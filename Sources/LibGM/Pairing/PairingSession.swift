import Foundation
import Crypto
import GMCrypto
import GMProto

/// UKEY2 Pairing session for Google account authentication
public struct PairingSession: Sendable {
    /// Session UUID
    public let uuid: UUID

    /// Session start time
    public let startTime: Date

    /// ECDSA private key for ECDH key exchange
    public let pairingKey: P256.KeyAgreement.PrivateKey

    /// Destination registration device info
    public let destRegID: String
    public let destRegUnknownInt: UInt64

    /// Server init response (set after ProcessServerInit)
    public var serverInit: Authentication_GaiaPairingResponseContainer?

    /// Client init payload (raw UKEY2 message)
    public var initPayload: Data?

    /// Client finish payload (raw UKEY2 message)
    public var finishPayload: Data?

    /// Next key for final encryption key derivation
    public var nextKey: Data?

    /// Create a new pairing session
    public init(destRegID: String, destRegUnknownInt: UInt64 = 0) {
        self.uuid = UUID()
        self.startTime = Date()
        self.pairingKey = P256.KeyAgreement.PrivateKey()
        self.destRegID = destRegID
        self.destRegUnknownInt = destRegUnknownInt
    }

    /// Prepare the UKEY2 init and finish payloads
    /// - Returns: Tuple of (clientInit, clientFinish) payloads
    public mutating func preparePayloads() throws -> (init: Data, finish: Data) {
        // Get public key coordinates
        let publicKeyData = pairingKey.publicKey.x963Representation
        // x963 format: 04 || x (32 bytes) || y (32 bytes)
        let xCoord = publicKeyData[1..<33]
        let yCoord = publicKeyData[33..<65]

        // Build public key proto with 33-byte format (leading zero byte)
        var pubKey = Ukey_GenericPublicKey()
        pubKey.type = .ecP256
        var ecKey = Ukey_EcP256PublicKey()
        ecKey.x = Data([0]) + xCoord
        ecKey.y = Data([0]) + yCoord
        pubKey.ecP256PublicKey = ecKey

        // Build client finished payload
        var clientFinished = Ukey_Ukey2ClientFinished()
        clientFinished.publicKey = pubKey
        let finishPayloadData = try clientFinished.serializedData()

        // Build finish message
        var finishMessage = Ukey_Ukey2Message()
        finishMessage.messageType = .clientFinish
        finishMessage.messageData = finishPayloadData
        let finish = try finishMessage.serializedData()
        self.finishPayload = finish

        // Compute commitment (SHA-512 of finish message)
        let keyCommitment = SHA512.hash(data: finish)

        // Generate random bytes
        var random = Data(count: 32)
        _ = random.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }

        // Build client init payload
        var clientInit = Ukey_Ukey2ClientInit()
        clientInit.version = 1
        clientInit.random = random
        clientInit.nextProtocol = "AES_256_CBC-HMAC_SHA256"

        var commitment = Ukey_Ukey2ClientInit.CipherCommitment()
        commitment.handshakeCipher = .p256Sha512
        commitment.commitment = Data(keyCommitment)
        clientInit.cipherCommitments = [commitment]

        let initPayloadData = try clientInit.serializedData()

        // Build init message
        var initMessage = Ukey_Ukey2Message()
        initMessage.messageType = .clientInit
        initMessage.messageData = initPayloadData
        let initData = try initMessage.serializedData()
        self.initPayload = initData

