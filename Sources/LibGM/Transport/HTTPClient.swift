import Foundation
import GMProto
@preconcurrency import SwiftProtobuf

import CommonCrypto

/// HTTP client for Google Messages RPC endpoints.
public actor GMHTTPClient {
    public enum Encoding: Sendable {
        case protobuf
        case pblite

        var contentType: String {
            switch self {
            case .protobuf: return GMConstants.contentTypeProtobuf
            case .pblite: return GMConstants.contentTypePBLite
            }
        }
    }

    private var session: URLSession
    private let authData: AuthData
    private var proxyURL: URL?

    public init(authData: AuthData, proxyURL: URL? = nil) {
        self.authData = authData
        self.proxyURL = proxyURL
        self.session = Self.makeSession(proxyURL: proxyURL)
    }

    public func setProxy(_ url: URL?) {
        self.proxyURL = url
        self.session = Self.makeSession(proxyURL: url)
    }

    // MARK: - High-level helpers

    private static func makeSession(proxyURL: URL?) -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 300

        if let proxy = proxyURL {
            let host = proxy.host ?? ""
            let port = proxy.port ?? 8080

            #if os(macOS)
            config.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPEnable: true,
                kCFNetworkProxiesHTTPProxy: host,
                kCFNetworkProxiesHTTPPort: port,
                kCFNetworkProxiesHTTPSEnable: true,
                kCFNetworkProxiesHTTPSProxy: host,
                kCFNetworkProxiesHTTPSPort: port,
            ]
            #else
            // CFNetwork proxy constants are unavailable on some Apple SDKs (for example watchOS),
            // but URLSession still accepts these string-based dictionary keys.
            config.connectionProxyDictionary = [
                "HTTPEnable": 1,
                "HTTPProxy": host,
                "HTTPPort": port,
                "HTTPSEnable": 1,
                "HTTPSProxy": host,
                "HTTPSPort": port,
            ]
            #endif
        }

        return URLSession(configuration: config)
    }

    public func post<Request: SwiftProtobuf.Message, Response: SwiftProtobuf.Message>(
        url: String,
        encoding: Encoding,
        request: Request,
        response: Response.Type,
        accept: String = "*/*"
    ) async throws -> Response {
        let body = try encode(request, encoding: encoding)
        let (data, http) = try await send(
            url: url,
            method: "POST",
            contentType: encoding.contentType,
            accept: accept,
            body: body,
            timeout: 60
        )
        return try decodeResponse(data, contentType: http.value(forHTTPHeaderField: "Content-Type"), as: response)
    }

    public func postNoResponse<Request: SwiftProtobuf.Message>(
        url: String,
        encoding: Encoding,
        request: Request,
        accept: String = "*/*"
    ) async throws {
        let body = try encode(request, encoding: encoding)
        _ = try await send(
            url: url,
            method: "POST",
            contentType: encoding.contentType,
            accept: accept,
            body: body,
            timeout: 60
        )
    }

    public func openStream<Request: SwiftProtobuf.Message>(
        url: String,
        encoding: Encoding,
        request: Request,
        accept: String = "*/*",
        timeout: TimeInterval = 30 * 60
    ) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        let body = try encode(request, encoding: encoding)
        let url = URL(string: url)!

        var req = await makeRequest(
            url: url,
            method: "POST",
            contentType: encoding.contentType,
            accept: accept,
            body: body
        )
        req.timeoutInterval = timeout

        let (bytes, resp) = try await session.bytes(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw GMHTTPError.invalidResponse
        }
        try await updateCookies(from: http)

        guard (200...299).contains(http.statusCode) else {
            // Note: body is streamed; callers should treat non-2xx as fatal.
            throw GMHTTPError.httpError(statusCode: http.statusCode, body: nil)
        }

        return (bytes, http)
    }

    /// Fetch the Messages for Web config (`/web/config`).
    ///
    /// This isn't required for core operation, but is useful for parity with Go libgm
    /// and to discover the server's reported client version/device ID.
    public func fetchConfig() async throws -> Config_Config {
        let url = URL(string: GMConstants.configURL)!

        // Match Go libgm: use relay-like headers, but treat as same-origin and omit `x-user-agent` + `origin`.
        var req = await makeRequest(
            url: url,
            method: "GET",
            contentType: "",
            accept: "*/*",
            body: Data()
        )
        req.setValue("same-origin", forHTTPHeaderField: "sec-fetch-site")
        req.setValue(nil, forHTTPHeaderField: "x-user-agent")
        req.setValue(nil, forHTTPHeaderField: "origin")

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw GMHTTPError.invalidResponse
        }

        try await updateCookies(from: http)

        guard (200...299).contains(http.statusCode) else {
            throw GMHTTPError.httpError(statusCode: http.statusCode, body: data)
        }

        return try decodeResponse(
            data,
            contentType: http.value(forHTTPHeaderField: "Content-Type"),
            as: Config_Config.self
        )
    }

    // MARK: - Core request sending

    private func send(
        url: String,
        method: String,
        contentType: String,
        accept: String,
        body: Data,
        timeout: TimeInterval
    ) async throws -> (Data, HTTPURLResponse) {
        var req = await makeRequest(
            url: URL(string: url)!,
            method: method,
            contentType: contentType,
            accept: accept,
            body: body
        )
        req.timeoutInterval = timeout

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw GMHTTPError.invalidResponse
        }

        try await updateCookies(from: http)

        guard (200...299).contains(http.statusCode) else {
            throw GMHTTPError.httpError(statusCode: http.statusCode, body: data)
        }

        return (data, http)
    }

    private func makeRequest(
        url: URL,
        method: String,
        contentType: String,
        accept: String,
        body: Data
    ) async -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.httpBody = body

        // Headers mimic Messages for Web.
        req.setValue(GMConstants.secCHUA, forHTTPHeaderField: "sec-ch-ua")
        req.setValue(GMConstants.xUserAgent, forHTTPHeaderField: "x-user-agent")
        req.setValue(GMConstants.googleAPIKey, forHTTPHeaderField: "x-goog-api-key")
        if !contentType.isEmpty {
            req.setValue(contentType, forHTTPHeaderField: "content-type")
        }
        req.setValue(GMConstants.secCHUAMobile, forHTTPHeaderField: "sec-ch-ua-mobile")
        req.setValue(GMConstants.userAgent, forHTTPHeaderField: "user-agent")
        req.setValue("\"\(GMConstants.secCHUAPlatform)\"", forHTTPHeaderField: "sec-ch-ua-platform")
        req.setValue(accept, forHTTPHeaderField: "accept")
        req.setValue(GMConstants.messagesBaseURL, forHTTPHeaderField: "origin")
        req.setValue("cross-site", forHTTPHeaderField: "sec-fetch-site")
        req.setValue("cors", forHTTPHeaderField: "sec-fetch-mode")
        req.setValue("empty", forHTTPHeaderField: "sec-fetch-dest")
        req.setValue("\(GMConstants.messagesBaseURL)/", forHTTPHeaderField: "referer")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "accept-language")

        // Cookies + SAPISIDHASH (if available).
        await self.addCookiesAndAuth(to: &req)

        return req
    }

    private func encode(_ msg: any SwiftProtobuf.Message, encoding: Encoding) throws -> Data {
        switch encoding {
        case .protobuf:
            return try msg.serializedData()
        case .pblite:
            return try PBLite.marshal(msg)
        }
    }

    private func decodeResponse<Response: SwiftProtobuf.Message>(
        _ data: Data,
        contentType: String?,
        as type: Response.Type
    ) throws -> Response {
        // contentType may include charset, etc.
        let mimeType: String
        if let contentType {
            mimeType = contentType.split(separator: ";", maxSplits: 1).first.map(String.init) ?? contentType
        } else {
            mimeType = ""
        }

        switch mimeType {
        case GMConstants.contentTypeProtobuf:
            return try Response(serializedBytes: data)
        case GMConstants.contentTypePBLite, "text/plain":
            return try PBLite.unmarshal(data, as: Response.self)
        default:
            // Best-effort: try protobuf first, then pblite.
            if let decoded = try? Response(serializedBytes: data) {
                return decoded
            }
            return try PBLite.unmarshal(data, as: Response.self)
        }
    }

    // MARK: - Cookies / SAPISIDHASH

    private func addCookiesAndAuth(to request: inout URLRequest) async {
        let cookies = await authData.cookies
        if cookies.isEmpty { return }

        let cookieString = cookies.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
        request.setValue(cookieString, forHTTPHeaderField: "cookie")

        if let sapisid = cookies["SAPISID"] ?? cookies["__Secure-1PAPISID"] {
            let auth = sapisidHash(origin: GMConstants.messagesBaseURL, sapisid: sapisid)
            request.setValue(auth, forHTTPHeaderField: "authorization")
        }
    }

    private func sapisidHash(origin: String, sapisid: String) -> String {
        let ts = Int(Date().timeIntervalSince1970)
        let input = "\(ts) \(sapisid) \(origin)"
        let inputData = Data(input.utf8)
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        inputData.withUnsafeBytes {
            _ = CC_SHA1($0.baseAddress, CC_LONG(inputData.count), &hash)
        }
        let hashString = hash.map { String(format: "%02x", $0) }.joined()
        return "SAPISIDHASH \(ts)_\(hashString)"
    }

    private func updateCookies(from http: HTTPURLResponse) async throws {
        guard let headerFields = http.allHeaderFields as? [String: String],
              let url = http.url else { return }
        let responseCookies = HTTPCookie.cookies(withResponseHeaderFields: headerFields, for: url)
        for cookie in responseCookies {
            await authData.setCookie(cookie.name, value: cookie.value)
        }
    }
}

/// HTTP client errors
public enum GMHTTPError: Error, LocalizedError {
    case invalidResponse
    case httpError(statusCode: Int, body: Data?)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid HTTP response"
        case .httpError(let statusCode, _):
            return "HTTP error: \(statusCode)"
        }
    }
}
