import CoreFoundation
import Foundation

enum SourceHTTP {
    static let session = makeSession(resourceTimeout: 22)
    static let slowImageSession = makeSession(resourceTimeout: 65)
    static let previewSession = makeSession(resourceTimeout: 12, cached: true)

    static func request(for url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        if let host = url.host(), ArchivePhotoSources.commonsHosts.contains(host) {
            request.setValue(
                "macui/0.3 (macOS desktop wallpaper app; https://commons.wikimedia.org/wiki/Commons:Quality_images)",
                forHTTPHeaderField: "User-Agent"
            )
        }
        return request
    }

    private static func makeSession(resourceTimeout: TimeInterval, cached: Bool = false) -> URLSession {
        let config = cached ? URLSessionConfiguration.default : .ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.httpMaximumConnectionsPerHost = 5
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = resourceTimeout
        config.httpAdditionalHeaders = ["User-Agent": "Mozilla/5.0 (Macintosh) WallpaperWall/1.0"]
        if cached {
            let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
                .appending(path: "WallpaperWall/Thumbnails", directoryHint: .isDirectory)
            config.urlCache = URLCache(memoryCapacity: 8 * 1024 * 1024, diskCapacity: 96 * 1024 * 1024, directory: directory)
            config.requestCachePolicy = .returnCacheDataElseLoad
        }
        return URLSession(configuration: config, delegate: RedirectPolicy(), delegateQueue: nil)
    }

    static func check(_ response: URLResponse, for url: URL) throws {
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode),
              response.url?.scheme == "https",
              response.url?.host() == url.host()
        else { throw WallpaperError.badResponse }
    }

    private final class RedirectPolicy: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            let sameHost = request.url?.host() == task.originalRequest?.url?.host()
            completionHandler(request.url?.scheme == "https" && sameHost ? request : nil)
        }
    }
}

struct CatalogPage: Sendable {
    let items: [Wallpaper]
    let next: URL?
}

struct OnlineCatalog: Sendable {
    func firstPage(source: WallpaperSource, query: String, portrait: Bool = false, peopleOnly: Bool = false) -> URL? {
        let search = WallpaperSearch(query)
        let term = search.text
        var components = URLComponents()
        components.scheme = "https"
        components.host = source.host
        switch source {
        case .wallhaven:
            guard let keyword = search.wallhavenQuery else { return nil }
            components.path = "/api/v1/search"
            components.queryItems = [
                URLQueryItem(name: "atleast", value: portrait ? "2160x3840" : "3840x2160"),
                URLQueryItem(name: "purity", value: "100"),
                URLQueryItem(name: "sorting", value: keyword.isEmpty ? "toplist" : "relevance")
            ]
            if keyword.isEmpty {
                components.queryItems?.append(URLQueryItem(name: "topRange", value: "1M"))
                components.queryItems?.append(URLQueryItem(name: "categories", value: "100"))
            } else {
                components.queryItems?.append(URLQueryItem(name: "q", value: keyword))
                if peopleOnly || search.isPortraitPhotography {
                    components.queryItems?.append(URLQueryItem(name: "categories", value: "001"))
                    if !portrait { components.queryItems?.append(URLQueryItem(name: "ratios", value: "landscape")) }
                } else if search.isAnime {
                    components.queryItems?.append(URLQueryItem(name: "categories", value: "010"))
                }
            }
            if portrait { components.queryItems?.append(URLQueryItem(name: "ratios", value: "portrait")) }
        case .bing:
            components.path = "/HPImageArchive.aspx"
            components.queryItems = [
                URLQueryItem(name: "format", value: "js"), URLQueryItem(name: "idx", value: "0"),
                URLQueryItem(name: "n", value: "8"), URLQueryItem(name: "mkt", value: "zh-CN")
            ]
        case .commons:
            components.path = "/w/api.php"
            components.queryItems = ArchivePhotoSources.commonsParameters(search, portrait: portrait)
        case .bizhicang:
            components.path = term.isEmpty ? (portrait ? "/mobile/" : "/computer/") : "/api/search"
            if !term.isEmpty { components.queryItems = [URLQueryItem(name: "q", value: term)] }
        case .wallpic, .tenwallpaper:
            if term.isEmpty {
                components.path = source == .wallpic ? "/pc-pic/pc-static" : "/cn/"
            } else {
                let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_~"))
                guard let encoded = term.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
                let prefix = source == .wallpic ? "/search/" : "/cn/search/"
                components.percentEncodedPath = prefix + encoded + "/"
            }
        case .hao, .netbian, .nasa, .local: return nil
        }
        return components.url
    }