        return (initData, finish)
    }

    /// Process server init message and derive pairing emoji
    /// - Parameter response: The server's GaiaPairingResponseContainer
    /// - Returns: The pairing emoji to display to user
    public mutating func processServerInit(_ response: Authentication_GaiaPairingResponseContainer) throws -> String {
        self.serverInit = response

        // Parse UKEY2 message
        let ukeyMessage = try Ukey_Ukey2Message(serializedBytes: response.data)
        guard ukeyMessage.messageType == .serverInit else {
            throw PairingError.unexpectedMessageType(ukeyMessage.messageType.rawValue)
        }

        // Parse server init
        let serverInit = try Ukey_Ukey2ServerInit(serializedBytes: ukeyMessage.messageData)
        guard serverInit.version == 1 else {
            throw PairingError.unsupportedVersion(Int(serverInit.version))
        }
        guard serverInit.handshakeCipher == .p256Sha512 else {
            throw PairingError.unsupportedCipher(serverInit.handshakeCipher.rawValue)
        }
        guard serverInit.random.count == 32 else {
            throw PairingError.invalidRandomLength(serverInit.random.count)
        }

        // Extract server public key
        let serverKeyData = serverInit.publicKey.ecP256PublicKey
        var xData = serverKeyData.x
        var yData = serverKeyData.y

        // Remove leading zero byte if present (33 -> 32 bytes)
        if xData.count == 33 && xData[0] == 0 {
            xData = xData.dropFirst().withUnsafeBytes { Data($0) }
        }
        if yData.count == 33 && yData[0] == 0 {
            yData = yData.dropFirst().withUnsafeBytes { Data($0) }
        }

        // Construct server public key
        var x963 = Data([0x04])
        x963.append(xData)
        x963.append(yData)
        let serverPublicKey = try P256.KeyAgreement.PublicKey(x963Representation: x963)

        // Perform ECDH
        let sharedSecret = try pairingKey.sharedSecretFromKeyAgreement(with: serverPublicKey)
        let sharedSecretHash = SHA256.hash(data: sharedSecret.withUnsafeBytes { Data($0) })
        let sharedSecretData = Data(sharedSecretHash)

        // Build auth info
        guard let initPayload = initPayload else {
            throw PairingError.missingInitPayload
        }
        var authInfo = initPayload
        authInfo.append(response.data)

        // Derive UKEY2 v1 auth key
        let ukeyV1Auth = HKDFHelper.deriveKey(
            inputKeyMaterial: sharedSecretData,
            salt: "UKEY2 v1 auth",
            info: String(decoding: authInfo, as: UTF8.self)
        )

        // Derive next key for encryption
        nextKey = HKDFHelper.deriveKey(
            inputKeyMaterial: sharedSecretData,
            salt: "UKEY2 v1 next",
            info: String(decoding: authInfo, as: UTF8.self)
        )

        // Get auth number for emoji selection
        let authNumber = ukeyV1Auth.withUnsafeBytes { ptr -> UInt32 in
            ptr.load(as: UInt32.self).bigEndian
        }

        // Select emoji based on version
        let emojis: [String]
        switch response.confirmedVerificationCodeVersion {
        case 0:
            emojis = PairingEmojis.v0
        case 1:
            emojis = PairingEmojis.v1
        default:
            throw PairingError.unsupportedEmojiVersion(Int(response.confirmedVerificationCodeVersion))
        }

        let emojiIndex = Int(authNumber) % emojis.count
        return emojis[emojiIndex]
    }

    /// Derive final encryption keys after successful pairing
    /// - Parameter keyDerivationVersion: The confirmed key derivation version from server
    /// - Returns: Tuple of (aesKey, hmacKey)
    public func deriveEncryptionKeys(keyDerivationVersion: Int32) throws -> (aesKey: Data, hmacKey: Data) {
        guard let nextKey = nextKey else {
            throw PairingError.missingNextKey
        }

        let ukey2ClientKey = HKDFHelper.deriveKey(
            inputKeyMaterial: nextKey,
            salt: encryptionKeyInfo,
            info: Data("client".utf8)
        )
        let ukey2ServerKey = HKDFHelper.deriveKey(
            inputKeyMaterial: nextKey,
            salt: encryptionKeyInfo,
            info: Data("server".utf8)
        )

        switch keyDerivationVersion {
        case 0:
            return (aesKey: ukey2ClientKey, hmacKey: ukey2ServerKey)
        case 1:
            // V1: Hash the concatenation of encryptionKeyInfo and sorted keys
            var concatted = Data(count: 96)
            concatted[0..<32] = encryptionKeyInfo[0..<32]

            // Sort keys by hash value
            let clientHash = byteHash(ukey2ClientKey)
            let serverHash = byteHash(ukey2ServerKey)

            if clientHash < serverHash {
                concatted[32..<64] = ukey2ClientKey[0..<32]
                concatted[64..<96] = ukey2ServerKey[0..<32]
            } else {
                concatted[32..<64] = ukey2ServerKey[0..<32]
                concatted[64..<96] = ukey2ClientKey[0..<32]
            }

            let concattedHash = SHA256.hash(data: concatted)
            let hashData = Data(concattedHash)

            let aesKey = HKDFHelper.deriveKey(
                inputKeyMaterial: hashData,
                salt: "Ditto salt 1",
                info: "Ditto info 1"
            )
            let hmacKey = HKDFHelper.deriveKey(
                inputKeyMaterial: hashData,
                salt: "Ditto salt 2",
                info: "Ditto info 2"
            )
            return (aesKey: aesKey, hmacKey: hmacKey)
        default:
            throw PairingError.unsupportedKeyDerivationVersion(Int(keyDerivationVersion))
        }
    }

    /// Compute byte hash (Java-style hashCode)
    private func byteHash(_ data: Data) -> Int32 {
        var result: Int32 = 1
        for byte in data {
            result = 31 * result + Int32(Int8(bitPattern: byte))
        }
        return result
    }
}

