import ArgumentParser
import Foundation
import LibGM
import GMProto

#if os(macOS)
import AppKit
#endif

@main
@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
struct GMCli: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gmcli",
        abstract: "Google Messages CLI client",
        subcommands: [
            PairCommand.self,
            ListCommand.self,
            SendCommand.self,
            StatusCommand.self,
            LogoutCommand.self,
        ],
        defaultSubcommand: StatusCommand.self
    )
}

// MARK: - Shared Utilities

/// Default auth data store location
func defaultStore() -> AuthDataStore {
    #if os(macOS)
    let baseDir = FileManager.default.homeDirectoryForCurrentUser
    #else
    let baseDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        ?? FileManager.default.temporaryDirectory
    #endif
    let gmcliDir = baseDir.appendingPathComponent(".gmcli", isDirectory: true)
    return AuthDataStore(directoryURL: gmcliDir)
}

/// Print events to console
final class ConsoleEventHandler: GMEventHandler, @unchecked Sendable {
    var onPairSuccess: ((String) -> Void)?
#if os(macOS)
    var pairingUI: PairingUIWindowController?
#endif

    func handleEvent(_ event: GMEvent) async {
        switch event {
        case .qrCode(let url):
            print("\n=== QR Code ===")
            print("Scan this QR code with Google Messages app:")
            print(url)
            print("================\n")
#if os(macOS)
            await MainActor.run {
                pairingUI?.model.qrURL = url
            }
#endif

        case .gaiaPairingEmoji(let emoji):
            print("\n=== Pairing Emoji ===")
            print("Confirm this emoji on your phone: \(emoji)")
            print("=====================\n")

        case .pairSuccessful(let phoneID, _):
            print("Pairing successful! Phone ID: \(phoneID)")
            onPairSuccess?(phoneID)
#if os(macOS)
            await MainActor.run {
                pairingUI?.model.statusText = "Paired (\(phoneID)). Finalizing..."
            }
#endif

        case .authTokenRefreshed:
            print("Auth token refreshed")

        case .message(let msg, let isOld):
            let conversationID = msg.conversationID
            let content = msg.messageInfo.first?.messageContent.content ?? ""
            let prefix = isOld ? "[old] " : ""
            print("\(prefix)[\(conversationID)] Message: \(content)")

        case .typing(let data):
            print("Typing indicator: \(data)")

        case .listenFatalError(let error):
            print("Fatal listen error: \(error)")
#if os(macOS)
            await MainActor.run {
                pairingUI?.model.statusText = "Fatal error: \(error.localizedDescription)"
            }
#endif

        case .listenTemporaryError(let error):
            print("Temporary listen error: \(error)")
#if os(macOS)
            await MainActor.run {
                pairingUI?.model.statusText = "Temporary error: \(error.localizedDescription)"
            }
#endif

        case .listenRecovered:
            print("Listen connection recovered")

        case .pingFailed(let error, let count):
            print("Ping failed (\(count)x): \(error)")

        case .phoneNotResponding:
            print("Warning: Phone not responding")

        case .phoneRespondingAgain:
            print("Phone responding again")

        case .noDataReceived:
            print("No data received in timeout period")

        case .userAlert(let alert):
            print("User alert: \(alert)")

        case .conversation(let conv):
            print("Conversation update: \(conv.conversationID)")

        case .settings(let settings):
            print("Settings update: \(settings)")

        case .browserActive(let session):
            print("Browser active: \(session)")

        case .gaiaLoggedOut:
            print("Logged out from Google account")

        case .accountChange(let event, let isFake):
            print("Account change (fake=\(isFake)): \(event)")

        case .requestError(let info):
            print("Request error: \(info.action)")

        case .httpError(let info):
            print("HTTP error (\(info.statusCode)): \(info.action)")
        }
    }
}

// MARK: - Pair Command

