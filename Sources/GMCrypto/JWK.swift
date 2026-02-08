import Foundation
import Crypto

/// JSON Web Key (JWK) representation for ECDSA P-256 keys
/// Used for token refresh and pairing authentication
public struct JWK: Codable, Sendable {
    /// Key type (always "EC" for elliptic curve)
    public let kty: String

    /// Curve name (always "P-256")
    public let crv: String

    /// Private key scalar (D coordinate) - base64url encoded
    public let d: RawURLBytes

    /// Public key X coordinate - base64url encoded
    public let x: RawURLBytes

    /// Public key Y coordinate - base64url encoded
    public let y: RawURLBytes

    /// Create a JWK from existing key components
    public init(kty: String = "EC", crv: String = "P-256", d: Data, x: Data, y: Data) {
        self.kty = kty
        self.crv = crv
        self.d = RawURLBytes(d)
        self.x = RawURLBytes(x)
        self.y = RawURLBytes(y)
    }

    /// Generate a new ECDSA P-256 key pair
    public static func generate() -> JWK {
        let privateKey = P256.Signing.PrivateKey()
        let publicKey = privateKey.publicKey

        // Get raw representation
        let privateKeyData = privateKey.rawRepresentation

        // P-256 private key is 32 bytes
        let d = privateKeyData

        // Get public key coordinates from x963 representation
        // x963 format: 04 || x (32 bytes) || y (32 bytes)
        let publicKeyData = publicKey.x963Representation
        let x = publicKeyData[1..<33]
        let y = publicKeyData[33..<65]

        return JWK(d: d, x: Data(x), y: Data(y))
    }

    /// Get the P256 private key
    public func getPrivateKey() throws -> P256.Signing.PrivateKey {
        return try P256.Signing.PrivateKey(rawRepresentation: d.data)
    }

    /// Get the P256 public key
    public func getPublicKey() throws -> P256.Signing.PublicKey {
        // Construct x963 representation: 04 || x || y
        var x963 = Data([0x04])
        x963.append(x.data)
        x963.append(y.data)
        return try P256.Signing.PublicKey(x963Representation: x963)
    }

    /// Marshal the public key as a DER-encoded SubjectPublicKeyInfo (PKIX).
    ///
    /// This matches Go's `x509.MarshalPKIXPublicKey` output, which Google Messages expects
    /// in some requests (e.g. RegisterPhoneRelay/SignInGaia).
    public func pkixPublicKeyDER() throws -> Data {
        let pub = try getPublicKey()
        return try DER.subjectPublicKeyInfoP256(uncompressedPoint: pub.x963Representation)
    }

    /// Get the P256 key agreement private key (for ECDH)
    public func getKeyAgreementPrivateKey() throws -> P256.KeyAgreement.PrivateKey {
        return try P256.KeyAgreement.PrivateKey(rawRepresentation: d.data)
    }

    /// Get the P256 key agreement public key (for ECDH)
    public func getKeyAgreementPublicKey() throws -> P256.KeyAgreement.PublicKey {
        var x963 = Data([0x04])
        x963.append(x.data)
        x963.append(y.data)
        return try P256.KeyAgreement.PublicKey(x963Representation: x963)
    }

    /// Sign data with this key using ECDSA P-256
    /// - Parameter data: Data to sign (will be hashed with SHA-256)
    /// - Returns: DER-encoded signature
    public func sign(_ data: Data) throws -> Data {
        let privateKey = try getPrivateKey()
        let signature = try privateKey.signature(for: data)
        return signature.derRepresentation
    }

    /// Sign a message for token refresh
    /// - Parameters:
    ///   - requestID: Request ID (UUID string)
    ///   - timestamp: Unix timestamp in microseconds
    /// - Returns: DER-encoded signature
    public func signRefreshRequest(requestID: String, timestamp: Int64) throws -> Data {
        let message = "\(requestID):\(timestamp)"
        let messageData = Data(message.utf8)
        return try sign(messageData)
    }
}

