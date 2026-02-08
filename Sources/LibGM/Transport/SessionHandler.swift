import Foundation
import GMCrypto
import GMProto
@preconcurrency import SwiftProtobuf

/// Parameters for sending a message through the Messaging.SendMessage RPC.
public struct GMSendMessageParams: Sendable {
    public var action: Rpc_ActionType
    public var data: (any SwiftProtobuf.Message)?

    /// Override the outgoing request ID (otherwise a UUID is generated).
    public var requestID: String?

    /// When true, omit TTL from the wrapper message.
    public var omitTTL: Bool

    /// Override TTL in microseconds (0 = use default behavior).
    public var customTTL: Int64

    /// When true, send the payload in `unencryptedProtoData` instead of `encryptedProtoData`.
    public var dontEncrypt: Bool

    /// Override the wrapper message type.
    public var messageType: Rpc_MessageType

    public init(
        action: Rpc_ActionType,
        data: (any SwiftProtobuf.Message)? = nil,
        requestID: String? = nil,
        omitTTL: Bool = false,
        customTTL: Int64 = 0,
        dontEncrypt: Bool = false,
        messageType: Rpc_MessageType = .unknownMessageType
    ) {
        self.action = action
        self.data = data
        self.requestID = requestID
        self.omitTTL = omitTTL
        self.customTTL = customTTL
        self.dontEncrypt = dontEncrypt
        self.messageType = messageType
    }
}

