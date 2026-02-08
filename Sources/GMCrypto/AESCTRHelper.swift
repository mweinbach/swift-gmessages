import Foundation
import Crypto
import CommonCrypto

/// AES-256-CTR encryption with HMAC-SHA256 authentication
///
/// Encryption format: [ciphertext || IV(16 bytes) || HMAC-SHA256(32 bytes)]
/// The HMAC is calculated over (ciphertext || IV)
public struct AESCTRHelper: Codable, Sendable {
    /// 256-bit AES key
    public let aesKey: Data
    /// 256-bit HMAC key
    public let hmacKey: Data

    private enum CodingKeys: String, CodingKey {
        case aesKey = "aes_key"
        case hmacKey = "hmac_key"
    }

    /// Create a new AESCTRHelper with random keys
    public init() {
        self.aesKey = generateKey(length: 32)
        self.hmacKey = generateKey(length: 32)
    }

    /// Create an AESCTRHelper with existing keys
    /// - Parameters:
    ///   - aesKey: 256-bit AES key
    ///   - hmacKey: 256-bit HMAC key
    public init(aesKey: Data, hmacKey: Data) {
        precondition(aesKey.count == 32, "AES key must be 32 bytes")
        precondition(hmacKey.count == 32, "HMAC key must be 32 bytes")
        self.aesKey = aesKey
        self.hmacKey = hmacKey
    }

    /// Encrypt plaintext using AES-256-CTR with HMAC-SHA256
    /// - Parameter plaintext: Data to encrypt
    /// - Returns: Encrypted data in format [ciphertext || IV || HMAC]
    public func encrypt(_ plaintext: Data) throws -> Data {
        // Generate random IV (16 bytes = AES block size)
        var iv = [UInt8](repeating: 0, count: kCCBlockSizeAES128)
        let ivResult = SecRandomCopyBytes(kSecRandomDefault, iv.count, &iv)
        guard ivResult == errSecSuccess else {
            throw CryptoError.randomGenerationFailed
        }

        // Encrypt using AES-CTR (manual implementation for reliability)
        let ciphertext = try aesCTREncrypt(plaintext: Array(plaintext), key: Array(aesKey), iv: iv)

        // Append IV to ciphertext
        var result = Data(ciphertext)
        result.append(contentsOf: iv)

        // Calculate HMAC over (ciphertext || IV)
        let hmac = HMAC<SHA256>.authenticationCode(for: result, using: SymmetricKey(data: hmacKey))
        result.append(contentsOf: hmac)

        return result
    }

    /// Decrypt data encrypted with AES-256-CTR + HMAC-SHA256
    /// - Parameter encryptedData: Encrypted data in format [ciphertext || IV || HMAC]
    /// - Returns: Decrypted plaintext
    public func decrypt(_ encryptedData: Data) throws -> Data {
        // Minimum size: 48 bytes (16 IV + 32 HMAC)
        guard encryptedData.count >= 48 else {
            throw CryptoError.inputTooShort
        }

        // Extract HMAC (last 32 bytes)
        let hmacSignature = encryptedData.suffix(32)
        let encryptedDataWithoutHMAC = encryptedData.prefix(encryptedData.count - 32)

        // Verify HMAC
        let expectedHMAC = HMAC<SHA256>.authenticationCode(
            for: encryptedDataWithoutHMAC,
            using: SymmetricKey(data: hmacKey)
        )

        guard hmacSignature.elementsEqual(expectedHMAC) else {
            throw CryptoError.hmacMismatch
        }

        // Extract IV (last 16 bytes before HMAC)
        let iv = Array(encryptedDataWithoutHMAC.suffix(16))
        let ciphertext = Array(encryptedDataWithoutHMAC.prefix(encryptedDataWithoutHMAC.count - 16))

        // Decrypt using AES-CTR
        let plaintext = try aesCTREncrypt(plaintext: ciphertext, key: Array(aesKey), iv: iv)

        return Data(plaintext)
    }

    /// Manual AES-CTR implementation using ECB mode
    /// CTR mode encrypts a counter and XORs with plaintext
    private func aesCTREncrypt(plaintext: [UInt8], key: [UInt8], iv: [UInt8]) throws -> [UInt8] {
        var result = [UInt8](repeating: 0, count: plaintext.count)
        var counter = iv
        var keystream = [UInt8](repeating: 0, count: kCCBlockSizeAES128)

        for blockStart in stride(from: 0, to: plaintext.count, by: kCCBlockSizeAES128) {
            // Encrypt counter to get keystream block
            var numBytesEncrypted: size_t = 0
            let cryptStatus = CCCrypt(
                CCOperation(kCCEncrypt),
                CCAlgorithm(kCCAlgorithmAES),
                CCOptions(kCCOptionECBMode),
                key,
                kCCKeySizeAES256,
                nil,
                counter,
                kCCBlockSizeAES128,
                &keystream,
                kCCBlockSizeAES128,
                &numBytesEncrypted
            )

            guard cryptStatus == kCCSuccess else {
                throw CryptoError.encryptionFailed(status: cryptStatus)
            }

            // XOR plaintext with keystream
            let blockEnd = min(blockStart + kCCBlockSizeAES128, plaintext.count)
            for i in blockStart..<blockEnd {
                result[i] = plaintext[i] ^ keystream[i - blockStart]
            }

            // Increment counter (big-endian)
            incrementCounter(&counter)
        }

        return result
    }

    /// Increment a 16-byte counter in big-endian format
    private func incrementCounter(_ counter: inout [UInt8]) {
        for i in (0..<counter.count).reversed() {
            counter[i] &+= 1
            if counter[i] != 0 {
                break
            }
        }
    }
}

/// Crypto-related errors
public enum CryptoError: Error, LocalizedError {
    case inputTooShort
    case hmacMismatch
    case encryptionFailed(status: CCCryptorStatus)
    case decryptionFailed(status: CCCryptorStatus)
    case randomGenerationFailed
    case invalidKeyLength
    case invalidHeader
    case chunkDecryptionFailed(index: Int, underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .inputTooShort:
            return "Input data is too short"
        case .hmacMismatch:
            return "HMAC verification failed"
        case .encryptionFailed(let status):
            return "Encryption failed with status \(status)"
        case .decryptionFailed(let status):
            return "Decryption failed with status \(status)"
        case .randomGenerationFailed:
            return "Failed to generate random bytes"
        case .invalidKeyLength:
            return "Invalid key length"
        case .invalidHeader:
            return "Invalid encrypted data header"
        case .chunkDecryptionFailed(let index, let error):
            return "Failed to decrypt chunk #\(index + 1): \(error.localizedDescription)"
        }
    }
}
