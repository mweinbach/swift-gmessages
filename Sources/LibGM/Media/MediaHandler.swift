import Foundation
import GMCrypto
import GMProto
import os

/// Handles media upload and download operations
public actor MediaHandler {
    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "LibGM",
        category: "media"
    )

    /// Auth data for authenticated requests
    private let authData: AuthData

    /// HTTP session for media requests
    private let session: URLSession

    /// Upload/download media URL (same endpoint; metadata selects operation)
    private static let uploadURL = GMConstants.uploadMediaURL

    /// Create a new media handler
    public init(authData: AuthData) {
        self.authData = authData

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: config)
    }

    // MARK: - Upload

    /// Upload media file
    /// - Parameters:
    ///   - data: Raw media data
    ///   - fileName: File name
    ///   - mimeType: MIME type (e.g., "image/jpeg")
    /// - Returns: MediaContent with upload info and decryption key
    public func uploadMedia(
        data: Data,
        fileName: String,
        mimeType: String
    ) async throws -> Conversations_MediaContent {
        // Get media format type
        let mediaFormat = MediaTypes.formatFor(mimeType: mimeType)

        // Generate encryption key (32 bytes for AES-256)
        let decryptionKey = generateKey(length: 32)

        // Encrypt media with AES-GCM
        let encryptedData = try AESGCMHelper.encrypt(data, key: decryptionKey)

        // Start upload
        let startResponse = try await startUpload(
            encryptedData: encryptedData,
            mimeType: mimeType
        )

        // Finalize upload
        let uploadResult = try await finalizeUpload(
            startResponse: startResponse
        )

        // Build result
        var mediaContent = Conversations_MediaContent()
        mediaContent.format = mediaFormat
        mediaContent.mediaID = uploadResult.mediaID
        mediaContent.mediaName = fileName
        mediaContent.size = Int64(data.count)
        mediaContent.decryptionKey = decryptionKey
        mediaContent.mimeType = mimeType

        return mediaContent
    }

    /// Start media upload
    private func startUpload(
        encryptedData: Data,
        mimeType: String
    ) async throws -> StartUploadResponse {
        // Build upload request payload
        var request = Client_StartMediaUploadRequest()
        request.attachmentType = 1

        var authMessage = Authentication_AuthMessage()
        authMessage.requestID = UUID().uuidString
        if let token = await authData.tachyonAuthToken {
            authMessage.tachyonAuthToken = token
        }
        authMessage.network = await authData.authNetwork
        authMessage.configVersion = GMConstants.makeConfigVersion()
        request.authData = authMessage

        if let mobile = await authData.mobile {
            request.mobile = mobile
        }

        // Encode as base64
        let payloadData = try request.serializedData()
        let payloadBase64 = payloadData.base64EncodedString()

        // Build HTTP request
        let url = URL(string: Self.uploadURL)!
        var httpRequest = URLRequest(url: url)
        httpRequest.httpMethod = "POST"
        httpRequest.httpBody = payloadBase64.data(using: .utf8)

        // Add headers
        let encryptedSize = String(encryptedData.count)
        addMediaUploadHeaders(
            to: &httpRequest,
            size: encryptedSize,
            command: "start",
            offset: "",
            mimeType: mimeType,
            uploadType: "resumable"
        )

        // Send request
        let (_, response) = try await session.data(for: httpRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw MediaError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            throw MediaError.uploadFailed(statusCode: httpResponse.statusCode)
        }

        // Parse response headers
        guard let uploadURL = httpResponse.value(forHTTPHeaderField: "x-goog-upload-url") else {
            throw MediaError.missingUploadURL
        }

        let chunkGranularity = Int64(httpResponse.value(forHTTPHeaderField: "x-goog-upload-chunk-granularity") ?? "0") ?? 0

        return StartUploadResponse(
            uploadID: httpResponse.value(forHTTPHeaderField: "x-guploader-uploadid") ?? "",
            uploadURL: uploadURL,
            uploadStatus: httpResponse.value(forHTTPHeaderField: "x-goog-upload-status") ?? "",
            chunkGranularity: chunkGranularity,
            controlURL: httpResponse.value(forHTTPHeaderField: "x-goog-upload-control-url") ?? "",
            mimeType: mimeType,
            encryptedData: encryptedData
        )
    }

    /// Finalize media upload
    private func finalizeUpload(
        startResponse: StartUploadResponse
    ) async throws -> MediaUploadResult {
        // Build HTTP request
        guard let url = URL(string: startResponse.uploadURL) else {
            throw MediaError.invalidUploadURL
        }

        var httpRequest = URLRequest(url: url)
        httpRequest.httpMethod = "POST"
        httpRequest.httpBody = startResponse.encryptedData

        // Add headers
        let encryptedSize = String(startResponse.encryptedData.count)
        addMediaUploadHeaders(
            to: &httpRequest,
            size: encryptedSize,
            command: "upload, finalize",
            offset: "0",
            mimeType: startResponse.mimeType,
            uploadType: ""
        )

        // Send request
        let (responseData, response) = try await session.data(for: httpRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw MediaError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            throw MediaError.uploadFailed(statusCode: httpResponse.statusCode)
        }

        // Response may be base64 encoded
        let decodedData: Data
        if isStandardBase64(responseData) {
            guard let decoded = Data(base64Encoded: responseData) else {
                throw MediaError.invalidResponse
            }
            decodedData = decoded
        } else {
            decodedData = responseData
        }

        // Parse response
        let uploadResponse = try Client_UploadMediaResponse(serializedBytes: decodedData)

        return MediaUploadResult(
            mediaID: uploadResponse.media.mediaID,
            mediaNumber: uploadResponse.media.mediaNumber
        )
    }

    // MARK: - Download

    /// Download media file
    /// - Parameters:
    ///   - mediaID: Media ID to download
    ///   - decryptionKey: Key to decrypt the media
    /// - Returns: Decrypted media data
    public func downloadMedia(
        mediaID: String,
        decryptionKey: Data
    ) async throws -> Data {
        var keyToUse = decryptionKey
        if keyToUse.count != 32,
           let keyString = String(data: keyToUse, encoding: .utf8),
           let decoded = Data(base64Encoded: keyString),
           decoded.count == 32
        {
            keyToUse = decoded
            Self.log.warning("Download key looked base64; decoded mediaID=\(String(mediaID.suffix(6)), privacy: .public) keyLen=\(decryptionKey.count, privacy: .public)")
        }

        Self.log.info("Download start mediaID=\(String(mediaID.suffix(6)), privacy: .public) keyLen=\(keyToUse.count, privacy: .public)")
        // Build download request
        var request = Client_DownloadAttachmentRequest()

        var info = Client_AttachmentInfo()
        info.attachmentID = mediaID
        info.encrypted = true
        request.info = info

        var authMessage = Authentication_AuthMessage()
        authMessage.requestID = UUID().uuidString.lowercased()
        if let token = await authData.tachyonAuthToken {
            authMessage.tachyonAuthToken = token
        }
        authMessage.network = await authData.authNetwork
        authMessage.configVersion = GMConstants.makeConfigVersion()
        request.authData = authMessage

        // Encode as base64
        let payloadData = try request.serializedData()
        let payloadBase64 = payloadData.base64EncodedString()

        // Build HTTP request
        let url = URL(string: Self.uploadURL)!
        var httpRequest = URLRequest(url: url)
        httpRequest.httpMethod = "GET"

        addMediaDownloadHeaders(to: &httpRequest, metadata: payloadBase64)

        // Send request
        let (responseData, response) = try await session.data(for: httpRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw MediaError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let contentType = httpResponse.value(forHTTPHeaderField: "content-type") ?? ""
            let contentEncoding = httpResponse.value(forHTTPHeaderField: "content-encoding") ?? ""
            Self.log.error("Download failed mediaID=\(String(mediaID.suffix(6)), privacy: .public) status=\(httpResponse.statusCode, privacy: .public) bytes=\(responseData.count, privacy: .public) contentType=\(contentType, privacy: .public) encoding=\(contentEncoding, privacy: .public)")
            throw MediaError.downloadFailed(statusCode: httpResponse.statusCode)
        }

        let contentType = httpResponse.value(forHTTPHeaderField: "content-type") ?? ""
        let contentEncoding = httpResponse.value(forHTTPHeaderField: "content-encoding") ?? ""
        if responseData.count >= 2 {
            Self.log.info("Download HTTP 200 mediaID=\(String(mediaID.suffix(6)), privacy: .public) bytes=\(responseData.count, privacy: .public) encHeader=\(String(format: "%02x%02x", responseData[0], responseData[1]), privacy: .public) contentType=\(contentType, privacy: .public) encoding=\(contentEncoding, privacy: .public)")
        } else {
            Self.log.info("Download HTTP 200 mediaID=\(String(mediaID.suffix(6)), privacy: .public) bytes=\(responseData.count, privacy: .public) contentType=\(contentType, privacy: .public) encoding=\(contentEncoding, privacy: .public)")
        }

        // Decrypt media
        do {
            let decryptedData = try AESGCMHelper.decrypt(responseData, key: keyToUse)
            Self.log.info("Download decrypt ok mediaID=\(String(mediaID.suffix(6)), privacy: .public) decryptedBytes=\(decryptedData.count, privacy: .public)")
            return decryptedData
        } catch {
            if isStandardBase64(responseData), let decoded = Data(base64Encoded: responseData) {
                do {
                    Self.log.warning("Download response looked base64; retry decrypt mediaID=\(String(mediaID.suffix(6)), privacy: .public)")
                    let decryptedData = try AESGCMHelper.decrypt(decoded, key: keyToUse)
                    Self.log.info("Download decrypt ok (base64) mediaID=\(String(mediaID.suffix(6)), privacy: .public) decryptedBytes=\(decryptedData.count, privacy: .public)")
                    return decryptedData
                } catch {
                    // fall through to throw original error below
                }
            }

            Self.log.error("Download decrypt failed mediaID=\(String(mediaID.suffix(6)), privacy: .public) keyLen=\(keyToUse.count, privacy: .public) err=\(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    // MARK: - Helpers

    /// Add media upload headers to request
    private func addMediaUploadHeaders(
        to request: inout URLRequest,
        size: String,
        command: String,
        offset: String,
        mimeType: String,
        uploadType: String
    ) {
        // Match Go libgm `util.NewMediaUploadHeaders(...)`.
        request.setValue(GMConstants.secCHUA, forHTTPHeaderField: "sec-ch-ua")
        if !uploadType.isEmpty {
            request.setValue(uploadType, forHTTPHeaderField: "x-goog-upload-protocol")
        }
        request.setValue(size, forHTTPHeaderField: "x-goog-upload-header-content-length")
        request.setValue(GMConstants.secCHUAMobile, forHTTPHeaderField: "sec-ch-ua-mobile")
        request.setValue(GMConstants.userAgent, forHTTPHeaderField: "user-agent")
        if !mimeType.isEmpty {
            request.setValue(mimeType, forHTTPHeaderField: "x-goog-upload-header-content-type")
        }
        request.setValue("application/x-www-form-urlencoded;charset=UTF-8", forHTTPHeaderField: "content-type")
        if !command.isEmpty {
            request.setValue(command, forHTTPHeaderField: "x-goog-upload-command")
        }
        if !offset.isEmpty {
            request.setValue(offset, forHTTPHeaderField: "x-goog-upload-offset")
        }
        request.setValue("\"\(GMConstants.secCHUAPlatform)\"", forHTTPHeaderField: "sec-ch-ua-platform")
        request.setValue("*/*", forHTTPHeaderField: "accept")
        request.setValue(GMConstants.messagesBaseURL, forHTTPHeaderField: "origin")
        request.setValue("cross-site", forHTTPHeaderField: "sec-fetch-site")
        request.setValue("cors", forHTTPHeaderField: "sec-fetch-mode")
        request.setValue("empty", forHTTPHeaderField: "sec-fetch-dest")
        request.setValue("\(GMConstants.messagesBaseURL)/", forHTTPHeaderField: "referer")
        // Avoid Brotli ("br") to reduce compatibility issues when intermediates/frameworks
        // don't transparently decode it. (Encrypted media must be decrypted byte-for-byte.)
        request.setValue("gzip, deflate", forHTTPHeaderField: "accept-encoding")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "accept-language")
    }

    private func addMediaDownloadHeaders(
        to request: inout URLRequest,
        metadata: String
    ) {
        // Match Go libgm `util.BuildUploadHeaders(...)`.
        request.setValue(metadata, forHTTPHeaderField: "x-goog-download-metadata")
        request.setValue(GMConstants.secCHUA, forHTTPHeaderField: "sec-ch-ua")
        request.setValue(GMConstants.secCHUAMobile, forHTTPHeaderField: "sec-ch-ua-mobile")
        request.setValue(GMConstants.userAgent, forHTTPHeaderField: "user-agent")
        request.setValue("\"\(GMConstants.secCHUAPlatform)\"", forHTTPHeaderField: "sec-ch-ua-platform")
        request.setValue("*/*", forHTTPHeaderField: "accept")
        request.setValue(GMConstants.messagesBaseURL, forHTTPHeaderField: "origin")
        request.setValue("cross-site", forHTTPHeaderField: "sec-fetch-site")
        request.setValue("cors", forHTTPHeaderField: "sec-fetch-mode")
        request.setValue("empty", forHTTPHeaderField: "sec-fetch-dest")
        request.setValue("\(GMConstants.messagesBaseURL)/", forHTTPHeaderField: "referer")
        // Avoid Brotli ("br") to reduce compatibility issues when intermediates/frameworks
        // don't transparently decode it. (Encrypted media must be decrypted byte-for-byte.)
        request.setValue("gzip, deflate", forHTTPHeaderField: "accept-encoding")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "accept-language")
    }

    /// Check if data is standard base64 encoded
    private func isStandardBase64(_ data: Data) -> Bool {
        guard data.count % 4 == 0 else { return false }

        for byte in data {
            let isValid = (byte >= 65 && byte <= 90) ||   // A-Z
                         (byte >= 97 && byte <= 122) ||   // a-z
                         (byte >= 48 && byte <= 57) ||    // 0-9
                         byte == 43 ||                     // +
                         byte == 47 ||                     // /
                         byte == 61                        // =
            if !isValid {
                return false
            }
        }
        return true
    }
}