struct PairCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pair",
        abstract: "Pair with Google Messages using QR code or Gaia"
    )

    @Flag(
        inversion: .prefixedNo,
        help: "Show the QR code in a window (macOS)"
    )
    var ui: Bool = true

    @Flag(name: .long, help: "Use Google account pairing instead of QR code")
    var gaia = false

    @Option(name: .long, help: "Path to auth data directory")
    var dataDir: String?

    @Option(name: .long, help: "Cookie header value (for --gaia), e.g. 'SAPISID=...; __Secure-1PAPISID=...; ...'")
    var cookies: String?

    @Option(name: .long, help: "Path to a file containing a Cookie header value (for --gaia)")
    var cookiesFile: String?

    func run() async throws {
        let store = dataDir.map { AuthDataStore.store(at: $0) } ?? defaultStore()

        // Check if already paired
        if store.exists {
            print("Already paired. Use 'gmcli logout' to unpair first.")
            return
        }

        let eventHandler = ConsoleEventHandler()
        let client = await GMClient(eventHandler: eventHandler, autoReconnectAfterPairing: false)

        if gaia {
            // Google account pairing
            print("Starting Google account pairing...")
            print("Make sure you're signed into the same Google account on your phone.")

            if let cookieHeader = try loadCookieHeader() {
                let parsed = parseCookieHeader(cookieHeader)
                await client.authData.setCookies(parsed)
            }

            try await client.doGaiaPairing { emoji in
                print("\nConfirm this emoji on your phone: \(emoji)")
            }

            // Save auth data
            try await client.saveAuthData(to: store)
            print("\nPairing successful! Auth data saved to: \(store.filePath)")
            await client.disconnect()
        } else {
            // QR code pairing
            print("Starting QR code pairing...")

            let qrURL = try await client.startLogin()
            print("\n=== QR Code URL ===")
            print(qrURL)
            print("===================")
            print("\nScan this with the Google Messages app on your phone.")
            print("Waiting for pairing (connect to the server)...")

            #if os(macOS)
            if ui {
                let uiController = await MainActor.run { PairingUIWindowController(qrURL: qrURL) }
                eventHandler.pairingUI = uiController
                await MainActor.run {
                    _ = NSApplication.shared
                    NSApp.setActivationPolicy(.regular)
                    uiController.showAndActivate()
                }

                Task { [store] in
                    do {
                        try await waitForPairing(client: client, eventHandler: eventHandler, timeoutSeconds: 300)

                        // Persist auth data as soon as we receive the paired event so users don't
                        // lose the pairing if a post-pair reconnect fails.
                        await MainActor.run {
                            uiController.model.statusText = "Saving auth data..."
                        }
                        try await client.saveAuthData(to: store)
                        print("\nAuth data saved to: \(store.filePath)")

                        await MainActor.run {
                            uiController.model.statusText = "Finalizing pairing (reconnecting)..."
                        }
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        do {
                            try await client.reconnect()
                            // Save again in case the reconnect refreshed token/cookies.
                            try await client.saveAuthData(to: store)
                        } catch {
                            // Keep the saved auth data; reconnect failure can be transient.
                            print("Warning: reconnect after pairing failed: \(error.localizedDescription)")
                            await MainActor.run {
                                uiController.model.statusText = "Saved auth data, but reconnect failed: \(error.localizedDescription)"
                            }
                        }
                        await client.disconnect()

                        await MainActor.run {
                            uiController.model.statusText = "Auth data saved to: \(store.filePath)"
                            uiController.close()
                            NSApp.terminate(nil)
                        }
                    } catch {
                        await MainActor.run {
                            uiController.model.statusText = "Pairing failed: \(error.localizedDescription)"
                            uiController.close()
                            NSApp.terminate(nil)
                        }
                    }
                }

                // Run the AppKit event loop while pairing happens in the background.
                await MainActor.run {
                    NSApp.run()
                }

                return
            }
            #endif

            // Wait for the pairing event (or time out).
            try await waitForPairing(client: client, eventHandler: eventHandler, timeoutSeconds: 300)

            // Persist auth data immediately so users don't lose the pairing if reconnect fails.
            try await client.saveAuthData(to: store)
            print("\nAuth data saved to: \(store.filePath)")

            // Give the phone time to persist the pair data, then reconnect as a normal session.
            print("Finalizing pairing (reconnecting)...")
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            do {
                try await client.reconnect()
                // Save again in case the reconnect refreshed token/cookies.
                try await client.saveAuthData(to: store)
            } catch {
                print("Warning: reconnect after pairing failed: \(error.localizedDescription)")
            }

            // Save auth data
            await client.disconnect()
        }
    }

    private func waitForPairing(
        client: GMClient,
        eventHandler: ConsoleEventHandler,
        timeoutSeconds: UInt64
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let lock = NSLock()
            var finished = false

            func finish(_ result: Result<Void, Error>) {
                lock.lock()
                defer { lock.unlock() }
                guard !finished else { return }
                finished = true
                eventHandler.onPairSuccess = nil
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            let timeoutTask = Task {
                do {
                    try await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
                } catch {
                    return
                }
                finish(.failure(PairError.timeout))
            }

            eventHandler.onPairSuccess = { _ in
                timeoutTask.cancel()
                finish(.success(()))
            }

            Task {
                do {
                    try await client.connect()
                    print("Connected. Waiting for phone to pair...")
#if os(macOS)
                    await MainActor.run {
                        eventHandler.pairingUI?.model.statusText = "Connected. Waiting for phone to pair..."
                    }
#endif
                } catch {
                    timeoutTask.cancel()
                    finish(.failure(error))
                }
            }
        }
    }

    private func loadCookieHeader() throws -> String? {
        if let cookies, !cookies.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return cookies
        }
        if let cookiesFile {
            let s = try String(contentsOfFile: cookiesFile, encoding: .utf8)
            return s
        }
        return nil
    }

    private func parseCookieHeader(_ header: String) -> [String: String] {
        var s = header.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasPrefix("cookie:") {
            s = String(s.dropFirst("cookie:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var out: [String: String] = [:]
        for part in s.split(separator: ";") {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let kv = trimmed.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard kv.count == 2 else { continue }
            out[String(kv[0])] = String(kv[1])
        }
        return out
    }
}

enum PairError: Error, LocalizedError {
    case timeout

    var errorDescription: String? {
        switch self {
        case .timeout:
            return "Pairing timed out. Please try again."
        }
    }
}

// MARK: - List Command

struct ListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List conversations"
    )

    @Option(name: .shortAndLong, help: "Number of conversations to show")
    var count: Int = 10

    @Option(name: .long, help: "Path to auth data directory")
    var dataDir: String?

    func run() async throws {
        let store = dataDir.map { AuthDataStore.store(at: $0) } ?? defaultStore()

        guard let client = try await GMClient.loadFromStore(store) else {
            print("Not paired. Run 'gmcli pair' first.")
            return
        }

        print("Connecting...")
        try await client.connect()

        print("Fetching conversations...\n")
        let conversations = try await client.listConversations(count: count)

        if conversations.isEmpty {
            print("No conversations found.")
        } else {
            for (index, conv) in conversations.enumerated() {
                let name = conv.name.isEmpty ? conv.conversationID : conv.name
                let lastMessage = conv.latestMessage.displayContent.isEmpty ?
                    "(no message)" : conv.latestMessage.displayContent
                let unread = conv.unread ? " [unread]" : ""

                print("\(index + 1). \(name)\(unread)")
                print("   ID: \(conv.conversationID)")
                print("   Last: \(lastMessage)")
                print()
            }
        }

        await client.disconnect()
    }
}