// MARK: - Pairing Errors

public enum PairingError: Error, LocalizedError {
    case unexpectedMessageType(Int)
    case unsupportedVersion(Int)
    case unsupportedCipher(Int)
    case invalidRandomLength(Int)
    case missingInitPayload
    case missingNextKey
    case unsupportedEmojiVersion(Int)
    case unsupportedKeyDerivationVersion(Int)
    case noCookies
    case noDevicesFound
    case incorrectEmoji
    case pairingCancelled
    case pairingTimeout
    case pairingInitTimeout
    case multipleDevicesFound

    public var errorDescription: String? {
        switch self {
        case .unexpectedMessageType(let type):
            return "Unexpected UKEY2 message type: \(type)"
        case .unsupportedVersion(let version):
            return "Unsupported UKEY2 version: \(version)"
        case .unsupportedCipher(let cipher):
            return "Unsupported handshake cipher: \(cipher)"
        case .invalidRandomLength(let length):
            return "Invalid random length: \(length)"
        case .missingInitPayload:
            return "Missing init payload"
        case .missingNextKey:
            return "Missing next key"
        case .unsupportedEmojiVersion(let version):
            return "Unsupported emoji version: \(version)"
        case .unsupportedKeyDerivationVersion(let version):
            return "Unsupported key derivation version: \(version)"
        case .noCookies:
            return "Gaia pairing requires cookies"
        case .noDevicesFound:
            return "No devices found for Gaia pairing"
        case .incorrectEmoji:
            return "User chose incorrect emoji on phone"
        case .pairingCancelled:
            return "User cancelled pairing on phone"
        case .pairingTimeout:
            return "Pairing timed out"
        case .pairingInitTimeout:
            return "Client init timed out"
        case .multipleDevicesFound:
            return "Multiple primary devices found"
        }
    }
}

// MARK: - Pairing Emojis