public actor SessionHandler {
    public struct IncomingDataEvent: Sendable {
        public let incoming: Rpc_IncomingRPCMessage
        public let message: Rpc_RPCMessageData
        public let decryptedData: Data?

        public var payloadData: Data {
            if let decryptedData {
                return decryptedData
            }
            if !message.unencryptedData.isEmpty {
                return message.unencryptedData
            }
            return Data()
        }
    }

    private let authData: AuthData
    private let httpClient: GMHTTPClient

    private var responseWaiters: [String: CheckedContinuation<IncomingDataEvent, Error>] = [:]

    private static let requestSoftTimeoutSeconds: TimeInterval = 5
    private var onRequestSlow: (@Sendable () async -> Void)?

    private var ackIDs: Set<String> = []
    private var ackTickerTask: Task<Void, Never>?

    private var sessionID: String

    public init(authData: AuthData, httpClient: GMHTTPClient) {
        self.authData = authData
        self.httpClient = httpClient
        self.sessionID = UUID().uuidString.lowercased()
    }

    func setOnRequestSlow(_ cb: (@Sendable () async -> Void)?) {
        onRequestSlow = cb
    }

    public var currentSessionID: String {
        sessionID
    }

    public func resetSessionID() {
        sessionID = UUID().uuidString.lowercased()
    }

    // MARK: - Message Send

    public func sendMessage<Response: SwiftProtobuf.Message>(
        _ params: GMSendMessageParams,
        response: Response.Type
    ) async throws -> Response {
        let resp = try await sendMessageWithResponse(params)
        return try Response(serializedBytes: resp.payloadData)
    }

    public func sendMessageNoWait(_ params: GMSendMessageParams) async throws {
        try await sendMessageNoResponse(params)
    }

    public func sendRequest<Request: SwiftProtobuf.Message, Response: SwiftProtobuf.Message>(
        action: Rpc_ActionType,
        payload: Request,
        messageType: Rpc_MessageType = .bugleMessage,
        encrypt: Bool = true
    ) async throws -> Response {
        let params = GMSendMessageParams(
            action: action,
            data: payload,
            dontEncrypt: !encrypt,
            messageType: messageType
        )
        let resp = try await sendMessageWithResponse(params)
        return try Response(serializedBytes: resp.payloadData)
    }

    public func sendRequest<Response: SwiftProtobuf.Message>(
        action: Rpc_ActionType,
        messageType: Rpc_MessageType = .bugleMessage,
        encrypt: Bool = true
    ) async throws -> Response {
        let params = GMSendMessageParams(
            action: action,
            data: nil,
            dontEncrypt: !encrypt,
            messageType: messageType
        )
        let resp = try await sendMessageWithResponse(params)
        return try Response(serializedBytes: resp.payloadData)
    }

    public func sendRequestNoWait<Request: SwiftProtobuf.Message>(
        action: Rpc_ActionType,
        payload: Request,
        messageType: Rpc_MessageType = .bugleMessage,
        encrypt: Bool = true,
        requestID: String? = nil,
        omitTTL: Bool = false,
        customTTL: Int64 = 0
    ) async throws {
        let params = GMSendMessageParams(
            action: action,
            data: payload,
            requestID: requestID,
            omitTTL: omitTTL,
            customTTL: customTTL,
            dontEncrypt: !encrypt,
            messageType: messageType
        )
        try await sendMessageNoResponse(params)
    }

    public func sendRequestNoWait(
        action: Rpc_ActionType,
        messageType: Rpc_MessageType = .bugleMessage,
        requestID: String? = nil,
        omitTTL: Bool = false,
        customTTL: Int64 = 0
    ) async throws {
        let params = GMSendMessageParams(
            action: action,
            data: nil,
            requestID: requestID,
            omitTTL: omitTTL,
            customTTL: customTTL,
            dontEncrypt: false,
            messageType: messageType
        )
        try await sendMessageNoResponse(params)
    }

    private func sendMessageNoResponse(_ params: GMSendMessageParams) async throws {
        let (_, outgoing) = try await buildMessage(params)
        let useGoogleHost = await authData.shouldUseGoogleHost
        let url = useGoogleHost ? GMConstants.sendMessageURLGoogle : GMConstants.sendMessageURL
        _ = try await httpClient.post(
            url: url,
            encoding: .pblite,
            request: outgoing,
            response: Rpc_OutgoingRPCResponse.self
        )
    }

    private func sendMessageWithResponse(_ params: GMSendMessageParams) async throws -> IncomingDataEvent {
        let (requestID, outgoing) = try await buildMessage(params)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                responseWaiters[requestID] = cont

                Task { [weak self] in
                    guard let self else { return }
                    do {
                        let useGoogleHost = await self.authData.shouldUseGoogleHost
                        let url = useGoogleHost ? GMConstants.sendMessageURLGoogle : GMConstants.sendMessageURL
                        _ = try await self.httpClient.post(
                            url: url,
                            encoding: .pblite,
                            request: outgoing,
                            response: Rpc_OutgoingRPCResponse.self
                        )
                    } catch {
                        await self.cancelResponse(requestID: requestID, error: error)
                    }
                }

                Task { [weak self] in
                    guard let self else { return }
                    try? await Task.sleep(
                        nanoseconds: UInt64(Self.requestSoftTimeoutSeconds * 1_000_000_000)
                    )
                    await self.handleSoftTimeout(requestID: requestID)
                }
            }
        } onCancel: {
            Task { [weak self] in
                guard let self else { return }
                await self.cancelResponse(requestID: requestID, error: CancellationError())
            }
        }
    }

    private func cancelResponse(requestID: String, error: Error) {
        if let cont = responseWaiters.removeValue(forKey: requestID) {
            cont.resume(throwing: error)
        }
    }

    private func handleSoftTimeout(requestID: String) async {
        guard responseWaiters[requestID] != nil else { return }
        guard let cb = onRequestSlow else { return }
        await cb()
    }

    private func buildMessage(_ params: GMSendMessageParams) async throws -> (requestID: String, message: Rpc_OutgoingRPCMessage) {
        let requestID = (params.requestID ?? UUID().uuidString).lowercased()
        let crypto = await authData.requestCrypto

        var outgoingData = Rpc_OutgoingRPCData()
        outgoingData.requestID = requestID
        outgoingData.action = params.action
        outgoingData.sessionID = sessionID

        if let payload = params.data {
            let payloadBytes = try payload.serializedData()
            if params.dontEncrypt {
                outgoingData.unencryptedProtoData = payloadBytes
            } else {
                outgoingData.encryptedProtoData = try crypto.encrypt(payloadBytes)
            }
        }

        var msg = Rpc_OutgoingRPCMessage()

        if let mobile = await authData.mobile {
            msg.mobile = mobile
        }

        var dataMsg = Rpc_OutgoingRPCMessage.DataMessage()
        dataMsg.requestID = requestID
        dataMsg.bugleRoute = .dataEvent
        dataMsg.messageData = try outgoingData.serializedData()

        var typeMsg = Rpc_OutgoingRPCMessage.DataMessage.TypeMessage()
        typeMsg.emptyArr = Util_EmptyArr()
        typeMsg.messageType = params.messageType == .unknownMessageType ? .bugleMessage : params.messageType
        dataMsg.messageTypeData = typeMsg
        msg.data = dataMsg

        var auth = Rpc_OutgoingRPCMessage.Auth()
        auth.requestID = requestID
        if let token = await authData.tachyonAuthToken {
            auth.tachyonAuthToken = token
        }
        auth.configVersion = GMConstants.makeConfigVersion()
        msg.auth = auth

        if let dest = await authData.destRegID {
            msg.destRegistrationIds = [dest.uuidString.lowercased()]
        }

        if params.customTTL != 0 {
            msg.ttl = params.customTTL
        } else if !params.omitTTL, let ttl = await authData.tachyonTTL {
            msg.ttl = ttl
        }

        return (requestID, msg)
    }

    // MARK: - Response Handling (called by long poll)

    public func receiveResponse(_ incoming: IncomingDataEvent) async -> Bool {
        // Very hacky way to ignore weird messages that come before real responses.
        if await authData.shouldUseGoogleHost {
            switch incoming.message.action {
            case .createGaiaPairingClientInit, .createGaiaPairingClientFinished:
                break
            default:
                if !incoming.message.unencryptedData.isEmpty
                    && incoming.message.encryptedData.isEmpty
                    && incoming.message.encryptedData2.isEmpty
                {
                    return false
                }
            }
        }

        let key = incoming.message.sessionID
        guard let cont = responseWaiters.removeValue(forKey: key) else {
            return false
        }
        cont.resume(returning: incoming)
        return true
    }

    // MARK: - Ack Batching

    public func queueMessageAck(_ messageID: String) {
        ackIDs.insert(messageID)
    }

    public func startAckInterval() {
        guard ackTickerTask == nil else { return }
        ackTickerTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if Task.isCancelled { return }
                await self.sendAckRequest()
            }
        }
    }

    public func stopAckInterval(flush: Bool) async {
        ackTickerTask?.cancel()
        ackTickerTask = nil
        if flush {
            await sendAckRequest()
        }
    }

    public func sendAckRequest() async {
        let ids = ackIDs
        ackIDs.removeAll(keepingCapacity: true)
        guard !ids.isEmpty else { return }

        guard let browser = await authData.browser, let token = await authData.tachyonAuthToken else {
            // Can't ack yet; re-queue.
            ackIDs.formUnion(ids)
            return
        }

        var auth = Authentication_AuthMessage()
        auth.requestID = UUID().uuidString.lowercased()
        auth.tachyonAuthToken = token
        auth.network = await authData.authNetwork
        auth.configVersion = GMConstants.makeConfigVersion()

        var req = Client_AckMessageRequest()
        req.authData = auth
        req.emptyArr = Util_EmptyArr()

        req.acks = ids.map { id in
            var m = Client_AckMessageRequest.Message()
            m.requestID = id
            m.device = browser
            return m
        }

        do {
            let useGoogleHost = await authData.shouldUseGoogleHost
            let url = useGoogleHost ? GMConstants.ackMessagesURLGoogle : GMConstants.ackMessagesURL
            _ = try await httpClient.post(
                url: url,
                encoding: .pblite,
                request: req,
                response: Rpc_OutgoingRPCResponse.self
            )
        } catch {
            // Re-queue on failure.
            ackIDs.formUnion(ids)
        }
    }
}
