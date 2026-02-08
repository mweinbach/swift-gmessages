import Foundation
import Crypto

/// AES-256-GCM chunked encryption for media files
///
/// Format: [header(2 bytes) || chunk1 || chunk2 || ...]
/// Header: [0x00, log2(chunkSize)]
/// Each chunk: [nonce(12 bytes) || ciphertext || tag(16 bytes)]
/// AAD for each chunk: [isLastChunk(1 byte) || chunkIndex(4 bytes big-endian)]
public struct AESGCMHelper: Sendable {
    /// 256-bit AES key
    private let key: SymmetricKey

    /// Default raw chunk size (32KB)
    private static let outgoingRawChunkSize = 1 << 15  // 32768 bytes

    /// GCM nonce size
    private static let nonceSize = 12

    /// GCM tag size
    private static let tagSize = 16

    /// Create an AESGCMHelper with a 256-bit key
    /// - Parameter key: 32-byte AES key
    public init(key: Data) throws {
        guard key.count == 32 else {
            throw CryptoError.invalidKeyLength
        }
        self.key = SymmetricKey(data: key)
    }

    /// Create an AESGCMHelper with a SymmetricKey
    /// - Parameter key: 256-bit SymmetricKey
    public init(key: SymmetricKey) throws {
        guard key.bitCount == 256 else {
            throw CryptoError.invalidKeyLength
        }
        self.key = key
    }

    /// Encrypt data using chunked AES-GCM
    /// - Parameter data: Data to encrypt
    /// - Returns: Encrypted data with header and chunks
    public func encryptData(_ data: Data) throws -> Data {
        let chunkOverhead = Self.nonceSize + Self.tagSize  // 28 bytes
        let chunkSize = Self.outgoingRawChunkSize - chunkOverhead  // ~32740 bytes

        let chunkCount = Int(ceil(Double(data.count) / Double(chunkSize)))

        // Start with header
        var encrypted = Data(capacity: 2 + data.count + chunkOverhead * chunkCount)
        encrypted.append(0x00)  // Header byte 1
        encrypted.append(UInt8(log2(Double(Self.outgoingRawChunkSize))))  // Header byte 2

        var chunkIndex: UInt32 = 0
        var offset = 0

        while offset < data.count {
            let remaining = data.count - offset
            let currentChunkSize = min(chunkSize, remaining)
            let isLastChunk = offset + currentChunkSize >= data.count

            let chunk = data[offset..<(offset + currentChunkSize)]
            let aad = calculateAAD(index: chunkIndex, isLastChunk: isLastChunk)

            let encryptedChunk = try encryptChunk(chunk, aad: aad)
            encrypted.append(encryptedChunk)

            offset += currentChunkSize
            chunkIndex += 1
        }

        return encrypted
    }

    /// Decrypt chunked AES-GCM data
    /// - Parameter encryptedData: Encrypted data with header and chunks
    /// - Returns: Decrypted plaintext
    public func decryptData(_ encryptedData: Data) throws -> Data {
        guard encryptedData.count >= 2 else {
            return encryptedData  // Too short, return as-is
        }

        guard encryptedData[0] == 0x00 else {
            throw CryptoError.invalidHeader
        }

        let chunkSize = 1 << Int(encryptedData[1])
        var data = encryptedData.dropFirst(2)

        var chunkIndex: UInt32 = 0
        var decrypted = Data()
        decrypted.reserveCapacity(data.count)

        var offset = 0
        while offset < data.count {
            let remaining = data.count - offset
            let currentChunkSize = min(chunkSize, remaining)
            let isLastChunk = offset + currentChunkSize >= data.count

            let chunk = Data(data[data.startIndex.advanced(by: offset)..<data.startIndex.advanced(by: offset + currentChunkSize)])
            let aad = calculateAAD(index: chunkIndex, isLastChunk: isLastChunk)

            do {
                let decryptedChunk = try decryptChunk(chunk, aad: aad)
                decrypted.append(decryptedChunk)
            } catch {
                throw CryptoError.chunkDecryptionFailed(index: Int(chunkIndex), underlying: error)
            }

            offset += currentChunkSize
            chunkIndex += 1
        }

        return decrypted
    }

    /// Encrypt a single chunk with AES-GCM
    private func encryptChunk(_ data: Data, aad: Data) throws -> Data {
        let nonce = AES.GCM.Nonce()
        let sealedBox = try AES.GCM.seal(data, using: key, nonce: nonce, authenticating: aad)

        // Format: nonce || ciphertext || tag
        var result = Data()
        result.append(contentsOf: nonce)
        result.append(sealedBox.ciphertext)
        result.append(sealedBox.tag)

        return result
    }

    /// Decrypt a single chunk with AES-GCM
    private func decryptChunk(_ data: Data, aad: Data) throws -> Data {
        guard data.count >= Self.nonceSize + Self.tagSize else {
            throw CryptoError.inputTooShort
        }

        let nonceData = data.prefix(Self.nonceSize)
        let ciphertextAndTag = data.dropFirst(Self.nonceSize)
        let ciphertext = ciphertextAndTag.dropLast(Self.tagSize)
        let tag = ciphertextAndTag.suffix(Self.tagSize)

        let nonce = try AES.GCM.Nonce(data: nonceData)
        let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)

        return try AES.GCM.open(sealedBox, using: key, authenticating: aad)
    }

    /// Calculate AAD (Additional Authenticated Data) for a chunk
    /// Format: [isLastChunk(1 byte) || chunkIndex(4 bytes big-endian)]
    private func calculateAAD(index: UInt32, isLastChunk: Bool) -> Data {
        var aad = Data(count: 5)
        aad[0] = isLastChunk ? 1 : 0
        aad[1] = UInt8((index >> 24) & 0xFF)
        aad[2] = UInt8((index >> 16) & 0xFF)
        aad[3] = UInt8((index >> 8) & 0xFF)
        aad[4] = UInt8(index & 0xFF)
        return aad
    }

    // MARK: - Static Convenience Methods

    /// Encrypt data with a given key
    /// - Parameters:
    ///   - data: Data to encrypt
    ///   - key: 32-byte encryption key
    /// - Returns: Encrypted data
    public static func encrypt(_ data: Data, key: Data) throws -> Data {
        let helper = try AESGCMHelper(key: key)
        return try helper.encryptData(data)
    }

    /// Decrypt data with a given key
    /// - Parameters:
    ///   - encryptedData: Encrypted data
    ///   - key: 32-byte decryption key
    /// - Returns: Decrypted data
    public static func decrypt(_ encryptedData: Data, key: Data) throws -> Data {
        let helper = try AESGCMHelper(key: key)
        return try helper.decryptData(encryptedData)
    }
}
