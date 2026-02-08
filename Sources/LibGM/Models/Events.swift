import Foundation
import GMProto

/// Events emitted by the Google Messages client
public enum GMEvent: Sendable {
    // MARK: - Authentication Events

    /// QR code generated for pairing
    case qrCode(url: String)

    /// Gaia pairing emoji for user verification
    case gaiaPairingEmoji(emoji: String)

    /// Pairing completed successfully
    case pairSuccessful(phoneID: String, data: Authentication_PairedData?)

    /// Auth token was refreshed
    case authTokenRefreshed

    /// Logged out from Google account
    case gaiaLoggedOut

    // MARK: - Connection Events

    /// Fatal error during listening (requires reconnection)
    case listenFatalError(Error)

    /// Temporary error during listening (will retry)
    case listenTemporaryError(Error)

    /// Connection recovered after error
    case listenRecovered

    /// Ping failed (phone may be unresponsive)
    case pingFailed(error: Error, count: Int)

    /// Browser session is active
    case browserActive(sessionID: String)

    /// Phone stopped responding
    case phoneNotResponding

    /// Phone is responding again
    case phoneRespondingAgain

    /// No data received in timeout period
    case noDataReceived

    // MARK: - Data Events

    /// New message received
    case message(Conversations_Message, isOld: Bool)

    /// Conversation updated
    case conversation(Conversations_Conversation)

    /// Typing indicator
    case typing(Events_TypingData)

    /// User alert/notification
    case userAlert(Events_UserAlertEvent)

    /// Settings changed
    case settings(Settings_Settings)

    /// Account change event
    case accountChange(Events_AccountChangeOrSomethingEvent, isFake: Bool)

    // MARK: - Error Events

    /// Request error
    case requestError(ErrorInfo)

    /// HTTP error
    case httpError(HTTPErrorInfo)
}

/// Information about a request error
public struct ErrorInfo: Sendable {
    public let action: String
    public let errorResponse: Authentication_ErrorResponse?

    public init(action: String, errorResponse: Authentication_ErrorResponse? = nil) {
        self.action = action
        self.errorResponse = errorResponse
    }
}

/// Information about an HTTP error
public struct HTTPErrorInfo: Sendable {
    public let action: String
    public let statusCode: Int
    public let body: Data?

    public init(action: String, statusCode: Int, body: Data? = nil) {
        self.action = action
        self.statusCode = statusCode
        self.body = body
    }
}

/// Protocol for receiving Google Messages events
public protocol GMEventHandler: AnyObject, Sendable {
    /// Called when an event is received
    func handleEvent(_ event: GMEvent) async
}

/// Event handler using a closure
public actor ClosureEventHandler: GMEventHandler {
    private let handler: @Sendable (GMEvent) async -> Void

    public init(handler: @escaping @Sendable (GMEvent) async -> Void) {
        self.handler = handler
    }

    public func handleEvent(_ event: GMEvent) async {
        await handler(event)
    }
}
