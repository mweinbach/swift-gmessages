import Foundation
import GMProto

/// Constants and configuration for Google Messages protocol
public enum GMConstants {
    // MARK: - Base URLs

    /// Base URL for Messages web origin (used in headers)
    public static let messagesBaseURL = "https://messages.google.com"

    /// Base URL for Instant Messaging backend (Pairing, Upload)
    public static let instantMessagingBaseURL = "https://instantmessaging-pa.googleapis.com"

    /// Alternate hostname used by Messages web for Messaging/Registration RPCs.
    public static let instantMessagingBaseURLGoogle = "https://instantmessaging-pa.clients6.google.com"

    // MARK: - RPC Base Paths

    public static let pairingBaseURL = instantMessagingBaseURL + "/$rpc/google.internal.communications.instantmessaging.v1.Pairing"
    public static let messagingBaseURL = instantMessagingBaseURL + "/$rpc/google.internal.communications.instantmessaging.v1.Messaging"
    public static let messagingBaseURLGoogle = instantMessagingBaseURLGoogle + "/$rpc/google.internal.communications.instantmessaging.v1.Messaging"
    public static let registrationBaseURL = instantMessagingBaseURLGoogle + "/$rpc/google.internal.communications.instantmessaging.v1.Registration"

    // MARK: - RPC Endpoints

    public static let registerPhoneRelayURL = pairingBaseURL + "/RegisterPhoneRelay"
    public static let refreshPhoneRelayURL = pairingBaseURL + "/RefreshPhoneRelay"
    public static let webEncryptionKeyURL = pairingBaseURL + "/GetWebEncryptionKey"
    public static let revokeRelayPairingURL = pairingBaseURL + "/RevokeRelayPairing"

    public static let receiveMessagesURL = messagingBaseURL + "/ReceiveMessages"
    public static let sendMessageURL = messagingBaseURL + "/SendMessage"
    public static let ackMessagesURL = messagingBaseURL + "/AckMessages"

    public static let receiveMessagesURLGoogle = messagingBaseURLGoogle + "/ReceiveMessages"
    public static let sendMessageURLGoogle = messagingBaseURLGoogle + "/SendMessage"
    public static let ackMessagesURLGoogle = messagingBaseURLGoogle + "/AckMessages"

    public static let signInGaiaURL = registrationBaseURL + "/SignInGaia"
    public static let registerRefreshURL = registrationBaseURL + "/RegisterRefresh"

    // MARK: - Messages Web Config

    public static let configURL = messagesBaseURL + "/web/config"

    // MARK: - Media

    public static let uploadMediaURL = instantMessagingBaseURL + "/upload"

    // MARK: - QR Code

    /// Base URL used in the QR code for Messages for Web pairing.
    public static let qrCodeURLBase = "https://support.google.com/messages/?p=web_computer#?c="

    // MARK: - Network Types

    /// Network identifier used during QR registration.
    public static let qrNetwork = "Bugle"

    /// Network identifier used for Google account (Gaia/Ditto) pairing.
    public static let googleNetwork = "GDitto"

    // MARK: - Headers

    public static let contentTypeProtobuf = "application/x-protobuf"
    public static let contentTypePBLite = "application/json+protobuf"

    // Observed constants from Messages for Web.
    public static let googleAPIKey = "AIzaSyCA4RsOZUFrm9whhtGosPlJLmVPnfSHKz8"
    public static let userAgent = "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36"
    public static let secCHUA = "\"Google Chrome\";v=\"141\", \"Chromium\";v=\"141\", \"Not-A.Brand\";v=\"24\""
    public static let secCHUAMobile = "?1"
    public static let secCHUAPlatform = "Android"
    public static let xUserAgent = "grpc-web-javascript/0.1"

    // MARK: - Browser Details

    /// Create browser details for requests
    public static func makeBrowserDetails(
        userAgent: String = userAgent,
        browserType: Authentication_BrowserType = .other,
        os: String = "libgm",
        deviceType: Authentication_DeviceType = .tablet
    ) -> Authentication_BrowserDetails {
        var details = Authentication_BrowserDetails()
        details.userAgent = userAgent
        details.browserType = browserType
        details.os = os
        details.deviceType = deviceType
        return details
    }

    // MARK: - Config Version

    /// Current config version for requests
    public static func makeConfigVersion() -> Authentication_ConfigVersion {
        var config = Authentication_ConfigVersion()
        // These values are from observing the protocol (kept in sync with Go libgm).
        config.year = 2025
        config.month = 11
        config.day = 6
        config.v1 = 4
        config.v2 = 6
        return config
    }

    // MARK: - Timeouts

    /// Long polling timeout in seconds
    public static let longPollTimeout: TimeInterval = 30

    /// Ditto ping interval in seconds (15 minutes)
    public static let dittoPingInterval: TimeInterval = 15 * 60

    /// Max ditto ping interval in seconds (1 hour)
    public static let maxDittoPingInterval: TimeInterval = 60 * 60

    /// Phone not responding threshold (3 failed pings)
    public static let phoneNotRespondingThreshold = 3
}

/// Message types for RPC routing
public enum GMMessageType: Int {
    case unknown = 0
    case bugleMessage = 2
    case gaia1 = 3
    case bugleAnnotation = 16
    case gaia2 = 20
}

/// Route types for RPC messages
public enum GMBugleRoute: Int {
    case unknown = 0
    case dataEvent = 19
    case pairEvent = 14
    case gaiaEvent = 7
}
