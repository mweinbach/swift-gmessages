import Foundation
import Crypto

/// Generate cryptographically secure random bytes
/// - Parameter length: Number of random bytes to generate
/// - Returns: Data containing random bytes
public func generateKey(length: Int) -> Data {
    var bytes = [UInt8](repeating: 0, count: length)
    let result = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
    guard result == errSecSuccess else {
        fatalError("Failed to generate random bytes")
    }
    return Data(bytes)
}

/// Generate a 256-bit (32 byte) AES key
public func generateAESKey() -> SymmetricKey {
    return SymmetricKey(size: .bits256)
}
