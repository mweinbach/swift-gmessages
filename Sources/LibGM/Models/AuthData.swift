import Foundation
import GMCrypto
import GMProto

/// Authentication and session data for a Google Messages connection
public actor AuthData {
    /// AES-CTR encryption helper for request/response encryption
    public var requestCrypto: AESCTRHelper

    /// ECDSA key for token refresh signatures
    public var refreshKey: JWK

    /// Browser device information
    public var browser: Authentication_Device?

    /// Mobile device information
    public var mobile: Authentication_Device?

    /// Tachyon authentication token
    public var tachyonAuthToken: Data?

    /// Token expiry time
    public var tachyonExpiry: Date?

    /// Token TTL in microseconds
    public var tachyonTTL: Int64?

    /// Device session ID
    public var sessionID: UUID

    /// Destination registration ID (for Google account auth)
    public var destRegID: UUID?

    /// Pairing session ID
    public var pairingID: UUID?

    /// HTTP cookies for authenticated requests
    public var cookies: [String: String]

    /// Web encryption key (unused but stored)
    public var webEncryptionKey: Data?

    /// Web push keys (used to register push with `RegisterRefresh`)
    public var pushKeys: PushKeys?

    /// Create new AuthData with generated keys
    public init() {
        self.requestCrypto = AESCTRHelper()
        self.refreshKey = JWK.generate()
        self.sessionID = UUID()
        self.cookies = [:]
        self.pushKeys = nil
    }

    /// Create AuthData from existing data (for persistence)
    public init(
        requestCrypto: AESCTRHelper,
        refreshKey: JWK,
        browser: Authentication_Device? = nil,
        mobile: Authentication_Device? = nil,
        tachyonAuthToken: Data? = nil,
        tachyonExpiry: Date? = nil,
        tachyonTTL: Int64? = nil,
        sessionID: UUID = UUID(),
        destRegID: UUID? = nil,
        pairingID: UUID? = nil,
        cookies: [String: String] = [:],
        webEncryptionKey: Data? = nil,
        pushKeys: PushKeys? = nil
    ) {
        self.requestCrypto = requestCrypto
        self.refreshKey = refreshKey
        self.browser = browser
        self.mobile = mobile
        self.tachyonAuthToken = tachyonAuthToken
        self.tachyonExpiry = tachyonExpiry
        self.tachyonTTL = tachyonTTL
        self.sessionID = sessionID
        self.destRegID = destRegID
        self.pairingID = pairingID
        self.cookies = cookies
        self.webEncryptionKey = webEncryptionKey
        self.pushKeys = pushKeys
    }

    /// Create from serialized form (used by `AuthDataStore`).
    public init(from serialized: Serialized) {
        var browser: Authentication_Device?
        if let userID = serialized.browserUserID {
            browser = Authentication_Device()
            browser?.userID = userID
            browser?.sourceID = serialized.browserSourceID ?? ""
            browser?.network = serialized.browserNetwork ?? ""
        }

        var mobile: Authentication_Device?
        if let userID = serialized.mobileUserID {
            mobile = Authentication_Device()
            mobile?.userID = userID
            mobile?.sourceID = serialized.mobileSourceID ?? ""
            mobile?.network = serialized.mobileNetwork ?? ""
        }

        self.init(
            requestCrypto: serialized.requestCrypto,
            refreshKey: serialized.refreshKey,
            browser: browser,
            mobile: mobile,
            tachyonAuthToken: serialized.tachyonAuthToken,
            tachyonExpiry: serialized.tachyonExpiry,
            tachyonTTL: serialized.tachyonTTL,
            sessionID: serialized.sessionID,
            destRegID: serialized.destRegID,
            pairingID: serialized.pairingID,
            cookies: serialized.cookies,
            webEncryptionKey: serialized.webEncryptionKey,
            pushKeys: serialized.pushKeys
        )
    }

    /// Check if authenticated with Google account
    public var isGoogleAccount: Bool {
        destRegID != nil
    }

    /// Check if we have cookies set (Gaia pairing/authorization).
    public var hasCookies: Bool {
        !cookies.isEmpty
    }

    /// Whether to use the `instantmessaging-pa.clients6.google.com` host variant for Messaging RPCs.
    ///
    /// The Go reference implementation uses the "google" hostname in QR mode as well.
    public var shouldUseGoogleHost: Bool {
        !isGoogleAccount || hasCookies
    }

    /// Network type for authentication
    public var authNetwork: String {
        isGoogleAccount ? GMConstants.googleNetwork : ""
    }

    /// Update cookies
    public func setCookies(_ newCookies: [String: String]) {
        cookies = newCookies
    }

    /// Add a single cookie
    public func setCookie(_ name: String, value: String) {
        cookies[name] = value
    }

    /// Check if token needs refresh
    public var needsTokenRefresh: Bool {
        guard let expiry = tachyonExpiry else { return true }
        // Match Go libgm: refresh at least 1 hour before expiry.
        return Date() >= expiry.addingTimeInterval(-3600)
    }

    /// Update token data
    public func updateToken(token: Data, ttl: Int64) {
        // Some responses provide TTL=0; treat as 24 hours (matches Go libgm).
        let effectiveTTL: Int64 = ttl == 0 ? 24 * 60 * 60 * 1_000_000 : ttl
        tachyonAuthToken = token
        tachyonTTL = effectiveTTL
        tachyonExpiry = Date().addingTimeInterval(Double(effectiveTTL) / 1_000_000)  // TTL is in microseconds
    }

    /// Set destination registration ID
    public func setDestRegID(_ id: UUID) {
        destRegID = id
    }

    public func setSessionID(_ id: UUID) {
        sessionID = id
    }

    /// Set pairing ID
    public func setPairingID(_ id: UUID) {
        pairingID = id
    }

    /// Set browser device
    public func setBrowser(_ device: Authentication_Device) {
        browser = device
    }

    /// Set mobile device
    public func setMobile(_ device: Authentication_Device) {
        mobile = device
    }

    /// Update request crypto keys
    public func updateRequestCrypto(aesKey: Data, hmacKey: Data) {
        requestCrypto = AESCTRHelper(aesKey: aesKey, hmacKey: hmacKey)
    }

    public func setWebEncryptionKey(_ key: Data?) {
        webEncryptionKey = key
    }

    public func setPushKeys(_ keys: PushKeys?) {
        pushKeys = keys
    }
}