// MARK: - Supporting Types

/// Response from start upload request
private struct StartUploadResponse {
    let uploadID: String
    let uploadURL: String
    let uploadStatus: String
    let chunkGranularity: Int64
    let controlURL: String
    let mimeType: String
    let encryptedData: Data
}

/// Result of media upload
private struct MediaUploadResult {
    let mediaID: String
    let mediaNumber: Int64
}

/// Media handling errors
public enum MediaError: Error, LocalizedError {
    case invalidResponse
    case uploadFailed(statusCode: Int)
    case downloadFailed(statusCode: Int)
    case missingUploadURL
    case invalidUploadURL
    case encryptionFailed
    case decryptionFailed

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from server"
        case .uploadFailed(let statusCode):
            return "Upload failed with status code \(statusCode)"
        case .downloadFailed(let statusCode):
            return "Download failed with status code \(statusCode)"
        case .missingUploadURL:
            return "Missing upload URL in response"
        case .invalidUploadURL:
            return "Invalid upload URL"
        case .encryptionFailed:
            return "Failed to encrypt media"
        case .decryptionFailed:
            return "Failed to decrypt media"
        }
    }
}

// MARK: - Media Types

/// Media type definitions for MIME type mapping
public enum MediaTypes {
    /// Media type info
    public struct MediaType {
        public let fileExtension: String
        public let format: Conversations_MediaFormats

