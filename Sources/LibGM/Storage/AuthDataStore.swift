import Foundation
import GMCrypto
import GMProto

/// Handles persistence of authentication data
public struct AuthDataStore: Sendable {
    /// Directory URL for storage
    private let directoryURL: URL

    /// File name for auth data
    private static let authDataFileName = "auth_data.json"

    /// Create a new auth data store
    /// - Parameter directoryURL: Directory to store auth data in
    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    /// Directory used for persistence (useful for colocating caches).
    public var directory: URL {
        directoryURL
    }

    /// Create a store using the default application support directory
    public static func defaultStore() -> AuthDataStore {
        let urls = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let appSupport = urls.first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let gmessagesDir = appSupport.appendingPathComponent("GMMessages", isDirectory: true)
        return AuthDataStore(directoryURL: gmessagesDir)
    }

    /// Create a store using a custom path
    public static func store(at path: String) -> AuthDataStore {
        return AuthDataStore(directoryURL: URL(fileURLWithPath: path))
    }

    /// Save auth data to disk
    /// - Parameter authData: Auth data to save
    public func save(_ authData: AuthData) async throws {
        let serialized = await authData.serialized()

        // Ensure directory exists
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let fileURL = directoryURL.appendingPathComponent(Self.authDataFileName)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let data = try encoder.encode(serialized)
        try data.write(to: fileURL, options: .atomic)
    }

    /// Load auth data from disk
    /// - Returns: Loaded auth data, or nil if not found
    public func load() throws -> AuthData? {
        let fileURL = directoryURL.appendingPathComponent(Self.authDataFileName)

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let serialized = try decoder.decode(AuthData.Serialized.self, from: data)
        return AuthData(from: serialized)
    }

    /// Delete saved auth data
    public func delete() throws {
        let fileURL = directoryURL.appendingPathComponent(Self.authDataFileName)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    /// Check if auth data exists
    public var exists: Bool {
        let fileURL = directoryURL.appendingPathComponent(Self.authDataFileName)
        return FileManager.default.fileExists(atPath: fileURL.path)
    }

    /// Get the file path for auth data
    public var filePath: String {
        directoryURL.appendingPathComponent(Self.authDataFileName).path
    }
}
