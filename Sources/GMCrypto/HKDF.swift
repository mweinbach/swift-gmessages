import Foundation
import Crypto

/// HKDF (HMAC-based Key Derivation Function) utilities
/// Used for deriving encryption keys during Gaia pairing
public enum HKDFHelper {
    /// Derive a 32-byte key using HKDF-SHA256
    /// - Parameters:
    ///   - inputKeyMaterial: The input key material
    ///   - salt: Salt value (can be nil)
    ///   - info: Context/application-specific info
    /// - Returns: 32-byte derived key
    public static func deriveKey(
        inputKeyMaterial: Data,
        salt: Data?,
        info: Data
    ) -> Data {
        let inputKey = SymmetricKey(data: inputKeyMaterial)
        let derivedKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: inputKey,
            salt: salt ?? Data(),
            info: info,
            outputByteCount: 32
        )

        return derivedKey.withUnsafeBytes { Data($0) }
    }

    /// Derive a key using string salt and info
    /// - Parameters:
    ///   - inputKeyMaterial: The input key material
    ///   - salt: Salt string
    ///   - info: Info string
    /// - Returns: 32-byte derived key
    public static func deriveKey(
        inputKeyMaterial: Data,
        salt: String,
        info: String
    ) -> Data {
        return deriveKey(
            inputKeyMaterial: inputKeyMaterial,
            salt: Data(salt.utf8),
            info: Data(info.utf8)
        )
    }
}

/// Encryption key info used in Gaia pairing
/// This constant is from the Go implementation
public let encryptionKeyInfo = Data([
    130, 170, 85, 160, 211, 151, 248, 131, 70, 202, 28, 238, 141, 57, 9, 185,
    95, 19, 250, 125, 235, 29, 74, 179, 131, 118, 184, 37, 109, 168, 85, 16
])