public enum PairingEmojis {
    /// Version 0 emoji list
    public static let v0: [String] = [
        "😁", "😅", "🤣", "🫠", "🥰", "😇", "🤩", "😘", "😜", "🤗",
        "🤔", "🤐", "😴", "🥶", "🤯", "🤠", "🥳", "🥸", "😎", "🤓",
        "🧐", "🥹", "😭", "😱", "😖", "🥱", "😮‍💨", "🤡", "💩", "👻",
        "👽", "🤖", "😻", "💌", "💘", "💕", "❤", "💢", "💥", "💫",
        "💬", "🗯", "💤", "👋", "🙌", "🙏", "✍", "🦶", "👂", "🧠",
        "🦴", "👀", "🧑", "🧚", "🧍", "👣", "🐵", "🐶", "🐺", "🦊",
        "🦁", "🐯", "🦓", "🦄", "🐑", "🐮", "🐷", "🐿", "🐰", "🦇",
        "🐻", "🐨", "🐼", "🦥", "🐾", "🐔", "🐥", "🐦", "🕊", "🦆",
        "🦉", "🪶", "🦩", "🐸", "🐢", "🦎", "🐍", "🐳", "🐬", "🦭",
        "🐠", "🐡", "🦈", "🪸", "🐌", "🦋", "🐛", "🐝", "🐞", "🪱",
        "💐", "🌸", "🌹", "🌻", "🌱", "🌲", "🌴", "🌵", "🌾", "☘",
        "🍁", "🍂", "🍄", "🪺", "🍇", "🍈", "🍉", "🍋", "🍌", "🍍",
        "🍎", "🍐", "🍒", "🍓", "🥝", "🥥", "🥑", "🥕", "🌽", "🌶",
        "🫑", "🥦", "🥜", "🍞", "🥐", "🥨", "🧀", "🍗", "🍔", "🍟",
        "🍕", "🌭", "🌮", "🥗", "🥣", "🍿", "🦀", "🦑", "🍦", "🍩",
        "🍪", "🍫", "🍰", "🍬", "🍭", "☕", "🫖", "🍹", "🥤", "🧊",
        "🥢", "🍽", "🥄", "🧭", "🏔", "🌋", "🏕", "🏖", "🪵", "🏗",
        "🏡", "🏰", "🛝", "🚂", "🛵", "🛴", "🛼", "🚥", "⚓", "🛟",
        "⛵", "✈", "🚀", "🛸", "🧳", "⏰", "🌙", "🌡", "🌞", "🪐",
        "🌠", "🌧", "🌀", "🌈", "☂", "⚡", "❄", "⛄", "🔥", "🎇",
        "🧨", "✨", "🎈", "🎉", "🎁", "🏆", "🏅", "⚽", "⚾", "🏀",
        "🏐", "🏈", "🎾", "🎳", "🏓", "🥊", "⛳", "⛸", "🎯", "🪁",
        "🔮", "🎮", "🧩", "🧸", "🪩", "🖼", "🎨", "🧵", "🧶", "🦺",
        "🧣", "🧤", "🧦", "🎒", "🩴", "👟", "👑", "👒", "🎩", "🧢",
        "💎", "🔔", "🎤", "📻", "🎷", "🪗", "🎸", "🎺", "🎻", "🥁",
        "📺", "🔋", "💻", "💿", "☎", "🕯", "💡", "📖", "📚", "📬",
        "✏", "✒", "🖌", "🖍", "📝", "💼", "📋", "📌", "📎", "🔑",
        "🔧", "🧲", "🪜", "🧬", "🔭", "🩹", "🩺", "🪞", "🛋", "🪑",
        "🛁", "🧹", "🧺", "🔱", "🏁", "🐪", "🐘", "🦃", "🍞", "🍜",
        "🍠", "🚘", "🤿", "🃏", "👕", "📸", "🏷", "✂", "🧪", "🚪",
        "🧴", "🧻", "🪣", "🧽", "🚸"
    ]

    /// Version 1 emoji list (with additions and removals from v0)
    public static let v1: [String] = {
        let added = ["🍋‍🟩", "🐦‍🔥", "🐲", "🪅", "🦜", "🏺", "🗿", "🫐", "⛽", "🍱", "🥡", "🧋", "🍼", "📐"]
        let removed = Set(["💻", "🤗", "💬", "👋", "😁", "😎", "😇", "🥰", "🤓", "🤩"])

        // Deduplicate v0 and filter
        var result = Array(Set(v0))
        result = result.filter { !removed.contains($0) }
        result.append(contentsOf: added)
        return result
    }()
}