// MARK: - Send Command

struct SendCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "send",
        abstract: "Send a message"
    )

    @Argument(help: "Conversation ID")
    var conversationId: String

    @Argument(help: "Message text")
    var message: String

    @Option(name: .long, help: "Path to auth data directory")
    var dataDir: String?

    func run() async throws {
        let store = dataDir.map { AuthDataStore.store(at: $0) } ?? defaultStore()

        guard let client = try await GMClient.loadFromStore(store) else {
            print("Not paired. Run 'gmcli pair' first.")
            return
        }

        print("Connecting...")
        try await client.connect()

        print("Sending message...")
        let response = try await client.sendMessage(
            conversationID: conversationId,
            text: message
        )

        if response.status == .success {
            print("Message sent successfully!")
        } else {
            print("Message send status: \(response.status)")
        }

        // Save updated auth data (in case token was refreshed)
        try await client.saveAuthData(to: store)
        await client.disconnect()
    }
}

// MARK: - Status Command

struct StatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show connection status"
    )

    @Option(name: .long, help: "Path to auth data directory")
    var dataDir: String?

    func run() async throws {
        let store = dataDir.map { AuthDataStore.store(at: $0) } ?? defaultStore()

        print("Auth data path: \(store.filePath)")

        guard store.exists else {
            print("Status: Not paired")
            print("Run 'gmcli pair' to start pairing.")
            return
        }

        guard let client = try await GMClient.loadFromStore(store) else {
            print("Status: Invalid auth data")
            return
        }

        let isLoggedIn = await client.isLoggedIn
        if isLoggedIn {
            print("Status: Paired")

            // Try to connect to verify
            do {
                print("Testing connection...")
                try await client.connect()
                print("Connection: OK")
                await client.disconnect()
            } catch {
                print("Connection: Failed - \(error.localizedDescription)")
            }
        } else {
            print("Status: Auth token expired")
            print("Run 'gmcli pair' to re-authenticate.")
        }
    }
}

// MARK: - Logout Command

struct LogoutCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "logout",
        abstract: "Remove saved auth data"
    )

    @Option(name: .long, help: "Path to auth data directory")
    var dataDir: String?

    @Flag(name: .shortAndLong, help: "Skip confirmation")
    var force = false

    func run() async throws {
        let store = dataDir.map { AuthDataStore.store(at: $0) } ?? defaultStore()

        guard store.exists else {
            print("No auth data found.")
            return
        }

        if !force {
            print("This will remove your saved authentication data.")
            print("You will need to pair again to use Google Messages.")
            print("Continue? [y/N] ", terminator: "")

            guard let response = readLine(), response.lowercased() == "y" else {
                print("Cancelled.")
                return
            }
        }

        try store.delete()
        print("Auth data removed.")
    }
}