// MARK: - Minimal DER (PKIX SPKI) Encoding

private enum DER {
    // OIDs:
    // - id-ecPublicKey: 1.2.840.10045.2.1
    // - prime256v1:     1.2.840.10045.3.1.7
    private static let oidEcPublicKey: [UInt64] = [1, 2, 840, 10045, 2, 1]
    private static let oidPrime256v1: [UInt64] = [1, 2, 840, 10045, 3, 1, 7]

    static func subjectPublicKeyInfoP256(uncompressedPoint: Data) throws -> Data {
        // Expected X9.63 uncompressed point: 0x04 || X(32) || Y(32)
        guard uncompressedPoint.count == 65, uncompressedPoint.first == 0x04 else {
            throw CryptoError.invalidHeader
        }

        let algorithm = sequence([
            oid(oidEcPublicKey),
            oid(oidPrime256v1),
        ])
        let subjectPublicKey = bitString(uncompressedPoint)
        return sequence([algorithm, subjectPublicKey])
    }

    private static func sequence(_ elements: [Data]) -> Data {
        let content = elements.reduce(into: Data()) { $0.append($1) }
        return tagged(0x30, content)
    }

    private static func oid(_ arcs: [UInt64]) -> Data {
        precondition(arcs.count >= 2, "OID must have at least two arcs")
        var bytes = Data()
        bytes.append(UInt8(arcs[0] * 40 + arcs[1]))
        for arc in arcs.dropFirst(2) {
            bytes.append(contentsOf: base128(arc))
        }
        return tagged(0x06, bytes)
    }

    private static func bitString(_ bytes: Data) -> Data {
        // 0 unused bits prefix.
        var content = Data([0x00])
        content.append(bytes)
        return tagged(0x03, content)
    }

    private static func tagged(_ tag: UInt8, _ content: Data) -> Data {
        var out = Data([tag])
        out.append(encodeLength(content.count))
        out.append(content)
        return out
    }

    private static func encodeLength(_ length: Int) -> Data {
        precondition(length >= 0)
        if length < 128 {
            return Data([UInt8(length)])
        }
        // Long form: 0x80 | numBytes, followed by big-endian length bytes.
        var tmp = length
        var lenBytes: [UInt8] = []
        while tmp > 0 {
            lenBytes.append(UInt8(tmp & 0xff))
            tmp >>= 8
        }
        lenBytes.reverse()
        var out = Data()
        out.append(0x80 | UInt8(lenBytes.count))
        out.append(contentsOf: lenBytes)
        return out
    }

    private static func base128(_ value: UInt64) -> [UInt8] {
        // Base-128 with continuation bits, big-endian.
        var v = value
        var stack: [UInt8] = [UInt8(v & 0x7f)]
        v >>= 7
        while v > 0 {
            stack.append(UInt8(v & 0x7f))
            v >>= 7
        }
        // Reverse and set continuation bits.
        var out = stack.reversed()
        var result: [UInt8] = []
        for (idx, b) in out.enumerated() {
            if idx == out.count - 1 {
                result.append(b)
            } else {
                result.append(b | 0x80)
            }
        }
        return result
    }
}

/// Wrapper for base64url-encoded bytes in JSON
public struct RawURLBytes: Codable, Sendable {
    public let data: Data

    public init(_ data: Data) {
        self.data = data
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let base64String = try container.decode(String.self)
        guard let decoded = Data(base64URLEncoded: base64String) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid base64url string"
                )
            )
        }
        self.data = decoded
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(data.base64URLEncodedString())
    }
}

// MARK: - Base64URL Extensions

extension Data {
    /// Initialize from base64url encoded string
    init?(base64URLEncoded string: String) {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        // Add padding if needed
        let paddingLength = (4 - base64.count % 4) % 4
        base64 += String(repeating: "=", count: paddingLength)

        guard let data = Data(base64Encoded: base64) else {
            return nil
        }
        self = data
    }

    /// Encode to base64url string (no padding)
    func base64URLEncodedString() -> String {
        return base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
