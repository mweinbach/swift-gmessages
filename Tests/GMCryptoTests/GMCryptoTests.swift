import XCTest
@testable import GMCrypto

final class GMCryptoTests: XCTestCase {
    func testAESCTREncryptDecrypt() throws {
        let helper = AESCTRHelper()
        let plaintext = Data("Hello, World!".utf8)

        let encrypted = try helper.encrypt(plaintext)
        let decrypted = try helper.decrypt(encrypted)

        XCTAssertEqual(decrypted, plaintext)
    }

    func testAESCTRWithEmptyData() throws {
        let helper = AESCTRHelper()
        let plaintext = Data()

        let encrypted = try helper.encrypt(plaintext)
        let decrypted = try helper.decrypt(encrypted)

        XCTAssertEqual(decrypted, plaintext)
    }

    func testAESCTRWithLargeData() throws {
        let helper = AESCTRHelper()
        let plaintext = generateKey(length: 10000)

        let encrypted = try helper.encrypt(plaintext)
        let decrypted = try helper.decrypt(encrypted)

        XCTAssertEqual(decrypted, plaintext)
    }

    func testAESCTRHMACVerification() throws {
        let helper = AESCTRHelper()
        let plaintext = Data("Test data".utf8)

        var encrypted = try helper.encrypt(plaintext)

        // Tamper with the data
        encrypted[0] ^= 0xFF

        XCTAssertThrowsError(try helper.decrypt(encrypted)) { error in
            XCTAssertTrue(error is CryptoError)
        }
    }

    func testAESGCMEncryptDecrypt() throws {
        let key = generateKey(length: 32)
        let helper = try AESGCMHelper(key: key)
        let plaintext = Data("Hello, GCM World!".utf8)

        let encrypted = try helper.encryptData(plaintext)
        let decrypted = try helper.decryptData(encrypted)

        XCTAssertEqual(decrypted, plaintext)
    }

    func testAESGCMWithLargeData() throws {
        let key = generateKey(length: 32)
        let helper = try AESGCMHelper(key: key)
        // Create data larger than one chunk (32KB)
        let plaintext = generateKey(length: 100000)

        let encrypted = try helper.encryptData(plaintext)
        let decrypted = try helper.decryptData(encrypted)

        XCTAssertEqual(decrypted, plaintext)
    }

    func testJWKGeneration() throws {
        let jwk = JWK.generate()

        XCTAssertEqual(jwk.kty, "EC")
        XCTAssertEqual(jwk.crv, "P-256")
        XCTAssertEqual(jwk.d.data.count, 32)
        XCTAssertEqual(jwk.x.data.count, 32)
        XCTAssertEqual(jwk.y.data.count, 32)

        // Verify keys can be extracted
        let privateKey = try jwk.getPrivateKey()
        let publicKey = try jwk.getPublicKey()

        XCTAssertNotNil(privateKey)
        XCTAssertNotNil(publicKey)
    }

    func testJWKSerialization() throws {
        let jwk = JWK.generate()

        let encoder = JSONEncoder()
        let data = try encoder.encode(jwk)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(JWK.self, from: data)

        XCTAssertEqual(decoded.kty, jwk.kty)
        XCTAssertEqual(decoded.crv, jwk.crv)
        XCTAssertEqual(decoded.d.data, jwk.d.data)
        XCTAssertEqual(decoded.x.data, jwk.x.data)
        XCTAssertEqual(decoded.y.data, jwk.y.data)
    }

    func testHKDF() {
        let inputKey = generateKey(length: 32)
        let salt = "test salt"
        let info = "test info"

        let derived = HKDFHelper.deriveKey(
            inputKeyMaterial: inputKey,
            salt: salt,
            info: info
        )

        XCTAssertEqual(derived.count, 32)

        // Same inputs should produce same output
        let derived2 = HKDFHelper.deriveKey(
            inputKeyMaterial: inputKey,
            salt: salt,
            info: info
        )
        XCTAssertEqual(derived, derived2)

        // Different inputs should produce different output
        let derived3 = HKDFHelper.deriveKey(
            inputKeyMaterial: inputKey,
            salt: "different salt",
            info: info
        )
        XCTAssertNotEqual(derived, derived3)
    }

    func testBase64URL() {
        let original = Data([0, 1, 2, 3, 255, 254, 253])
        let encoded = original.base64URLEncodedString()

        XCTAssertFalse(encoded.contains("+"))
        XCTAssertFalse(encoded.contains("/"))
        XCTAssertFalse(encoded.contains("="))

        let decoded = Data(base64URLEncoded: encoded)
        XCTAssertEqual(decoded, original)
    }
}