    func page(source: WallpaperSource, at url: URL, query: String = "", portrait: Bool = false) async throws -> CatalogPage {
        switch source {
        case .wallhaven: return try HDPhotoSources.wallhavenPage(await read(url), at: url)
        case .bing: return try HDPhotoSources.bingPage(await read(url), query: query, at: url)
        case .commons: return try ArchivePhotoSources.commonsPage(await read(url), at: url)
        case .bizhicang:
            let response = try await read(url)
            if url.path == "/api/search" {
                return try DomesticPhotoSources.storehouseSearch(response, at: url, portrait: portrait)
            }
            return DomesticPhotoSources.storehouseCatalog(response, at: url, portrait: portrait)
        case .wallpic, .tenwallpaper:
            let search = WallpaperSearch(query)
            let fallbackURL = search.chineseFallback.flatMap { firstPage(source: source, query: $0) }
            let isFirstPage = url == firstPage(source: source, query: query)
            let html = try await read(url, acceptNotFound: isFirstPage)
            let exact = Self.parsePage(html, source: source, url: url, search: search)
            if exact.items.isEmpty, isFirstPage, let fallbackURL, fallbackURL != url {
                let html = try await read(fallbackURL, acceptNotFound: true)
                return Self.parsePage(html, source: source, url: fallbackURL, search: search)
            }
            return exact
        case .hao, .netbian, .nasa, .local: throw WallpaperError.badResponse
        }
    }

    func detailPreviewURL(for item: Wallpaper) async throws -> URL? {
        guard item.downloadsOnOriginalSite, let url = item.detail,
              Self.isHTTPS(url, host: item.source.host) else { return nil }
        return try DomesticPhotoSources.detailPreview(await read(url), at: url, source: item.source)
    }

    func originalURLs(for item: Wallpaper, requirements: WallpaperRequirements = WallpaperRequirements()) async throws -> [URL] {
        switch item.source {
        case .wallhaven, .bing, .commons:
            guard let original = item.original else { throw WallpaperError.missingUHD }
            return [original]
        case .bizhicang:
            guard let original = item.original, DomesticPhotoSources.isStorehouseOriginal(original) else {
                throw WallpaperError.missingUHD
            }
            return [original]
        case .wallpic, .tenwallpaper:
            guard let page = item.detail else { throw WallpaperError.missingUHD }
            let html = try await read(page)
            return Self.originalLinks(html, source: item.source, page: page, requirements: requirements)
        case .hao, .netbian:
            throw WallpaperError.downloadOnOriginalSite
        case .nasa, .local:
            throw WallpaperError.missingUHD
        }
    }

