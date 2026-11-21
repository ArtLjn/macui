import Foundation

enum DomesticPhotoSources {
    private static let originalHosts = [
        "img.bizhicang.com", "t-1308607921.cos.ap-shanghai.myqcloud.com"
    ]

    private struct StorehouseSearch: Decodable {
        struct Entry: Decodable {
            let filename: String
            let title: String
            let width: Int
            let height: Int
            let thumbnail_url: String?
            let download_url: String?
        }
        let results: [Entry]
        let page: Int
        let pages: Int
    }

    static func storehouseSearch(_ json: String, at url: URL, portrait: Bool) throws -> CatalogPage {
        let response = try JSONDecoder().decode(StorehouseSearch.self, from: Data(json.utf8))
        let items = response.results.compactMap { entry in
            storehouseItem(at: url, title: entry.title, detail: "/p/\(entry.filename).html",
                           thumbnail: entry.thumbnail_url, original: entry.download_url,
                           size: PixelSize(width: entry.width, height: entry.height), portrait: portrait)
        }
        var next: URL?
        if response.page > 0, response.page < response.pages,
           var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.queryItems = (components.queryItems ?? []).filter { $0.name != "page" }
                + [URLQueryItem(name: "page", value: String(response.page + 1))]
            next = components.url
        }
        return CatalogPage(items: items, next: next)
    }

    static func storehouseCatalog(_ html: String, at url: URL, portrait: Bool) -> CatalogPage {
        let cards = OnlineCatalog.matches(#"<div\b[^>]*\bdata-dl=[^>]*>"#, in: html)
        let items = cards.compactMap { card -> Wallpaper? in
            let attributes = OnlineCatalog.attributes(card[0])
            let dimensions = attributes["data-res"]?.split(separator: "×") ?? []
            guard dimensions.count == 2, let width = Int(dimensions[0]), let height = Int(dimensions[1]) else { return nil }
            return storehouseItem(at: url, title: attributes["data-title"], detail: attributes["data-url"],
                                  thumbnail: attributes["data-img"], original: attributes["data-dl"],
                                  size: PixelSize(width: width, height: height), portrait: portrait)
        }
        let prefix = portrait ? "/mobile/" : "/computer/"
        let current = Int(url.path.split(separator: "/").last ?? "") ?? 1
        let path = "\(prefix)\(current + 1)/"
        let next = OnlineCatalog.matches(#"<a\b[^>]*>"#, in: html).lazy
            .compactMap { OnlineCatalog.safe(OnlineCatalog.attributes($0[0])["href"], from: url, host: WallpaperSource.bizhicang.host) }
            .first { $0.path(percentEncoded: false) == path }
        return CatalogPage(items: items, next: next)
    }

    static func isStorehouseOriginal(_ url: URL) -> Bool {
        url.query == nil && url.fragment == nil &&
            originalHosts.contains { OnlineCatalog.isHTTPS(url, host: $0) } &&
            url.path.range(of: #"^/images/biz-\d+\.(?:jpe?g|png|webp)$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func storehouseItem(
        at url: URL, title: String?, detail: String?, thumbnail: String?, original: String?, size: PixelSize, portrait: Bool
    ) -> Wallpaper? {
        guard size.isSupported, size.isUHD, (size.height > size.width) == portrait,
              let title, !title.isEmpty,
              let detailURL = OnlineCatalog.safe(detail, from: url, host: WallpaperSource.bizhicang.host),
              detailURL.path.range(of: #"^/p/biz-\d+\.html$"#, options: .regularExpression) != nil,
              let raw = original, let originalURL = URL(string: raw), isStorehouseOriginal(originalURL),
              originalURL.deletingPathExtension().lastPathComponent == detailURL.deletingPathExtension().lastPathComponent,
              let preview = OnlineCatalog.safe(thumbnail, from: url, host: "img.bizhicang.com"),
              preview.path.hasPrefix("/thumbs/") else { return nil }
        return Wallpaper(id: detailURL.absoluteString, title: title, source: .bizhicang, detail: detailURL,
                         thumbnail: preview, preview: preview, original: originalURL, advertisedSize: size)
    }

    static func detailPreview(_ html: String, at url: URL, source: WallpaperSource) -> URL? {
        switch source {
        case .hao:
            let property = OnlineCatalog.matches(#"<meta\b[^>]*property="og:image"[^>]*>"#, in: html).first?.first
            return property.flatMap { haoImage(OnlineCatalog.attributes($0)["content"], base: url) }
        case .netbian:
            let image = OnlineCatalog.matches(#"<div\s+class="photo-pic"[^>]*>\s*(<img\b[^>]*>)"#, in: html).first?[1]
            return image.flatMap { netbianImage(OnlineCatalog.attributes($0)["src"], base: url) }
        default: return nil
        }
    }

    private static func haoImage(_ raw: String?, base: URL) -> URL? {
        guard let image = OnlineCatalog.safe(raw, from: base, host: "img.haowallpaper.com"),
              ["/cache_file/", "/pre_cache_file/"].contains(where: { image.path.hasPrefix($0) }),
              ["webp", "jpg", "jpeg", "png"].contains(image.pathExtension.lowercased()) else { return nil }
        return image
    }

    private static func netbianImage(_ raw: String?, base: URL) -> URL? {
        guard let image = OnlineCatalog.safe(raw, from: base, host: WallpaperSource.netbian.host),
              image.path.hasPrefix("/uploads/allimg/"),
              ["webp", "jpg", "jpeg", "png"].contains(image.pathExtension.lowercased()) else { return nil }
        return image
    }
}