// MARK: - Codable Support

extension AuthData {
    /// Serializable version of AuthData for persistence
    public struct Serialized: Codable {
        public var requestCrypto: AESCTRHelper
        public var refreshKey: JWK
        public var browserUserID: Int64?
        public var browserSourceID: String?
        public var browserNetwork: String?
        public var mobileUserID: Int64?
        public var mobileSourceID: String?
        public var mobileNetwork: String?
        public var tachyonAuthToken: Data?
        public var tachyonExpiry: Date?
        public var tachyonTTL: Int64?
        public var sessionID: UUID
        public var destRegID: UUID?
        public var pairingID: UUID?
        public var cookies: [String: String]
        public var webEncryptionKey: Data?
        public var pushKeys: PushKeys?
    }

    /// Convert to serializable form
    public func serialized() -> Serialized {
        Serialized(
            requestCrypto: requestCrypto,
            refreshKey: refreshKey,
            browserUserID: browser?.userID,
            browserSourceID: browser?.sourceID,
            browserNetwork: browser?.network,
            mobileUserID: mobile?.userID,
            mobileSourceID: mobile?.sourceID,
            mobileNetwork: mobile?.network,
            tachyonAuthToken: tachyonAuthToken,
            tachyonExpiry: tachyonExpiry,
            tachyonTTL: tachyonTTL,
            sessionID: sessionID,
            destRegID: destRegID,
            pairingID: pairingID,
            cookies: cookies,
            webEncryptionKey: webEncryptionKey,
            pushKeys: pushKeys
        )
    }

    // `AuthData` has a designated `init(from:)` in the actor declaration.
}

/// Web push keys used for push registration in `RegisterRefresh`.
public struct PushKeys: Codable, Sendable, Equatable {
    public var url: String
    public var p256dh: Data
    public var auth: Data

    public init(url: String, p256dh: Data, auth: Data) {
        self.url = url
        self.p256dh = p256dh
        self.auth = auth
    }
}

extension Data {
    /// Base64 URL-safe encoding without padding (matches Go's `base64.RawURLEncoding`).
    func base64URLEncodedStringNoPadding() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