    private func read(_ url: URL, acceptNotFound: Bool = false) async throws -> String {
        let (data, response) = try await SourceHTTP.session.data(for: SourceHTTP.request(for: url))
        if acceptNotFound, (response as? HTTPURLResponse)?.statusCode == 404 { return "" }
        try SourceHTTP.check(response, for: url)
        let legacyEncoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        ))
        let html = String(data: data, encoding: .utf8)
            ?? (url.host() == WallpaperSource.netbian.host ? String(data: data, encoding: legacyEncoding) : nil)
        guard data.count < 4 * 1024 * 1024, let html
        else { throw WallpaperError.badResponse }
        return html
    }

    static func parsePage(_ html: String, source: WallpaperSource, url: URL, search: WallpaperSearch = WallpaperSearch("")) -> CatalogPage {
        var visited = Set<String>()
        let items = matches(#"(<a\b[^>]*>)\s*(<img\b[^>]*>)"#, in: html).compactMap { pair -> Wallpaper? in
            let anchor = attributes(pair[1])
            let image = attributes(pair[2])
            guard let detail = safe(anchor["href"], from: url, host: source.host),
                  matches(source == .wallpic ? #"^/\d+\.html$"# : #"^/cn/view/[^/]+\.html$"#,
                          in: detail.path).first != nil
            else { return nil }
            let rawTitle = image["alt"] ?? anchor["title"] ?? ""
            let title = rawTitle.replacingOccurrences(
                of: #"-4K\s*高清免费壁纸.*$|\s*浏览[：:].*$"#, with: "", options: .regularExpression
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !["手机壁纸", "手机静态壁纸", "动态壁纸", "表情包"].contains(where: title.contains),
                  search.matches(title),
                  let thumbnail = imageURL(image["data-src"], from: url, source: source)
                    ?? imageURL(image["src"], from: url, source: source),
                  visited.insert(detail.absoluteString).inserted else { return nil }
            return Wallpaper(id: detail.absoluteString, title: title.isEmpty ? "未命名壁纸" : title,
                             source: source, detail: detail, thumbnail: thumbnail, preview: thumbnail)
        }
        let current = normalizedPath(url.path)
        let page = matches(#"/page/(\d+)$"#, in: current).first.flatMap { Int($0[1]) } ?? 1
        let base = current.replacingOccurrences(of: #"/page/\d+$"#, with: "", options: .regularExpression)
        let next = matches(#"<a\b[^>]*>"#, in: html).lazy
            .compactMap { safe(attributes($0[0])["href"], from: url, host: source.host) }
            .first { normalizedPath($0.path) == "\(base)/page/\(page + 1)" }
        return CatalogPage(items: items, next: next)
    }

    static func originalLinks(
        _ html: String, source: WallpaperSource, page: URL, requirements: WallpaperRequirements = WallpaperRequirements()
    ) -> [URL] {
        if source == .wallpic {
            return matches(#"<img\b[^>]*\bdata-wallpaper-macbook-image\b[^>]*>"#, in: html)
                .compactMap { imageURL(attributes($0[0])["src"], from: page, source: source) }
        }
        let links = matches(#"<a\b[^>]*\bdownload(?:\s|=|>)[^>]*>"#, in: html).compactMap { match -> (URL, PixelSize)? in
            guard let url = imageURL(attributes(match[0])["href"], from: page, source: source),
                  let size = downloadSize(url), size.isSupported, size.isUHD else { return nil }
            return (url, size)
        }
        let ranked = links.sorted {
            let leftFits = requirements.issue(for: $0.1) == nil
            let rightFits = requirements.issue(for: $1.1) == nil
            if leftFits != rightFits { return leftFits }
            if let screen = requirements.preferredScreen {
                let leftScale = max(1, Placement.fill.scale(from: $0.1, to: screen))
                let rightScale = max(1, Placement.fill.scale(from: $1.1, to: screen))
                if leftScale != rightScale { return leftScale < rightScale }
                let leftCrop = $0.1.cropFraction(for: screen.aspect)
                let rightCrop = $1.1.cropFraction(for: screen.aspect)
                if leftCrop != rightCrop { return leftCrop < rightCrop }
            }
            let leftArea = $0.1.width * $0.1.height, rightArea = $1.1.width * $1.1.height
            return leftArea < rightArea
        }
        var seen = Set<URL>()
        return ranked.map(\.0).filter { seen.insert($0).inserted }
    }

    private static func downloadSize(_ url: URL) -> PixelSize? {
        guard let dimensions = matches(#"/wallpaper/(\d{3,5})x(\d{3,5})/"#, in: url.path).first,
              let width = Int(dimensions[1]), let height = Int(dimensions[2]) else { return nil }
        return PixelSize(width: width, height: height)
    }

    private static func imageURL(_ raw: String?, from base: URL, source: WallpaperSource) -> URL? {
        guard let url = safe(raw, from: base, host: source.host),
              ["jpg", "jpeg", "png", "webp", "heic", "tiff"].contains(url.pathExtension.lowercased())
        else { return nil }
        switch source {
        case .wallpic: return url.path.hasPrefix("/wp-content/uploads/") ? url : nil
        case .tenwallpaper: return url.path.hasPrefix("/wallpaper/") ? url : nil
        case .bizhicang, .hao, .netbian, .wallhaven, .bing, .commons, .nasa, .local: return nil
        }
    }

    static func safe(_ raw: String?, from base: URL, host: String) -> URL? {
        guard let raw, let url = URL(string: raw, relativeTo: base)?.absoluteURL, isHTTPS(url, host: host)
        else { return nil }
        return url
    }

    static func isHTTPS(_ url: URL, host: String) -> Bool {
        url.scheme == "https" && url.host() == host && url.user == nil && url.password == nil && url.port == nil
    }

    private static func normalizedPath(_ path: String) -> String {
        path.replacingOccurrences(of: #"/$"#, with: "", options: .regularExpression)
    }

    static func attributes(_ tag: String) -> [String: String] {
        var result: [String: String] = [:]
        for match in matches(#"\s([\w:-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')"#, in: tag) {
            let value = match[2].isEmpty ? match[3] : match[2]
            result[match[1].lowercased()] = value.replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&#039;", with: "'")
                .replacingOccurrences(of: "&amp;", with: "&")
        }
        return result
    }

    static func matches(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
            (0..<match.numberOfRanges).map { index in
                Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
            }
        }
    }
}
