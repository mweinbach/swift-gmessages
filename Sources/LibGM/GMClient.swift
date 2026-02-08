import Foundation
import GMCrypto
import GMProto
@preconcurrency import SwiftProtobuf

public enum GMClientError: Error, LocalizedError, Equatable {
    case notLoggedIn
    case backgroundPollingExitedUncleanly

    public var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "Not logged in"
        case .backgroundPollingExitedUncleanly:
            return "Background polling exited before receiving data"
        }
    }
}

/// Main Google Messages client
public actor GMClient {
    /// Authentication data
    public let authData: AuthData

    /// HTTP client
    private let httpClient: GMHTTPClient

    /// Session handler
    private let sessionHandler: SessionHandler

    /// Long-poll connection
    private let longPoll: LongPollConnection

    /// Media handler for uploads/downloads
    private let mediaHandler: MediaHandler

    /// Event handler
    private var eventHandler: (any GMEventHandler)?

    private var conversationsFetchedOnce = false
    private var gaiaHackyDeviceSwitcher = 0

    /// Whether connected to the server
    public var isConnected: Bool {
        get async { await longPoll.connected }
    }

    /// Current session identifier used for request/response correlation.
    public var currentSessionID: String {
        get async { await sessionHandler.currentSessionID }
    }

    /// Whether logged in (has auth token)
    public var isLoggedIn: Bool {
        get async {
            let hasToken = await authData.tachyonAuthToken != nil
            let hasBrowser = await authData.browser != nil
            let isGoogleAccount = await authData.isGoogleAccount
            let hasCookies = await authData.hasCookies
            return hasToken && hasBrowser && (!isGoogleAccount || hasCookies)
        }
    }

    /// Create a new Google Messages client
    /// - Parameters:
    ///   - authData: Authentication data (nil to create new)
    ///   - eventHandler: Event handler for receiving events
    public init(
        authData: AuthData? = nil,
        eventHandler: (any GMEventHandler)? = nil,
        autoReconnectAfterPairing: Bool = true
    ) async {
        let auth = authData ?? AuthData()
        self.authData = auth
        self.httpClient = GMHTTPClient(authData: auth)
        self.sessionHandler = SessionHandler(authData: auth, httpClient: httpClient)
        self.longPoll = LongPollConnection(
            authData: auth,
            httpClient: httpClient,
            sessionHandler: sessionHandler,
            eventHandler: eventHandler,
            onPaired: nil
        )
        self.mediaHandler = MediaHandler(authData: auth)
        self.eventHandler = eventHandler

        // Match Go libgm: if a request is "stuck" for a few seconds, short-circuit the ditto pinger.
        await sessionHandler.setOnRequestSlow { [weak longPoll = self.longPoll] in
            guard let longPoll else { return }
            await longPoll.shortCircuitPing()
        }

        if autoReconnectAfterPairing {
            // Pairing completion in QR mode requires a short delay before reconnecting,
            // otherwise the phone may not persist the pair data and will unpair the session.
            await longPoll.setOnPaired { [weak self] _ in
                guard let self else { return }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                do {
                    try await self.reconnect()
                } catch {
                    await self.emitEvent(.listenFatalError(error))
                }
            }
        }
    }

    /// Set the event handler
    public func setEventHandler(_ handler: any GMEventHandler) async {
        self.eventHandler = handler
        await longPoll.setEventHandler(handler)
    }

    /// Set the event handler using a closure
    public func setEventHandler(_ handler: @escaping @Sendable (GMEvent) async -> Void) async {
        let closureHandler = ClosureEventHandler(handler: handler)
        await setEventHandler(closureHandler)
    }

    // MARK: - Connection Management

    public func setProxy(_ url: URL?) async {
        await httpClient.setProxy(url)
    }

    public func setProxy(_ proxy: String) async throws {
        guard let url = URL(string: proxy) else {
            throw URLError(.badURL)
        }
        await setProxy(url)
    }

    /// Fetch the Messages for Web config (`/web/config`).
    public func fetchConfig() async throws -> Config_Config {
        let config = try await httpClient.fetchConfig()
        if config.hasDeviceInfo, let uuid = UUID(uuidString: config.deviceInfo.deviceID) {
            await authData.setSessionID(uuid)
        }
        return config
    }

    /// Connect to Google Messages
    public func connect() async throws {
        // Match Go libgm: refresh token before opening the stream to avoid races.
        try await refreshTokenIfNeeded()

        let loggedIn = await isLoggedIn
        if loggedIn {
            // Match Go libgm: schedule an early "no data" check after connect.
            await longPoll.bumpNextDataReceiveCheck(after: 10 * 60)
            await sessionHandler.startAckInterval()
        }

        // Start long-polling stream. After the first connect, send acks + set active session.
        let onFirstConnect: (@Sendable () async -> Void)?
        if loggedIn {
            onFirstConnect = { [weak self] in
                guard let self else { return }
                await self.postConnect()
            }
        } else {
            onFirstConnect = nil
        }
        try await longPoll.start(onFirstConnect: onFirstConnect)
        // Wait for the stream to actually open even in QR pairing mode, otherwise it's easy
        // to miss the pair event if the QR is scanned quickly (Go starts longpoll immediately).
        try await longPoll.waitForFirstConnect(timeout: 15)
    }

    /// Disconnect from Google Messages
    public func disconnect() async {
        await longPoll.stop()
        await sessionHandler.stopAckInterval(flush: true)
    }

    /// Reconnect to Google Messages
    public func reconnect() async throws {
        await disconnect()
        try await connect()
    }

    /// Open a short-lived background long-poll session (Go libgm `ConnectBackground` parity).
    ///
    /// This is primarily used for push/background sync workflows where a full foreground connect
    /// loop is not desired.
    public func connectBackground() async throws {
        if await longPoll.connected {
            return
        }

        let hasToken = await authData.tachyonAuthToken != nil
        let hasBrowser = await authData.browser != nil
        guard hasToken && hasBrowser else {
            throw GMClientError.notLoggedIn
        }

        try await refreshTokenIfNeeded()

        try await longPoll.start()
        do {
            try await longPoll.waitForFirstConnect(timeout: 15)
        } catch {
            await longPoll.stop()
            throw error
        }

        var deadline = Date().addingTimeInterval(10)
        var payloadCount = await longPoll.totalPayloadCount

        while Date() < deadline {
            if !(await longPoll.connected) {
                break
            }
            try? await Task.sleep(nanoseconds: 250_000_000)

            let newPayloadCount = await longPoll.totalPayloadCount
            if newPayloadCount == payloadCount {
                continue
            }

            payloadCount = newPayloadCount
            let gotData = await longPoll.hasReceivedDataPayload
            deadline = Date().addingTimeInterval(gotData ? 3 : 5)
        }

        await longPoll.stop()
        await sessionHandler.sendAckRequest()

        if !(await longPoll.hasReceivedDataPayload) {
            throw GMClientError.backgroundPollingExitedUncleanly
        }
    }

    private func postConnect() async {
        // Let the long poll stream stabilize.
        try? await Task.sleep(nanoseconds: 2_000_000_000)

        // Go libgm waits a bit longer if the initial backlog skip count is non-zero,
        // otherwise SetActiveSession/GET_UPDATES can be flaky on some accounts.
        if await longPoll.pendingSkipCount > 0 {
            for _ in 0..<3 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if await longPoll.pendingSkipCount == 0 { break }
            }
        }

        // Send any queued acks before GET_UPDATES.
        await sessionHandler.sendAckRequest()
        try? await Task.sleep(nanoseconds: 1_000_000_000)

        do {
            try await setActiveSession()
        } catch {
            await emitEvent(.listenTemporaryError(error))
            return
        }

        // This request isn't strictly required, but Go libgm does it on connect.
        _ = try? await isBugleDefault()
    }

    public func setActiveSession() async throws {
        await sessionHandler.resetSessionID()
        let sid = await sessionHandler.currentSessionID
        try await sessionHandler.sendRequestNoWait(
            action: .getUpdates,
            requestID: sid,
            omitTTL: true
        )
    }

    public func isBugleDefault() async throws -> Bool {
        let response: Client_IsBugleDefaultResponse = try await sessionHandler.sendRequest(action: .isBugleDefault)
        return response.success
    }

    // MARK: - Pairing

    /// Start QR code pairing flow
    /// - Returns: QR code URL to display to user
    public func startLogin() async throws -> String {
        let response = try await registerPhoneRelay()
        if response.hasAuthKeyData {
            await authData.updateToken(token: response.authKeyData.tachyonAuthToken, ttl: response.authKeyData.ttl)
        }

        // Match Go libgm: start longpoll immediately so pairing events aren't missed.
        try await longPoll.start()

        let qrURL = try generateQRCodeURL(
            pairingKey: response.pairingKey,
            aesKey: await authData.requestCrypto.aesKey,
            hmacKey: await authData.requestCrypto.hmacKey
        )

        await emitEvent(.qrCode(url: qrURL))
        return qrURL
    }

    /// Register phone relay for pairing
    public func registerPhoneRelay() async throws -> Authentication_RegisterPhoneRelayResponse {
        var request = Authentication_AuthenticationContainer()

        // Auth message
        var authMessage = Authentication_AuthMessage()
        authMessage.requestID = UUID().uuidString.lowercased()
        authMessage.network = GMConstants.qrNetwork
        authMessage.configVersion = GMConstants.makeConfigVersion()
        request.authMessage = authMessage

        // Browser details
        request.browserDetails = GMConstants.makeBrowserDetails()

        // Key data
        var keyData = Authentication_KeyData()

        // ECDSA keys
        var ecdsaKeys = Authentication_ECDSAKeys()
        ecdsaKeys.field1 = 2
        // Go libgm sends a DER SubjectPublicKeyInfo (PKIX) blob here (x509.MarshalPKIXPublicKey).
        let refreshKey = await authData.refreshKey
        let pkix = try refreshKey.pkixPublicKeyDER()
        ecdsaKeys.encryptedKeys = pkix
        keyData.ecdsaKeys = ecdsaKeys

        request.keyData = keyData

        return try await httpClient.post(
            url: GMConstants.registerPhoneRelayURL,
            encoding: .protobuf,
            request: request,
            response: Authentication_RegisterPhoneRelayResponse.self
        )
    }

    /// Refresh the QR relay pairing and return a new QR URL (QR pairing only).
    public func refreshPhoneRelay() async throws -> String {
        var request = Authentication_AuthenticationContainer()

        var authMessage = Authentication_AuthMessage()
        authMessage.requestID = UUID().uuidString.lowercased()
        if let token = await authData.tachyonAuthToken {
            authMessage.tachyonAuthToken = token
        }
        authMessage.network = GMConstants.qrNetwork
        authMessage.configVersion = GMConstants.makeConfigVersion()
        request.authMessage = authMessage

        let response = try await httpClient.post(
            url: GMConstants.refreshPhoneRelayURL,
            encoding: .protobuf,
            request: request,
            response: Authentication_RefreshPhoneRelayResponse.self
        )

        return try generateQRCodeURL(
            pairingKey: response.pairKey,
            aesKey: await authData.requestCrypto.aesKey,
            hmacKey: await authData.requestCrypto.hmacKey
        )
    }

    /// Fetch the web encryption key (currently unused, but exposed for parity with Go libgm).
    public func getWebEncryptionKey() async throws -> Authentication_WebEncryptionKeyResponse {
        var request = Authentication_AuthenticationContainer()

        var authMessage = Authentication_AuthMessage()
        authMessage.requestID = UUID().uuidString.lowercased()
        if let token = await authData.tachyonAuthToken {
            authMessage.tachyonAuthToken = token
        }
        authMessage.configVersion = GMConstants.makeConfigVersion()
        request.authMessage = authMessage

        let response = try await httpClient.post(
            url: GMConstants.webEncryptionKeyURL,
            encoding: .protobuf,
            request: request,
            response: Authentication_WebEncryptionKeyResponse.self
        )

        if !response.key.isEmpty {
            await authData.setWebEncryptionKey(response.key)
        }

        return response
    }

    /// Generate QR code URL from pairing data
    private func generateQRCodeURL(pairingKey: Data, aesKey: Data, hmacKey: Data) throws -> String {
        var urlData = Authentication_URLData()
        urlData.pairingKey = pairingKey
        urlData.aeskey = aesKey
        urlData.hmackey = hmacKey

        let encodedData = try urlData.serializedData().base64EncodedString()
        return GMConstants.qrCodeURLBase + encodedData
    }

    /// Unpair from phone
    public func unpair() async throws {
        if await authData.isGoogleAccount {
            try await unpairGaia()
        } else {
            try await unpairBugle()
        }
    }

    /// Unpair from phone (QR code pairing)
    public func unpairBugle() async throws {
        var request = Authentication_RevokeRelayPairingRequest()

        var authMessage = Authentication_AuthMessage()
        authMessage.requestID = UUID().uuidString.lowercased()
        if let token = await authData.tachyonAuthToken {
            authMessage.tachyonAuthToken = token
        }
        authMessage.configVersion = GMConstants.makeConfigVersion()
        request.authMessage = authMessage

        if let browser = await authData.browser {
            request.browser = browser
        }

        _ = try await httpClient.post(
            url: GMConstants.revokeRelayPairingURL,
            encoding: .protobuf,
            request: request,
            response: Authentication_RevokeRelayPairingResponse.self
        )
    }

    /// Unpair from phone (Google account pairing)
    public func unpairGaia() async throws {
        var request = Authentication_RevokeGaiaPairingRequest()
        if let pairingID = await authData.pairingID {
            request.pairingAttemptID = pairingID.uuidString.lowercased()
        }

        try await sessionHandler.sendRequestNoWait(action: .unpairGaiaPairing, payload: request)
    }

    // MARK: - Gaia (Google Account) Pairing

    /// Set the preferred primary-device index for Gaia pairing when multiple candidates exist.
    ///
    /// This matches Go libgm's `GaiaHackyDeviceSwitcher` behavior.
    public func setGaiaDeviceSwitcher(_ index: Int) {
        gaiaHackyDeviceSwitcher = index
    }

    /// Current Gaia pairing device switcher value.
    public func getGaiaDeviceSwitcher() -> Int {
        gaiaHackyDeviceSwitcher
    }

    /// Start Gaia pairing flow (Google account authentication)
    /// Requires cookies to be set from a logged-in Google account
    /// - Parameter deviceSelectionIndex: Optional override for selecting among multiple primary devices.
    /// - Returns: Tuple of (emoji to display, pairing session for finishGaiaPairing)
    public func startGaiaPairing(
        deviceSelectionIndex: Int? = nil
    ) async throws -> (emoji: String, session: PairingSession) {
        // Verify we have cookies
        guard await authData.hasCookies else {
            throw PairingError.noCookies
        }

        // Sign in to Gaia and get token
        let sigResp = try await signInGaiaGetToken()
        let selectionIndex = deviceSelectionIndex ?? gaiaHackyDeviceSwitcher

        // Find primary device
        guard let primaryDevice = findPrimaryDevice(from: sigResp, selectionIndex: selectionIndex) else {
            throw PairingError.noDevicesFound
        }

        // Store destination registration ID
        if let destRegUUID = UUID(uuidString: primaryDevice.regID) {
            await authData.setDestRegID(destRegUUID)
        }

        // Start long-polling
        try await longPoll.start()
        try await longPoll.waitForFirstConnect(timeout: 15)

        // Create pairing session
        var pairingSession = PairingSession(
            destRegID: primaryDevice.regID,
            destRegUnknownInt: primaryDevice.unknownInt
        )

        // Prepare UKEY2 payloads
        let (clientInit, _) = try pairingSession.preparePayloads()

        // Send client init and wait for server init
        let serverInit = try await sendGaiaPairingMessage(
            session: pairingSession,
            action: .createGaiaPairingClientInit,
            data: clientInit
        )

        // Process server init and get pairing emoji
        let pairingEmoji = try pairingSession.processServerInit(serverInit)

        await emitEvent(.gaiaPairingEmoji(emoji: pairingEmoji))

        return (emoji: pairingEmoji, session: pairingSession)
    }

    /// Finish Gaia pairing after user confirms emoji on phone
    /// - Parameter session: The pairing session from startGaiaPairing
    /// - Returns: Phone ID string
    public func finishGaiaPairing(session: PairingSession) async throws -> String {
        guard let finishPayload = session.finishPayload else {
            throw PairingError.missingInitPayload
        }

        // Send client finish
        let finishResp = try await sendGaiaPairingMessage(
            session: session,
            action: .createGaiaPairingClientFinished,
            data: finishPayload
        )

        // Check for errors
        if finishResp.finishErrorType != 0 {
            switch finishResp.finishErrorCode {
            case .wrongVerificationCodeSelected:
                throw PairingError.incorrectEmoji
            case .userCanceledVerification:
                throw PairingError.pairingCancelled
            case .requestOutOfDate, .requestNotReceivedQuickly, .verificationTimedOut:
                throw PairingError.pairingTimeout
            case .userDeniedVerificationNotMe:
                throw PairingError.pairingCancelled
            default:
                throw PairingError.pairingCancelled
            }
        }

        // Derive encryption keys
        guard let serverInit = session.serverInit else {
            throw PairingError.missingNextKey
        }

        let (aesKey, hmacKey) = try session.deriveEncryptionKeys(
            keyDerivationVersion: serverInit.confirmedKeyDerivationVersion
        )

        // Update auth data with new keys
        await authData.updateRequestCrypto(aesKey: aesKey, hmacKey: hmacKey)
        await authData.setPairingID(session.uuid)

        // Get mobile info
        let mobileSourceID = await authData.mobile?.sourceID ?? ""
        let phoneID = "\(mobileSourceID)/\(session.destRegUnknownInt)"

        await emitEvent(.pairSuccessful(phoneID: phoneID, data: nil))

        return phoneID
    }

    /// Perform complete Gaia pairing flow with emoji callback
    /// - Parameter emojiCallback: Called with the pairing emoji to display
    public func doGaiaPairing(emojiCallback: @escaping (String) async -> Void) async throws {
        let (emoji, session) = try await startGaiaPairing()
        await emojiCallback(emoji)
        _ = try await finishGaiaPairing(session: session)

        // Reconnect after successful pairing
        try await reconnect()
    }

    /// Cancel an in-progress Gaia pairing session
    public func cancelGaiaPairing(session: PairingSession) async throws {
        let ttl = Int64(300 * 1_000_000) // 300 seconds in microseconds
        let params = GMSendMessageParams(
            action: .cancelGaiaPairing,
            data: nil,
            requestID: session.uuid.uuidString.lowercased(),
            customTTL: ttl,
            dontEncrypt: true,
            messageType: .gaia2
        )
        try await sessionHandler.sendMessageNoWait(params)
    }

    // MARK: - Gaia Pairing Helpers

    /// Sign in to Gaia and get authentication token
    private func signInGaiaGetToken() async throws -> Authentication_SignInGaiaResponse {
        let sessionID = await authData.sessionID
        var request = Authentication_SignInGaiaRequest()

        var authMessage = Authentication_AuthMessage()
        authMessage.requestID = UUID().uuidString.lowercased()
        authMessage.network = GMConstants.googleNetwork
        authMessage.configVersion = GMConstants.makeConfigVersion()
        request.authMessage = authMessage

        var inner = Authentication_SignInGaiaRequest.Inner()
        var deviceID = Authentication_SignInGaiaRequest.Inner.DeviceID()
        deviceID.unknownInt1 = 3
        deviceID.deviceID = "messages-web-\(sessionID.uuidString.lowercased().replacingOccurrences(of: "-", with: ""))"
        inner.deviceID = deviceID

        // Add public key for token generation (PKIX DER SPKI, matches Go x509.MarshalPKIXPublicKey)
        let refreshKey = await authData.refreshKey
        let keyData = try refreshKey.pkixPublicKeyDER()
        var someData = Authentication_SignInGaiaRequest.Inner.DataMessage()
        someData.someData = keyData
        inner.someData = someData

        request.inner = inner
        request.network = GMConstants.googleNetwork

        let response = try await httpClient.post(
            url: GMConstants.signInGaiaURL,
            encoding: .pblite,
            request: request,
            response: Authentication_SignInGaiaResponse.self
        )

        // Update token
        if response.hasTokenData {
            await authData.updateToken(
                token: response.tokenData.tachyonAuthToken,
                ttl: response.tokenData.ttl
            )
        }

        // Update device info
        if response.hasDeviceData {
            let device = response.deviceData.deviceWrapper.device
            var lowercaseDevice = device
            lowercaseDevice.sourceID = device.sourceID.lowercased()
            await authData.setMobile(lowercaseDevice)
            await authData.setBrowser(device)
        }

        return response
    }

    /// Primary device information
    private struct PrimaryDevice {
        let regID: String
        let unknownInt: UInt64
        let lastSeen: Date?
    }

    /// Find the primary device from sign-in response
    private func findPrimaryDevice(
        from response: Authentication_SignInGaiaResponse,
        selectionIndex: Int
    ) -> PrimaryDevice? {
        var primaryDevices: [PrimaryDevice] = []
        var lastSeenMap: [String: Date] = [:]

        // Collect primary devices
        for item in response.deviceData.unknownItems2 {
            if item.unknownInt4 == 1 {
                primaryDevices.append(PrimaryDevice(
                    regID: item.destOrSourceUuid,
                    unknownInt: item.unknownBigInt7,
                    lastSeen: nil
                ))
            }
        }

        // Collect last seen times
        for item in response.deviceData.unknownItems3 {
            lastSeenMap[item.destOrSourceUuid] = Date(
                timeIntervalSince1970: Double(item.unknownTimestampMicroseconds) / 1_000_000
            )
        }

        // Update last seen and sort
        primaryDevices = primaryDevices.map { device in
            PrimaryDevice(
                regID: device.regID,
                unknownInt: device.unknownInt,
                lastSeen: lastSeenMap[device.regID]
            )
        }
        .sorted { ($0.lastSeen ?? .distantPast) > ($1.lastSeen ?? .distantPast) }

        guard !primaryDevices.isEmpty else {
            return nil
        }

        let count = primaryDevices.count
        let normalizedIndex = ((selectionIndex % count) + count) % count
        return primaryDevices[normalizedIndex]
    }

    /// Send a Gaia pairing message and wait for response
    private func sendGaiaPairingMessage(
        session: PairingSession,
        action: Rpc_ActionType,
        data: Data
    ) async throws -> Authentication_GaiaPairingResponseContainer {
        var reqContainer = Authentication_GaiaPairingRequestContainer()
        reqContainer.pairingAttemptID = session.uuid.uuidString.lowercased()
        reqContainer.browserDetails = GMConstants.makeBrowserDetails()
        reqContainer.startTimestamp = Int64(session.startTime.timeIntervalSince1970 * 1000)
        reqContainer.data = data

        if action == .createGaiaPairingClientInit {
            reqContainer.proposedVerificationCodeVersion = 1
            reqContainer.proposedKeyDerivationVersion = 1
        }

        let msgType: Rpc_MessageType = (action == .createGaiaPairingClientFinished) ? .bugleMessage : .gaia2
        let ttl = Int64(300 * 1_000_000) // 300 seconds in microseconds
        let params = GMSendMessageParams(
            action: action,
            data: reqContainer,
            customTTL: ttl,
            dontEncrypt: true,
            messageType: msgType
        )
        return try await sessionHandler.sendMessage(params, response: Authentication_GaiaPairingResponseContainer.self)
    }

    // MARK: - Conversations

    /// List conversations
    /// - Parameters:
    ///   - count: Number of conversations to fetch
    ///   - folder: Folder to list (inbox, archive, etc.)
    /// - Returns: List of conversations
    public func listConversations(
        count: Int = 25,
        folder: Client_ListConversationsRequest.Folder = .inbox
    ) async throws -> [Conversations_Conversation] {
        let response = try await listConversationsPage(count: count, folder: folder, cursor: nil)
        return response.conversations
    }

    public func listConversationsPage(
        count: Int = 25,
        folder: Client_ListConversationsRequest.Folder = .inbox,
        cursor: Client_Cursor? = nil
    ) async throws -> Client_ListConversationsResponse {
        var request = Client_ListConversationsRequest()
        request.count = Int64(count)
        request.folder = folder
        if let cursor {
            request.cursor = cursor
        }

        let msgType: Rpc_MessageType = conversationsFetchedOnce ? .bugleMessage : .bugleAnnotation
        conversationsFetchedOnce = true

        let response: Client_ListConversationsResponse = try await sessionHandler.sendRequest(
            action: .listConversations,
            payload: request,
            messageType: msgType
        )
        return response
    }

    /// Get a specific conversation
    /// - Parameter conversationID: The conversation ID
    /// - Returns: The conversation
    public func getConversation(id conversationID: String) async throws -> Conversations_Conversation {
        var request = Client_GetConversationRequest()
        request.conversationID = conversationID

        let response: Client_GetConversationResponse = try await sessionHandler.sendRequest(
            action: .getConversation,
            payload: request
        )
        return response.conversation
    }

    /// Get the server's conversation type metadata.
    public func getConversationType(conversationID: String) async throws -> Client_GetConversationTypeResponse {
        var request = Client_GetConversationTypeRequest()
        request.conversationID = conversationID

        let response: Client_GetConversationTypeResponse = try await sessionHandler.sendRequest(
            action: .getConversationType,
            payload: request
        )
        return response
    }

    /// Send a raw update-conversation request.
    public func updateConversation(_ request: Client_UpdateConversationRequest) async throws -> Client_UpdateConversationResponse {
        let response: Client_UpdateConversationResponse = try await sessionHandler.sendRequest(
            action: .updateConversation,
            payload: request
        )
        return response
    }

    /// Delete a conversation.
    /// - Parameters:
    ///   - conversationID: Conversation ID to delete.
    ///   - phone: Optional phone number (some accounts include it in the delete payload).
    /// - Returns: Whether the server reported success.
    public func deleteConversation(
        conversationID: String,
        phone: String? = nil
    ) async throws -> Bool {
        var deleteData = Client_DeleteConversationData()
        deleteData.conversationID = conversationID
        if let phone {
            deleteData.phone = phone
        }

        var request = Client_UpdateConversationRequest()
        request.action = .delete
        request.conversationID = conversationID
        request.deleteData = deleteData

        let response = try await updateConversation(request)
        return response.success
    }

    // MARK: - Messages

    /// Fetch messages from a conversation
    /// - Parameters:
    ///   - conversationID: The conversation ID
    ///   - count: Number of messages to fetch
    /// - Returns: List of messages
    public func fetchMessages(
        conversationID: String,
        count: Int = 25
    ) async throws -> [Conversations_Message] {
        let response = try await fetchMessagesPage(conversationID: conversationID, count: count, cursor: nil)
        return response.messages
    }

    /// Fetch a page of messages from a conversation (supports pagination via cursor).
    /// - Parameters:
    ///   - conversationID: The conversation ID
    ///   - count: Number of messages to fetch
    ///   - cursor: Cursor for pagination (from a previous response)
    /// - Returns: Full list-messages response (messages + cursor metadata)
    public func fetchMessagesPage(
        conversationID: String,
        count: Int = 25,
        cursor: Client_Cursor? = nil
    ) async throws -> Client_ListMessagesResponse {
        var request = Client_ListMessagesRequest()
        request.conversationID = conversationID
        request.count = Int64(count)
        if let cursor {
            request.cursor = cursor
        }

        let response: Client_ListMessagesResponse = try await sessionHandler.sendRequest(
            action: .listMessages,
            payload: request
        )
        return response
    }

    /// Fetch messages with an optional cursor, returning both messages and next cursor.
    public func fetchMessages(
        conversationID: String,
        count: Int = 25,
        cursor: Client_Cursor?
    ) async throws -> (messages: [Conversations_Message], cursor: Client_Cursor?) {
        let response = try await fetchMessagesPage(conversationID: conversationID, count: count, cursor: cursor)
        return (messages: response.messages, cursor: response.hasCursor ? response.cursor : nil)
    }

    /// Send a text message
    /// - Parameters:
    ///   - conversationID: The conversation ID
    ///   - text: The message text
    /// - Returns: Send response with message ID
    public func sendMessage(
        conversationID: String,
        text: String
    ) async throws -> Client_SendMessageResponse {
        var request = Client_SendMessageRequest()
        request.conversationID = conversationID

        var payload = Client_MessagePayload()
        var content = Client_MessagePayloadContent()
        content.messageContent = Conversations_MessageContent.with {
            $0.content = text
        }
        payload.messagePayloadContent = content
        request.messagePayload = payload

        return try await sendMessage(request)
    }

    /// Send a raw send-message request.
    public func sendMessage(_ request: Client_SendMessageRequest) async throws -> Client_SendMessageResponse {
        let response: Client_SendMessageResponse = try await sessionHandler.sendRequest(
            action: .sendMessage,
            payload: request
        )
        return response
    }

    /// Send a reaction to a message
    /// - Parameters:
    ///   - messageID: The message ID to react to
    ///   - emoji: The emoji to send
    ///   - action: Add, remove, or switch reaction
    public func sendReaction(
        messageID: String,
        emoji: String,
        action: Client_SendReactionRequest.Action = .add
    ) async throws {
        var request = Client_SendReactionRequest()
        request.messageID = messageID

        var reactionData = Conversations_ReactionData()
        reactionData.unicode = emoji
        reactionData.type = .custom
        request.reactionData = reactionData

        request.action = action

        _ = try await sendReaction(request)
    }

    /// Send a raw send-reaction request.
    public func sendReaction(_ request: Client_SendReactionRequest) async throws -> Client_SendReactionResponse {
        let response: Client_SendReactionResponse = try await sessionHandler.sendRequest(
            action: .sendReaction,
            payload: request
        )
        return response
    }

    /// Delete a message.
    /// - Parameter messageID: Message ID to delete.
    /// - Returns: Whether the server reported success.
    public func deleteMessage(messageID: String) async throws -> Bool {
        var request = Client_DeleteMessageRequest()
        request.messageID = messageID

        let response = try await deleteMessage(request)
        return response.success
    }

    /// Delete a message with a raw request.
    public func deleteMessage(_ request: Client_DeleteMessageRequest) async throws -> Client_DeleteMessageResponse {
        let response: Client_DeleteMessageResponse = try await sessionHandler.sendRequest(
            action: .deleteMessage,
            payload: request
        )
        return response
    }

    /// Update a conversation's status (e.g. archive/unarchive).
    public func updateConversationStatus(
        conversationID: String,
        status: Conversations_ConversationStatus
    ) async throws {
        var data = Client_UpdateConversationData()
        data.conversationID = conversationID
        data.status = status

        var request = Client_UpdateConversationRequest()
        request.conversationID = conversationID
        request.updateData = data

        _ = try await updateConversation(request)
    }

    /// Mute or unmute a conversation.
    public func setConversationMuted(
        conversationID: String,
        isMuted: Bool
    ) async throws {
        var data = Client_UpdateConversationData()
        data.conversationID = conversationID
        data.mute = isMuted ? .mute : .unmute

        var request = Client_UpdateConversationRequest()
        request.conversationID = conversationID
        request.updateData = data

        _ = try await updateConversation(request)
    }

    /// Mark a message as read
    /// - Parameters:
    ///   - conversationID: The conversation ID
    ///   - messageID: The message ID
    public func markRead(
        conversationID: String,
        messageID: String
    ) async throws {
        var request = Client_MessageReadRequest()
        request.conversationID = conversationID
        request.messageID = messageID

        try await sessionHandler.sendRequestNoWait(
            action: .messageRead,
            payload: request
        )
    }

    /// Send typing indicator (start/stop).
    public func setTyping(
        conversationID: String,
        isTyping: Bool,
        simPayload: Settings_SIMPayload? = nil
    ) async throws {
        var request = Client_TypingUpdateRequest()
        var dataMsg = Client_TypingUpdateRequest.DataMessage()
        dataMsg.conversationID = conversationID
        dataMsg.typing = isTyping
        request.data = dataMsg
        if let simPayload {
            request.simpayload = simPayload
        }

        try await sessionHandler.sendRequestNoWait(
            action: .typingUpdates,
            payload: request
        )
    }

    /// Convenience: start typing indicator.
    public func setTyping(conversationID: String) async throws {
        try await setTyping(conversationID: conversationID, isTyping: true)
    }

    /// Go libgm parity overload: always sends a "typing=true" update.
    public func setTyping(
        conversationID: String,
        simPayload: Settings_SIMPayload?
    ) async throws {
        try await setTyping(conversationID: conversationID, isTyping: true, simPayload: simPayload)
    }

    /// Notify Ditto activity (used for Google account sessions).
    public func notifyDittoActivity() async throws -> Client_NotifyDittoActivityResponse {
        var request = Client_NotifyDittoActivityRequest()
        request.success = true

        let response: Client_NotifyDittoActivityResponse = try await sessionHandler.sendRequest(
            action: .notifyDittoActivity,
            payload: request
        )
        return response
    }

    /// Fetch the full-size image payload for a message.
    public func getFullSizeImage(messageID: String, actionMessageID: String) async throws -> Client_GetFullSizeImageResponse {
        var request = Client_GetFullSizeImageRequest()
        request.messageID = messageID
        request.actionMessageID = actionMessageID

        let response: Client_GetFullSizeImageResponse = try await sessionHandler.sendRequest(
            action: .getFullSizeImage,
            payload: request
        )
        return response
    }

    // MARK: - Contacts

    /// List all contacts
    /// - Returns: List of contacts
    public func listContacts() async throws -> [Conversations_Contact] {
        let response = try await listContactsResponse()
        return response.contacts
    }

    public func listContactsResponse() async throws -> Client_ListContactsResponse {
        var request = Client_ListContactsRequest()
        request.i1 = 1
        request.i2 = 350
        request.i3 = 50

        let response: Client_ListContactsResponse = try await sessionHandler.sendRequest(
            action: .listContacts,
            payload: request
        )
        return response
    }

    /// List top contacts
    /// - Returns: List of top contacts
    public func listTopContacts() async throws -> [Conversations_Contact] {
        let response = try await listTopContactsResponse()
        return response.contacts
    }

    public func listTopContactsResponse(count: Int32 = 8) async throws -> Client_ListTopContactsResponse {
        var request = Client_ListTopContactsRequest()
        request.count = count

        let response: Client_ListTopContactsResponse = try await sessionHandler.sendRequest(
            action: .listTopContacts,
            payload: request
        )
        return response
    }

    public func getParticipantThumbnail(participantIDs: [String]) async throws -> Client_GetThumbnailResponse {
        var request = Client_GetThumbnailRequest()
        request.identifiers = participantIDs

        let response: Client_GetThumbnailResponse = try await sessionHandler.sendRequest(
            action: .getParticipantsThumbnail,
            payload: request
        )
        return response
    }

    public func getParticipantThumbnail(participantIDs: String...) async throws -> Client_GetThumbnailResponse {
        try await getParticipantThumbnail(participantIDs: participantIDs)
    }

    public func getContactThumbnail(contactIDs: [String]) async throws -> Client_GetThumbnailResponse {
        var request = Client_GetThumbnailRequest()
        request.identifiers = contactIDs

        let response: Client_GetThumbnailResponse = try await sessionHandler.sendRequest(
            action: .getContactsThumbnail,
            payload: request
        )
        return response
    }

    public func getContactThumbnail(contactIDs: String...) async throws -> Client_GetThumbnailResponse {
        try await getContactThumbnail(contactIDs: contactIDs)
    }

    // MARK: - Compose / Conversation Creation

    /// Get or create a conversation using a raw request.
    public func getOrCreateConversation(
        _ request: Client_GetOrCreateConversationRequest
    ) async throws -> Client_GetOrCreateConversationResponse {
        let response: Client_GetOrCreateConversationResponse = try await sessionHandler.sendRequest(
            action: .getOrCreateConversation,
            payload: request
        )
        return response
    }

    /// Get or create a conversation for the provided phone numbers.
    ///
    /// This is used to start a new 1:1 conversation (one number) or create a group.
    public func getOrCreateConversation(
        numbers: [String],
        rcsGroupName: String? = nil,
        createRCSGroup: Bool = false
    ) async throws -> Client_GetOrCreateConversationResponse {
        var request = Client_GetOrCreateConversationRequest()
        request.numbers = numbers.map { number in
            var cn = Conversations_ContactNumber()
            // Go libgm comment: 7 seems to mean "user input".
            cn.mysteriousInt = 7
            cn.number = number
            cn.number2 = number
            return cn
        }
        if let rcsGroupName, !rcsGroupName.isEmpty {
            request.rcsgroupName = rcsGroupName
        }
        if createRCSGroup {
            request.createRcsgroup = true
        }

        return try await getOrCreateConversation(request)
    }

    // MARK: - Media

    /// Upload media file
    /// - Parameters:
    ///   - data: Raw media data
    ///   - fileName: File name
    ///   - mimeType: MIME type (e.g., "image/jpeg")
    /// - Returns: MediaContent with upload info and decryption key
    public func uploadMedia(
        data: Data,
        fileName: String,
        mimeType: String
    ) async throws -> Conversations_MediaContent {
        return try await mediaHandler.uploadMedia(
            data: data,
            fileName: fileName,
            mimeType: mimeType
        )
    }

    /// Download media file
    /// - Parameters:
    ///   - mediaID: Media ID to download
    ///   - decryptionKey: Key to decrypt the media
    /// - Returns: Decrypted media data
    public func downloadMedia(
        mediaID: String,
        decryptionKey: Data
    ) async throws -> Data {
        return try await mediaHandler.downloadMedia(
            mediaID: mediaID,
            decryptionKey: decryptionKey
        )
    }

    /// Download an avatar (contact photo) by URL.
    ///
    /// This uses the same header shape as Messages for Web, but intentionally omits
    /// `x-user-agent` and `x-goog-api-key` (matches Go libgm `DownloadAvatar`).
    public func downloadAvatar(url: String) async throws -> Data {
        guard let u = URL(string: url) else {
            throw GMHTTPError.invalidResponse
        }

        var req = URLRequest(url: u)
        req.httpMethod = "GET"
        req.setValue(GMConstants.secCHUA, forHTTPHeaderField: "sec-ch-ua")
        req.setValue(GMConstants.secCHUAMobile, forHTTPHeaderField: "sec-ch-ua-mobile")
        req.setValue(GMConstants.userAgent, forHTTPHeaderField: "user-agent")
        req.setValue("\"\(GMConstants.secCHUAPlatform)\"", forHTTPHeaderField: "sec-ch-ua-platform")
        req.setValue("*/*", forHTTPHeaderField: "accept")
        req.setValue(GMConstants.messagesBaseURL, forHTTPHeaderField: "origin")
        req.setValue("cross-site", forHTTPHeaderField: "sec-fetch-site")
        req.setValue("cors", forHTTPHeaderField: "sec-fetch-mode")
        req.setValue("empty", forHTTPHeaderField: "sec-fetch-dest")
        req.setValue("\(GMConstants.messagesBaseURL)/", forHTTPHeaderField: "referer")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "accept-language")

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw GMHTTPError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw GMHTTPError.httpError(statusCode: http.statusCode, body: data)
        }
        return data
    }

    /// Send a message with media attachment
    /// - Parameters:
    ///   - conversationID: The conversation ID
    ///   - mediaData: Raw media data
    ///   - fileName: File name
    ///   - mimeType: MIME type
    ///   - text: Optional text to include with media
    /// - Returns: Send response with message ID
    public func sendMediaMessage(
        conversationID: String,
        mediaData: Data,
        fileName: String,
        mimeType: String,
        text: String? = nil
    ) async throws -> Client_SendMessageResponse {
        // Upload media first
        let mediaContent = try await uploadMedia(
            data: mediaData,
            fileName: fileName,
            mimeType: mimeType
        )

        // Build message with media
        var request = Client_SendMessageRequest()
        request.conversationID = conversationID

        var payload = Client_MessagePayload()
        var content = Client_MessagePayloadContent()

        if let text = text, !text.isEmpty {
            content.messageContent = Conversations_MessageContent.with {
                $0.content = text
            }
        }

        // Add media info
        var messageInfo = Conversations_MessageInfo()
        messageInfo.mediaContent = mediaContent
        payload.messageInfo = [messageInfo]
        payload.messagePayloadContent = content
        request.messagePayload = payload

        let response: Client_SendMessageResponse = try await sessionHandler.sendRequest(
            action: .sendMessage,
            payload: request
        )

        return response
    }

    // MARK: - Settings / Push

    public func updateSettings(_ request: Client_SettingsUpdateRequest) async throws {
        try await sessionHandler.sendRequestNoWait(
            action: .settingsUpdate,
            payload: request
        )
    }

    /// Register web push keys and enable push (parity with Go libgm `RegisterPush`).
    public func registerPush(keys: PushKeys) async throws {
        let existing = await authData.pushKeys

        // Go libgm only forces a refresh when first registering, or when the endpoint URL changes.
        if existing == nil || existing?.url != keys.url {
            try await refreshTokenIfNeeded(pushKeysOverride: keys)
        }

        var settings = Client_SettingsUpdateRequest()
        var pushSettings = Client_SettingsUpdateRequest.PushSettings()
        pushSettings.enabled = true
        settings.pushSettings = pushSettings

        try await updateSettings(settings)
        await authData.setPushKeys(keys)
    }

    // MARK: - Private Helpers

    private func refreshTokenIfNeeded(pushKeysOverride: PushKeys? = nil) async throws {
        guard await authData.browser != nil else { return }
        if pushKeysOverride == nil {
            guard await authData.needsTokenRefresh else { return }
        }

        var request = Authentication_RegisterRefreshRequest()

        let requestID = UUID().uuidString.lowercased()
        let timestamp = Int64(Date().timeIntervalSince1970 * 1_000_000) // microseconds

        var authMessage = Authentication_AuthMessage()
        authMessage.requestID = requestID
        if let token = await authData.tachyonAuthToken {
            authMessage.tachyonAuthToken = token
        }
        authMessage.network = await authData.authNetwork
        authMessage.configVersion = GMConstants.makeConfigVersion()
        request.messageAuth = authMessage

        if let browser = await authData.browser {
            request.currBrowserDevice = browser
        }

        request.unixTimestamp = timestamp

        let refreshKey = await authData.refreshKey
        request.signature = try refreshKey.signRefreshRequest(requestID: requestID, timestamp: timestamp)

        var parameters = Authentication_RegisterRefreshRequest.Parameters()
        parameters.emptyArr = Util_EmptyArr()

        let keys: PushKeys?
        if let pushKeysOverride {
            keys = pushKeysOverride
        } else {
            keys = await authData.pushKeys
        }
        if let keys {
            var more = Authentication_RegisterRefreshRequest.MoreParameters()
            more.three = 3
            var push = Authentication_RegisterRefreshRequest.PushRegistration()
            push.type = "messages_web"
            push.url = keys.url
            push.p256Dh = keys.p256dh.base64URLEncodedStringNoPadding()
            push.auth = keys.auth.base64URLEncodedStringNoPadding()
            more.pushReg = push
            parameters.moreParameters = more
        }
        request.parameters = parameters

        request.messageType = 2

        let response = try await httpClient.post(
            url: GMConstants.registerRefreshURL,
            encoding: .pblite,
            request: request,
            response: Authentication_RegisterRefreshResponse.self
        )

        if response.hasTokenData {
            await authData.updateToken(token: response.tokenData.tachyonAuthToken, ttl: response.tokenData.ttl)
            await emitEvent(.authTokenRefreshed)
        }
    }

    /// Emit an event
    private func emitEvent(_ event: GMEvent) async {
        await eventHandler?.handleEvent(event)
    }

    // MARK: - Persistence

    /// Save auth data to storage
    /// - Parameter store: Auth data store to save to
    public func saveAuthData(to store: AuthDataStore) async throws {
        try await store.save(authData)
    }

    /// Create a client from saved auth data
    /// - Parameters:
    ///   - store: Auth data store to load from
    ///   - eventHandler: Event handler for receiving events
    /// - Returns: Client with loaded auth data, or nil if no saved data
    public static func loadFromStore(
        _ store: AuthDataStore,
        eventHandler: (any GMEventHandler)? = nil,
        autoReconnectAfterPairing: Bool = true
    ) async throws -> GMClient? {
        guard let authData = try store.load() else {
            return nil
        }
        return await GMClient(
            authData: authData,
            eventHandler: eventHandler,
            autoReconnectAfterPairing: autoReconnectAfterPairing
        )
    }

    /// Create a client, loading from store if available
    /// - Parameters:
    ///   - store: Auth data store to check
    ///   - eventHandler: Event handler for receiving events
    /// - Returns: Client (either loaded or new)
    public static func loadOrCreate(
        from store: AuthDataStore,
        eventHandler: (any GMEventHandler)? = nil,
        autoReconnectAfterPairing: Bool = true
    ) async throws -> GMClient {
        if let client = try await loadFromStore(
            store,
            eventHandler: eventHandler,
            autoReconnectAfterPairing: autoReconnectAfterPairing
        ) {
            return client
        }
        return await GMClient(eventHandler: eventHandler, autoReconnectAfterPairing: autoReconnectAfterPairing)
    }
}