        public init(fileExtension: String, format: Conversations_MediaFormats) {
            self.fileExtension = fileExtension
            self.format = format
        }
    }

    /// MIME type to format mapping
    public static let mimeToFormat: [String: MediaType] = [
        // Images
        "image/jpeg": MediaType(fileExtension: "jpeg", format: .imageJpeg),
        "image/jpg": MediaType(fileExtension: "jpg", format: .imageJpg),
        "image/png": MediaType(fileExtension: "png", format: .imagePng),
        "image/gif": MediaType(fileExtension: "gif", format: .imageGif),
        "image/bmp": MediaType(fileExtension: "bmp", format: .imageXMsBmp),

        // Videos
        "video/mp4": MediaType(fileExtension: "mp4", format: .videoMp4),
        "video/3gpp": MediaType(fileExtension: "3gpp", format: .video3Gpp),
        "video/webm": MediaType(fileExtension: "webm", format: .videoWebm),

        // Audio
        "audio/aac": MediaType(fileExtension: "aac", format: .audioAac),
        "audio/amr": MediaType(fileExtension: "amr", format: .audioAmr),
        "audio/mp3": MediaType(fileExtension: "mp3", format: .audioMp3),
        "audio/mpeg": MediaType(fileExtension: "mpeg", format: .audioMpeg),
        "audio/ogg": MediaType(fileExtension: "ogg", format: .audioOgg),

        // Documents
        "application/pdf": MediaType(fileExtension: "pdf", format: .appPdf),
        "text/plain": MediaType(fileExtension: "txt", format: .appTxt),
        "text/vcard": MediaType(fileExtension: "vcf", format: .textVcard),
    ]

    /// Get format for MIME type
    public static func formatFor(mimeType: String) -> Conversations_MediaFormats {
        if let mediaType = mimeToFormat[mimeType] {
            return mediaType.format
        }

        // Try base type
        let baseType = mimeType.components(separatedBy: "/").first ?? ""
        switch baseType {
        case "image":
            return .imageUnspecified
        case "video":
            return .videoUnspecified
        case "audio":
            return .audioUnspecified
        default:
            return .appUnspecified
        }
    }

    /// Get file extension for format
    public static func extensionFor(format: Conversations_MediaFormats) -> String {
        for (_, mediaType) in mimeToFormat {
            if mediaType.format == format {
                return mediaType.fileExtension
            }
        }
        return "bin"
    }
}
