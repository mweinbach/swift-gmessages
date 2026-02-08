import Foundation
import GMCrypto
import GMProto
@preconcurrency import SwiftProtobuf

fileprivate actor BufferedPulse {
    private var pending = false
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    func signal() {
        if let entry = waiters.first {
            waiters.removeValue(forKey: entry.key)
            entry.value.resume()
            return
        }
        if pending {
            return
        }
        pending = true
    }

    func wait() async {
        if pending {
            pending = false
            return
        }

        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                waiters[id] = cont
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
    }

    private func cancelWaiter(id: UUID) {
        if let cont = waiters.removeValue(forKey: id) {
            cont.resume()
        }
    }
}

fileprivate actor UnbufferedPulse {
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    func signal() {
        guard let entry = waiters.first else { return }
        waiters.removeValue(forKey: entry.key)
        entry.value.resume()
    }

    func wait() async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                waiters[id] = cont
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
    }

    private func cancelWaiter(id: UUID) {
        if let cont = waiters.removeValue(forKey: id) {
            cont.resume()
        }
    }
}

fileprivate actor Resetter {
    private var doneFlag = false
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    func wait() async {
        if doneFlag {
            return
        }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                if doneFlag {
                    cont.resume()
                } else {
                    waiters[id] = cont
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
    }

    func done() {
        guard !doneFlag else { return }
        doneFlag = true
        let w = waiters
        waiters.removeAll(keepingCapacity: true)
        for (_, cont) in w {
            cont.resume()
        }
    }

    private func cancelWaiter(id: UUID) {
        if let cont = waiters.removeValue(forKey: id) {
            cont.resume()
        }
    }
}

/// Streaming long-poll connection (PBLite) for real-time message reception.
public actor LongPollConnection {
    private let authData: AuthData
    private let httpClient: GMHTTPClient
    private let sessionHandler: SessionHandler

    private weak var eventHandler: (any GMEventHandler)?

    private var isConnected = false
    private var pollTask: Task<Void, Never>?

    private var listenRequestID: String = UUID().uuidString.lowercased()
    private var skipCount: Int = 0
    private var totalPayloadCountValue: UInt64 = 0
    private var receivedDataPayload = false

    private var onFirstConnect: (@Sendable () async -> Void)?
    private var didCallOnFirstConnect = false

    private var onPaired: (@Sendable (Authentication_PairedData) async -> Void)?

    private var didOpenStreamOnce = false
    private var firstConnectWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    // MARK: - Ditto Pinger / Health Checks (Go libgm parity)

    private static let defaultPingTimeout: TimeInterval = 60
    private static let shortPingTimeout: TimeInterval = 10
    private static let minPingInterval: TimeInterval = 30
    private static let maxRepingTickerTime: TimeInterval = 64 * 60

    private static let defaultBugleDefaultCheckInterval: TimeInterval = 2 * 60 * 60 + 55 * 60

    private var pingerTask: Task<Void, Never>?
    private var pingPulse = BufferedPulse()
    private var pingShortCircuit = UnbufferedPulse()

    private var firstPingDone = false
    private var oldestPingTime: Date?
    private var lastPingTime: Date = .distantPast
    private var pingFails: Int = 0
    private var notRespondingSent = false

    private var nextDataReceiveCheck: Date = .distantPast

    private struct UpdateDedupItem {
        var id: String
        var hash: Data
    }

    private var recentUpdates: [UpdateDedupItem] = Array(repeating: UpdateDedupItem(id: "", hash: Data()), count: 8)
    private var recentUpdatesPtr: Int = 0

    private var pingIDCounter: UInt64 = 0

    public init(
        authData: AuthData,
        httpClient: GMHTTPClient,
        sessionHandler: SessionHandler,
        eventHandler: (any GMEventHandler)?,
        onPaired: (@Sendable (Authentication_PairedData) async -> Void)? = nil
    ) {
        self.authData = authData
        self.httpClient = httpClient
        self.sessionHandler = sessionHandler
        self.eventHandler = eventHandler
        self.onPaired = onPaired
    }

    public enum LongPollConnectionError: Error, LocalizedError {
        case firstConnectTimeout

        public var errorDescription: String? {
            switch self {
            case .firstConnectTimeout:
                return "Timed out waiting for long poll to connect"
            }
        }
    }

    public func setEventHandler(_ handler: any GMEventHandler) {
        self.eventHandler = handler
    }

    public func setOnPaired(_ cb: (@Sendable (Authentication_PairedData) async -> Void)?) {
        self.onPaired = cb
    }

    public var connected: Bool {
        isConnected
    }

    /// Number of initial messages to treat as "old" (set by the startup ack payload).
    var pendingSkipCount: Int {
        skipCount
    }

    /// Number of parsed long-poll payloads since the latest `start()`.
    var totalPayloadCount: UInt64 {
        totalPayloadCountValue
    }

    /// Whether any parsed payload since the latest `start()` contained `data`.
    var hasReceivedDataPayload: Bool {
        receivedDataPayload
    }

    public func start(onFirstConnect: (@Sendable () async -> Void)? = nil) async throws {
        guard !isConnected else { return }
        isConnected = true
        listenRequestID = UUID().uuidString.lowercased()
        skipCount = 0
        totalPayloadCountValue = 0
        receivedDataPayload = false
        self.onFirstConnect = onFirstConnect
        didCallOnFirstConnect = false
        didOpenStreamOnce = false

        // Match Go libgm: reset pinger state when starting a new long-poll session.
        firstPingDone = false
        oldestPingTime = nil
        lastPingTime = .distantPast
        pingFails = 0
        notRespondingSent = false
        pingPulse = BufferedPulse()
        pingShortCircuit = UnbufferedPulse()

        if pingerTask == nil {
            pingerTask = Task { [weak self] in
                guard let self else { return }
                await self.dittoPingerLoop()
            }
        }

        pollTask = Task { [weak self] in
            guard let self else { return }
            await self.pollLoop()
        }
    }

    public func stop() {
        isConnected = false
        pollTask?.cancel()
        pollTask = nil
        pingerTask?.cancel()
        pingerTask = nil
        failFirstConnectWaiters(error: CancellationError())
    }

    public func waitForFirstConnect(timeout: TimeInterval = 15) async throws {
        if didOpenStreamOnce {
            return
        }
        try await withCheckedThrowingContinuation { cont in
            let id = UUID()
            firstConnectWaiters[id] = cont
            if timeout > 0 {
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    await self?.timeoutFirstConnectWaiter(id: id)
                }
            }
        }
    }

    private func timeoutFirstConnectWaiter(id: UUID) {
        guard let cont = firstConnectWaiters.removeValue(forKey: id) else { return }
        cont.resume(throwing: LongPollConnectionError.firstConnectTimeout)
    }

    private func resolveFirstConnectWaiters() {
        didOpenStreamOnce = true
        let waiters = firstConnectWaiters
        firstConnectWaiters.removeAll(keepingCapacity: true)
        for (_, cont) in waiters {
            cont.resume()
        }
    }

    private func failFirstConnectWaiters(error: Error) {
        let waiters = firstConnectWaiters
        firstConnectWaiters.removeAll(keepingCapacity: true)
        for (_, cont) in waiters {
            cont.resume(throwing: error)
        }
    }

    // MARK: - Poll Loop

    private func pollLoop() async {
        var errorCount = 0
        while isConnected && !Task.isCancelled {
            do {
                try await refreshAuthTokenIfNeeded()

                // Go libgm uses the clients6 hostname for the streaming long poll when "HasCookies" is true.
                // In QR mode, "HasCookies" is also true, so this will typically choose the Google host.
                let useGoogleHost = await authData.shouldUseGoogleHost
                let url = useGoogleHost ? GMConstants.receiveMessagesURLGoogle : GMConstants.receiveMessagesURL

                var req = Client_ReceiveMessagesRequest()
                var auth = Authentication_AuthMessage()
                auth.requestID = listenRequestID
                if let token = await authData.tachyonAuthToken {
                    auth.tachyonAuthToken = token
                }
                auth.network = await authData.authNetwork
                auth.configVersion = GMConstants.makeConfigVersion()
                req.auth = auth

                var unk2 = Client_ReceiveMessagesRequest.UnknownEmptyObject2()
                unk2.unknown = Client_ReceiveMessagesRequest.UnknownEmptyObject1()
                req.unknown = unk2

                let (bytes, http) = try await httpClient.openStream(
                    url: url,
                    encoding: .pblite,
                    request: req,
                    accept: "*/*",
                    timeout: 30 * 60
                )

                if !didOpenStreamOnce {
                    resolveFirstConnectWaiters()
                }

                if errorCount > 0 {
                    errorCount = 0
                    await emitEvent(.listenRecovered)
                }

                if !didCallOnFirstConnect, let cb = onFirstConnect {
                    didCallOnFirstConnect = true
                    Task { await cb() }
                }

                if await shouldPingPhone() {
                    await pingPulse.signal()
                }

                try await readLongPoll(bytes: bytes, statusCode: http.statusCode)
            } catch {
                if !isConnected || Task.isCancelled { return }
                errorCount += 1
                await emitEvent(.listenTemporaryError(error))
                let sleepSeconds = min(5 * (errorCount + 1), 60)
                try? await Task.sleep(nanoseconds: UInt64(sleepSeconds) * 1_000_000_000)
            }
        }
    }

    // MARK: - Stream Parsing

    private func readLongPoll(bytes: URLSession.AsyncBytes, statusCode: Int) async throws {
        if !(200...299).contains(statusCode) {
            throw GMHTTPError.httpError(statusCode: statusCode, body: nil)
        }

        var it = bytes.makeAsyncIterator()

        guard let b0 = try await it.next(), let b1 = try await it.next() else {
            throw GMHTTPError.invalidResponse
        }
        // Stream is wrapped in a nested JSON array: `[[ <msg1>, <msg2>, ... ]]`.
        guard b0 == UInt8(ascii: "["), b1 == UInt8(ascii: "[") else {
            throw GMHTTPError.invalidResponse
        }

        var accumulated = Data()
        accumulated.reserveCapacity(256 * 1024)

        while isConnected && !Task.isCancelled {
            guard let b = try await it.next() else {
                // EOF
                return
            }

            if accumulated.isEmpty {
                if b == UInt8(ascii: ",") {
                    continue
                }
                if b == UInt8(ascii: "]") {
                    // Stream end marker: `]]`, then EOF.
                    guard let b2 = try await it.next() else { return }
                    if b2 == UInt8(ascii: "]") {
                        return
                    }
                    // Unexpected; treat as part of a message.
                    accumulated.append(b)
                    accumulated.append(b2)
                    continue
                }
            }

            accumulated.append(b)

            if b != UInt8(ascii: "]") {
                continue
            }

            if accumulated.count > 10 * 1024 * 1024 {
                throw GMHTTPError.invalidResponse
            }

            do {
                let obj = try JSONSerialization.jsonObject(with: accumulated, options: [])
                // We have a complete JSON value; clear the buffer to stay in sync even
                // if protobuf decoding fails.
                accumulated.removeAll(keepingCapacity: true)
                do {
                    let payload = try PBLite.unmarshal(obj, as: Rpc_LongPollingPayload.self)
                    try await handleLongPollPayload(payload)
                } catch {
                    // Ignore malformed payloads and keep reading.
                }
            } catch {
                // Most commonly an incomplete JSON chunk; keep reading.
            }
        }
    }

    private func handleLongPollPayload(_ payload: Rpc_LongPollingPayload) async throws {
        totalPayloadCountValue &+= 1
        if payload.hasData {
            receivedDataPayload = true
            try await handleIncomingRPC(payload.data)
            return
        }
        if payload.hasAck {
            let c = Int(payload.ack.count)
            if c > 0 {
                skipCount = c
            }
            return
        }
        // startRead/heartbeat: ignore
    }

    // MARK: - Incoming Message Handling

    private func handleIncomingRPC(_ raw: Rpc_IncomingRPCMessage) async throws {
        switch raw.bugleRoute {
        case .pairEvent:
            try await handlePairEvent(raw)
        case .gaiaEvent:
            // Not implemented yet (events are rare and mostly used during Gaia pairing).
            break
        case .dataEvent:
            try await handleDataEvent(raw)
        default:
            break
        }
    }

    private func handlePairEvent(_ raw: Rpc_IncomingRPCMessage) async throws {
        // Pair events are protobuf-encoded bytes in IncomingRPCMessage.messageData.
        let pairData = try Events_RPCPairData(serializedBytes: raw.messageData)

        switch pairData.event {
        case .paired(let paired):
            // Update auth data immediately, then emit success.
            if paired.hasTokenData {
                await authData.updateToken(token: paired.tokenData.tachyonAuthToken, ttl: paired.tokenData.ttl)
            }
            await authData.setMobile(paired.mobile)
            await authData.setBrowser(paired.browser)

            await emitEvent(.pairSuccessful(phoneID: paired.mobile.sourceID, data: paired))
            if let cb = onPaired {
                Task { await cb(paired) }
            }
        case .revoked:
            await emitEvent(.gaiaLoggedOut)
        case .none:
            break
        }
    }

    private func handleDataEvent(_ raw: Rpc_IncomingRPCMessage) async throws {
        await sessionHandler.queueMessageAck(raw.responseID)

        let msg = try Rpc_RPCMessageData(serializedBytes: raw.messageData)

        // Decrypt payload bytes if present.
        var decryptedPayload: Data? = nil
        if !msg.encryptedData.isEmpty {
            let crypto = await authData.requestCrypto
            decryptedPayload = try crypto.decrypt(msg.encryptedData)
        } else if !msg.encryptedData2.isEmpty {
            let crypto = await authData.requestCrypto
            let decrypted = try crypto.decrypt(msg.encryptedData2)
            decryptedPayload = decrypted

            // Hack: emit a fake account change event on startup (matches Go libgm behavior).
            if let container = try? Events_EncryptedData2Container(serializedBytes: decrypted),
               container.hasAccountChange,
               container.accountChange.account.contains("@")
            {
                await emitEvent(.accountChange(container.accountChange, isFake: true))
            }
        } else if !msg.unencryptedData.isEmpty {
            decryptedPayload = msg.unencryptedData
        }

        let incoming = SessionHandler.IncomingDataEvent(incoming: raw, message: msg, decryptedData: decryptedPayload)

        if await sessionHandler.receiveResponse(incoming) {
            return
        }

        var isOld = false
        if skipCount > 0 {
            skipCount -= 1
            isOld = true
        }

        // Most unsolicited data comes through GET_UPDATES.
        if msg.action == .getUpdates {
            try await handleGetUpdates(incoming: incoming, isOld: isOld)
        }
    }

    private func handleGetUpdates(incoming: SessionHandler.IncomingDataEvent, isOld: Bool) async throws {
        // Special-case logged out marker (matches Go libgm hack).
        if incoming.decryptedData == nil && incoming.message.unencryptedData == Data([0x72, 0x00]) {
            await emitEvent(.gaiaLoggedOut)
            return
        }

        guard let payload = incoming.decryptedData else {
            return
        }

        if !isOld {
            bumpNextDataReceiveCheck(after: Self.defaultBugleDefaultCheckInterval)
        }

        let contentHash = Data(SHA256.hash(data: payload))
        let updates = try Events_UpdateEvents(serializedBytes: payload)
        switch updates.event {
        case .userAlertEvent(let alert):
            if !isOld {
                await emitEvent(.userAlert(alert))
            }
        case .settingsEvent(let settings):
            await emitEvent(.settings(settings))
        case .browserPresenceCheckEvent:
            // No-op (observed, but not required for basic operation).
            break
        case .conversationEvent(let evt):
            for conv in evt.data {
                if deduplicateUpdate(id: conv.conversationID, hash: contentHash) {
                    return
                }
                if isOld { continue }
                await emitEvent(.conversation(conv))
            }
        case .messageEvent(let evt):
            for msg in evt.data {
                if deduplicateUpdate(id: msg.messageID, hash: contentHash) {
                    return
                }
                await emitEvent(.message(msg, isOld: isOld))
            }
        case .typingEvent(let evt):
            if isOld { return }
            await emitEvent(.typing(evt.data))
        case .accountChange(let evt):
            await emitEvent(.accountChange(evt, isFake: false))
        case .none:
            break
        }
    }

    // MARK: - Deduplication (Go libgm parity)

    private func deduplicateUpdate(id: String, hash: Data) -> Bool {
        let n = recentUpdates.count
        if n > 0 {
            for offset in 1...n {
                let idx = (recentUpdatesPtr + n - offset) % n
                if recentUpdates[idx].id == id {
                    if recentUpdates[idx].hash == hash {
                        return true
                    }
                    break
                }
            }
            recentUpdates[recentUpdatesPtr] = UpdateDedupItem(id: id, hash: hash)
            recentUpdatesPtr = (recentUpdatesPtr + 1) % n
        }
        return false
    }

    // MARK: - No-Data Checks (Go libgm parity)

    func bumpNextDataReceiveCheck(after: TimeInterval) {
        let now = Date()
        let target = now.addingTimeInterval(after)
        if nextDataReceiveCheck < target {
            nextDataReceiveCheck = target
        }
    }

    private func shouldDoDataReceiveCheck() -> Bool {
        let now = Date()
        if now >= nextDataReceiveCheck {
            nextDataReceiveCheck = now.addingTimeInterval(Self.defaultBugleDefaultCheckInterval)
            return true
        }
        return false
    }

    func shortCircuitPing() async {
        await pingShortCircuit.signal()
    }

    private func handleNoRecentUpdates() async {
        await emitEvent(.noDataReceived)
        do {
            let sid = await sessionHandler.currentSessionID
            try await sessionHandler.sendRequestNoWait(
                action: .getUpdates,
                requestID: sid,
                omitTTL: true
            )
        } catch {
            // Best-effort, matches Go libgm behavior (log-only).
        }
    }

    // MARK: - Ditto Pinger (Go libgm parity)

    private enum PingTrigger: Sendable {
        case normal
        case shortCircuit
    }

    private func nextPingID() -> UInt64 {
        pingIDCounter &+= 1
        return pingIDCounter
    }

    private func shouldPingPhone() async -> Bool {
        let hasToken = await authData.tachyonAuthToken != nil
        let hasBrowser = await authData.browser != nil
        let useGoogleHost = await authData.shouldUseGoogleHost
        return hasToken && hasBrowser && useGoogleHost
    }

    private func dittoPingerLoop() async {
        var lastDataReceiveCheck = Date.distantPast

        while isConnected && !Task.isCancelled {
            let trigger = await withTaskGroup(of: PingTrigger.self) { group in
                group.addTask { [pingPulse] in
                    await pingPulse.wait()
                    return .normal
                }
                group.addTask { [pingShortCircuit] in
                    await pingShortCircuit.wait()
                    return .shortCircuit
                }
                let first = await group.next() ?? .normal
                group.cancelAll()
                return first
            }

            if !isConnected || Task.isCancelled {
                return
            }

            let pingStart = Date()
            let pingID = nextPingID()

            switch trigger {
            case .shortCircuit:
                await ping(pingID: pingID, timeout: Self.shortPingTimeout, timeoutCount: 0, resetter: Resetter())
            case .normal:
                await ping(pingID: pingID, timeout: Self.defaultPingTimeout, timeoutCount: 0, resetter: Resetter())
            }

            if !isConnected || Task.isCancelled {
                return
            }

            if shouldDoDataReceiveCheck() {
                Task { [weak self] in
                    guard let self else { return }
                    await self.handleNoRecentUpdates()
                }
                lastDataReceiveCheck = Date()
            } else {
                let elapsed = Date().timeIntervalSince(pingStart)
                if elapsed > 5 * 60 || (elapsed > 60 && Date().timeIntervalSince(lastDataReceiveCheck) > 30 * 60) {
                    Task { [weak self] in
                        guard let self else { return }
                        await self.handleNoRecentUpdates()
                    }
                    lastDataReceiveCheck = Date()
                }
            }
        }
    }

    private func ping(pingID: UInt64, timeout: TimeInterval, timeoutCount: Int, resetter: Resetter) async {
        guard await shouldPingPhone() else { return }

        let now = Date()
        if now.timeIntervalSince(lastPingTime) < Self.minPingInterval {
            return
        }
        lastPingTime = now
        if oldestPingTime == nil {
            oldestPingTime = now
        }

        var request = Client_NotifyDittoActivityRequest()
        request.success = true

        let pingTask = Task { [sessionHandler] () throws -> Void in
            let _: Client_NotifyDittoActivityResponse = try await sessionHandler.sendRequest(
                action: .notifyDittoActivity,
                payload: request
            )
        }

        if timeoutCount == 0 {
            await waitForPingResponse(
                pingID: pingID,
                start: now,
                timeout: timeout,
                timeoutCount: timeoutCount,
                pingTask: pingTask,
                resetter: resetter
            )
        } else {
            Task { [weak self] in
                guard let self else { return }
                await self.waitForPingResponse(
                    pingID: pingID,
                    start: now,
                    timeout: timeout,
                    timeoutCount: timeoutCount,
                    pingTask: pingTask,
                    resetter: resetter
                )
            }
        }
    }

    private enum PingWaitResult: Sendable {
        case responded
        case failed(Error)
        case timedOut
        case shortCircuit
        case reset
        case cancelled
    }

    private func waitForPingResponse(
        pingID: UInt64,
        start: Date,
        timeout: TimeInterval,
        timeoutCount: Int,
        pingTask: Task<Void, Error>,
        resetter: Resetter
    ) async {
        let first = await withTaskGroup(of: PingWaitResult.self) { group in
            group.addTask {
                do {
                    try await pingTask.value
                    return .responded
                } catch {
                    if error is CancellationError {
                        return .cancelled
                    }
                    return .failed(error)
                }
            }
            if timeout > 0 {
                group.addTask {
                    do {
                        try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                        return .timedOut
                    } catch {
                        return .cancelled
                    }
                }
            }
            group.addTask { [resetter] in
                await resetter.wait()
                return .reset
            }
            let res = await group.next() ?? .cancelled
            group.cancelAll()
            return res
        }

        switch first {
        case .responded:
            await onPingRespond(pingID: pingID, duration: Date().timeIntervalSince(start), resetter: resetter)
            return
        case .failed(let error):
            pingFails += 1
            await emitEvent(.pingFailed(error: error, count: pingFails))
            return
        case .reset, .cancelled:
            return
        case .shortCircuit:
            return
        case .timedOut:
            await onPingTimeout(
                pingID: pingID,
                sendNotResponding: timeout == Self.shortPingTimeout || timeoutCount > 3
            )
        }

        var repingTickerTime: TimeInterval = 60
        let doRepingTicker = timeoutCount == 0
        var localTimeoutCount = timeoutCount

        while isConnected && !Task.isCancelled {
            localTimeoutCount += 1

            let next = await withTaskGroup(of: PingWaitResult.self) { group in
                group.addTask {
                    do {
                        try await pingTask.value
                        return .responded
                    } catch {
                        if error is CancellationError {
                            return .cancelled
                        }
                        return .failed(error)
                    }
                }
                group.addTask { [resetter] in
                    await resetter.wait()
                    return Task.isCancelled ? .cancelled : .reset
                }
                group.addTask { [pingShortCircuit] in
                    await pingShortCircuit.wait()
                    return Task.isCancelled ? .cancelled : .shortCircuit
                }
                if doRepingTicker {
                    let sleepFor = repingTickerTime
                    group.addTask {
                        do {
                            try await Task.sleep(nanoseconds: UInt64(sleepFor * 1_000_000_000))
                            return .timedOut
                        } catch {
                            return .cancelled
                        }
                    }
                }
                let res = await group.next() ?? .cancelled
                group.cancelAll()
                return res
            }

            switch next {
            case .responded:
                await onPingRespond(pingID: pingID, duration: Date().timeIntervalSince(start), resetter: resetter)
                return
            case .failed(let error):
                pingFails += 1
                await emitEvent(.pingFailed(error: error, count: pingFails))
                return
            case .reset, .cancelled:
                return
            case .shortCircuit:
                if !notRespondingSent {
                    notRespondingSent = true
                    await emitEvent(.phoneNotResponding)
                }
                continue
            case .timedOut:
                guard doRepingTicker else {
                    continue
                }
                if repingTickerTime < Self.maxRepingTickerTime {
                    repingTickerTime = min(repingTickerTime * 2, Self.maxRepingTickerTime)
                }
                let subPingID = nextPingID()
                await ping(
                    pingID: subPingID,
                    timeout: Self.defaultPingTimeout,
                    timeoutCount: localTimeoutCount,
                    resetter: resetter
                )
                continue
            }
        }
    }

    private func onPingRespond(pingID: UInt64, duration: TimeInterval, resetter: Resetter) async {
        if notRespondingSent || pingFails > 0 {
            await emitEvent(.phoneRespondingAgain)
        }

        oldestPingTime = nil
        notRespondingSent = false
        pingFails = 0
        firstPingDone = true
        await resetter.done()
    }

    private func onPingTimeout(pingID: UInt64, sendNotResponding: Bool) async {
        if (!firstPingDone || sendNotResponding) && !notRespondingSent {
            notRespondingSent = true
            await emitEvent(.phoneNotResponding)
        }
    }

    // MARK: - Token Refresh

    private func refreshAuthTokenIfNeeded() async throws {
        guard let browser = await authData.browser else { return }
        guard await authData.needsTokenRefresh else { return }

        let requestID = UUID().uuidString.lowercased()
        let timestamp = Int64(Date().timeIntervalSince1970 * 1_000_000) // microseconds

        var auth = Authentication_AuthMessage()
        auth.requestID = requestID
        if let token = await authData.tachyonAuthToken {
            auth.tachyonAuthToken = token
        }
        auth.network = await authData.authNetwork
        auth.configVersion = GMConstants.makeConfigVersion()

        var req = Authentication_RegisterRefreshRequest()
        req.messageAuth = auth
        req.currBrowserDevice = browser
        req.unixTimestamp = timestamp
        let refreshKey = await authData.refreshKey
        req.signature = try refreshKey.signRefreshRequest(requestID: requestID, timestamp: timestamp)

        var params = Authentication_RegisterRefreshRequest.Parameters()
        params.emptyArr = Util_EmptyArr()

        if let keys = await authData.pushKeys {
            var more = Authentication_RegisterRefreshRequest.MoreParameters()
            more.three = 3
            var push = Authentication_RegisterRefreshRequest.PushRegistration()
            push.type = "messages_web"
            push.url = keys.url
            push.p256Dh = keys.p256dh.base64URLEncodedStringNoPadding()
            push.auth = keys.auth.base64URLEncodedStringNoPadding()
            more.pushReg = push
            params.moreParameters = more
        }
        req.parameters = params
        req.messageType = 2

        let resp = try await httpClient.post(
            url: GMConstants.registerRefreshURL,
            encoding: .pblite,
            request: req,
            response: Authentication_RegisterRefreshResponse.self
        )

        if resp.hasTokenData {
            await authData.updateToken(token: resp.tokenData.tachyonAuthToken, ttl: resp.tokenData.ttl)
            await emitEvent(.authTokenRefreshed)
        }
    }

    // MARK: - Events

    private func emitEvent(_ event: GMEvent) async {
        await eventHandler?.handleEvent(event)
    }
}
