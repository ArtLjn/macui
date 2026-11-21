import Foundation
import Security

struct AIWallpaperTerms: Decodable, Sendable, Equatable {
    let english: String
    let chinese: String

    func query(for source: WallpaperSource) -> String {
        switch source {
        case .wallpic, .tenwallpaper, .bizhicang, .bing: chinese
        default: english
        }
    }
}

enum AIWallpaperSearchError: LocalizedError {
    case invalidSettings, missingKey, keychain, invalidResponse
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .invalidSettings: "请填写有效的模型 API 地址和模型名。HTTP 仅支持本机或已配置的网关。"
        case .missingKey: "请在「设置 → AI 搜索」保存模型配置和 API Key。"
        case .keychain: "无法访问 macOS 钥匙串，请解锁钥匙串后重试。"
        case .invalidResponse: "模型没有返回可用的中英文关键词。"
        case .http(401), .http(403): "模型网关拒绝了 API Key。"
        case .http(429): "模型请求过于频繁，请稍后重试。"
        case .http(let code): "模型网关返回 HTTP \(code)。"
        }
    }
}

struct AIWallpaperConfiguration: Sendable {
    static let httpGateway = "8.145.50.4"
    static let baseURLKey = "aiWallpaperBaseURL"
    static let modelKey = "aiWallpaperModel"
    private static let service = "local.wallpaperwall.mac.ai-search"
    private static let account = "model-api-key"

    let endpoint: URL
    let model: String
    let apiKey: String

    static func endpoint(for input: String) -> URL? {
        guard var url = URLComponents(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host?.lowercased(), !host.isEmpty,
              url.scheme == "https" || (url.scheme == "http" && [httpGateway, "localhost", "127.0.0.1", "::1"].contains(host)),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil
        else { return nil }
        while url.path.hasSuffix("/") { url.path.removeLast() }
        if !url.path.hasSuffix("/chat/completions") { url.path += "/chat/completions" }
        return url.url
    }

    static func load(defaults: UserDefaults = .standard) throws -> Self {
        guard let baseURL = defaults.string(forKey: baseURLKey), let model = defaults.string(forKey: modelKey) else {
            throw AIWallpaperSearchError.missingKey
        }
        guard let endpoint = endpoint(for: baseURL), !model.isEmpty else { throw AIWallpaperSearchError.invalidSettings }
        return try Self(endpoint: endpoint, model: model, apiKey: readKey())
    }

    static func save(baseURL: String, model: String, apiKey: String, defaults: UserDefaults = .standard) throws {
        let baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard endpoint(for: baseURL) != nil, !model.isEmpty else { throw AIWallpaperSearchError.invalidSettings }
        if apiKey.isEmpty {
            guard baseURL == defaults.string(forKey: baseURLKey) else { throw AIWallpaperSearchError.missingKey }
            _ = try readKey()
        } else {
            let data = Data(apiKey.utf8)
            var result = SecItemUpdate(keychainQuery as CFDictionary, [kSecValueData: data] as CFDictionary)
            if result == errSecItemNotFound {
                var attributes = keychainQuery
                attributes[kSecValueData as String] = data
                result = SecItemAdd(attributes as CFDictionary, nil)
            }
            guard result == errSecSuccess else { throw AIWallpaperSearchError.keychain }
        }
        defaults.set(baseURL, forKey: baseURLKey)
        defaults.set(model, forKey: modelKey)
    }

    private static var keychainQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    private static func readKey() throws -> String {
        var query = keychainQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let result = SecItemCopyMatching(query as CFDictionary, &value)
        if result == errSecItemNotFound { throw AIWallpaperSearchError.missingKey }
        guard result == errSecSuccess, let data = value as? Data, let key = String(data: data, encoding: .utf8),
              !key.isEmpty else { throw AIWallpaperSearchError.keychain }
        return key
    }
}

enum AIWallpaperSearch {
    private struct Request: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }
        let model: String
        let messages: [Message]
        let max_tokens = 400
        let temperature = 0.1
        let enable_thinking: Bool?
        let chat_template_kwargs: [String: Bool]?
    }

    private struct Response: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message
        }
        let choices: [Choice]
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 9
        configuration.timeoutIntervalForResource = 14
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration, delegate: RejectRedirects(), delegateQueue: nil)
    }()

    static func expand(_ input: String, configuration: AIWallpaperConfiguration) async throws -> AIWallpaperTerms {
        var request = URLRequest(url: configuration.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let qwen = configuration.model.localizedCaseInsensitiveContains("qwen")
        let messages: [Request.Message] = [
            .init(role: "system", content: """
            你为图片搜索引擎提取壁纸关键词。保留描述里的主体、地名、风格和有辨识度的色调。
            英文用 2 至 5 个适合图库检索的关键词，中文用简短关键词，以空格分隔。
            优先能直接搜到图片的视觉内容，省略“壁纸”“4K”等泛词。不回答问题，不提供链接。
            只返回 JSON 对象，包含字符串字段 english 和 chinese。
            """),
            .init(role: "user", content: String(input.prefix(300)))
        ]
        request.httpBody = try JSONEncoder().encode(Request(
            model: configuration.model, messages: messages, enable_thinking: qwen ? false : nil,
            chat_template_kwargs: qwen ? ["enable_thinking": false] : nil
        ))
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw AIWallpaperSearchError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else { throw AIWallpaperSearchError.http(response.statusCode) }
        return try terms(from: data)
    }

    static func terms(from data: Data) throws -> AIWallpaperTerms {
        guard data.count < 128 * 1024,
              let reply = try? JSONDecoder().decode(Response.self, from: data),
              let content = reply.choices.first?.message.content else { throw AIWallpaperSearchError.invalidResponse }
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let json: String
        if text.hasPrefix("```"), text.hasSuffix("```"), let newline = text.firstIndex(of: "\n") {
            json = String(text[text.index(after: newline)...].dropLast(3))
        } else {
            json = text
        }
        guard let terms = try? JSONDecoder().decode(AIWallpaperTerms.self, from: Data(json.utf8)),
              let english = keyword(terms.english, pattern: #"^[\p{Latin}\p{N}\p{M} '-]+$"#),
              let chinese = keyword(terms.chinese, pattern: #"^[\p{Han}\p{Latin}\p{N}\p{M} '-]+$"#)
        else { throw AIWallpaperSearchError.invalidResponse }
        return AIWallpaperTerms(english: english, chinese: chinese)
    }

    private static func keyword(_ input: String, pattern: String) -> String? {
        let words = input.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard (1...96).contains(words.count), words.range(of: pattern, options: .regularExpression) != nil,
              words.range(of: #"\p{L}|\p{N}"#, options: .regularExpression) != nil else { return nil }
        return words
    }

    private final class RejectRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }
}
