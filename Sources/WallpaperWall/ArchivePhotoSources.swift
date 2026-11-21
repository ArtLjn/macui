import Foundation

enum ArchivePhotoSources {
    static let commonsHosts: Set<String> = ["commons.wikimedia.org", "thumb.wikimedia.org", "upload.wikimedia.org"]

    static func commonsParameters(_ search: WallpaperSearch, portrait: Bool) -> [URLQueryItem] {
        let keyword = search.wallhavenQuery ?? "intitle:\"\(search.text.replacingOccurrences(of: "\"", with: " "))\""
        let subject = "\(keyword) incategory:\"Quality images\"".trimmingCharacters(in: .whitespaces)
        let size = portrait ? "filew:>2159 fileh:>3839" : "filew:>3839 fileh:>2159"
        return [
            "action": "query", "format": "json", "formatversion": "2", "generator": "search",
            "gsrnamespace": "6", "gsrlimit": "16", "gsrsearch": "\(subject) \(size) filetype:bitmap",
            "prop": "imageinfo", "iiprop": "url|size|mime|extmetadata",
            "iiextmetadatafilter": "Artist|LicenseShortName", "iiurlwidth": "640"
        ].sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
    }

    private struct CommonsResponse: Decodable {
        struct Cursor: Decodable {
            let gsroffset: Int
            let `continue`: String
        }
        struct Query: Decodable {
            struct File: Decodable {
                struct ImageInfo: Decodable {
                    struct Metadata: Decodable {
                        struct Field: Decodable { let value: String }
                        let Artist: Field?
                        let LicenseShortName: Field?
                    }
                    let url: URL
                    let thumburl: URL?
                    let descriptionurl: URL
                    let width: Int
                    let height: Int
                    let size: Int
                    let mime: String
                    let extmetadata: Metadata?
                }
                let pageid: Int
                let index: Int?
                let title: String
                let imageinfo: [ImageInfo]?
            }
            let pages: [File]?
        }
        struct APIError: Decodable { let code: String }
        let query: Query?
        let `continue`: Cursor?
        let error: APIError?
    }

    static func commonsPage(_ json: String, at url: URL) throws -> CatalogPage {
        let response = try JSONDecoder().decode(CommonsResponse.self, from: Data(json.utf8))
        if response.error != nil { throw WallpaperError.badResponse }
        let items = (response.query?.pages ?? [])
            .sorted { ($0.index ?? $0.pageid) < ($1.index ?? $1.pageid) }
            .compactMap { file -> Wallpaper? in
                guard let image = file.imageinfo?.first, file.title.hasPrefix("File:"),
                      OnlineCatalog.isHTTPS(image.descriptionurl, host: WallpaperSource.commons.host),
                      image.descriptionurl.path.hasPrefix("/wiki/File:"),
                      OnlineCatalog.isHTTPS(image.url, host: "upload.wikimedia.org"),
                      image.url.path.hasPrefix("/wikipedia/commons/"),
                      let thumb = image.thumburl,
                      ["upload.wikimedia.org", "thumb.wikimedia.org"].contains(where: { OnlineCatalog.isHTTPS(thumb, host: $0) }),
                      thumb.path.hasPrefix("/wikipedia/commons/thumb/"),
                      ["image/jpeg", "image/png", "image/webp", "image/tiff", "image/heic"].contains(image.mime),
                      image.size > 0, image.size <= ImageVault.maximumBytes else { return nil }
                let size = PixelSize(width: image.width, height: image.height)
                guard size.isSupported, size.isUHD else { return nil }
                let title = (String(file.title.dropFirst(5)) as NSString).deletingPathExtension
                let license = cleanCredit(image.extmetadata?.LicenseShortName?.value)
                return Wallpaper(
                    id: "commons:\(file.pageid)", title: title, source: .commons, detail: image.descriptionurl,
                    author: cleanCredit(image.extmetadata?.Artist?.value),
                    thumbnail: removingTracking(from: thumb), preview: removingTracking(from: thumb),
                    original: removingTracking(from: image.url), advertisedSize: size, license: license
                )
            }
        let cursor = response.continue
        let next = cursor.flatMap { token in
            replacingParameters(in: url, names: ["gsroffset", "continue"], with: [
                URLQueryItem(name: "gsroffset", value: String(token.gsroffset)),
                URLQueryItem(name: "continue", value: token.continue)
            ])
        }
        return CatalogPage(items: items, next: next)
    }

    private static func replacingParameters(in url: URL, names: Set<String>, with new: [URLQueryItem]) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = (components.queryItems ?? []).filter { !names.contains($0.name) } + new
        return components.url
    }

    private static func removingTracking(from url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let parameters = components.queryItems else { return url }
        let kept = parameters.filter { !$0.name.hasPrefix("utm_") }
        components.queryItems = kept.isEmpty ? nil : kept
        return components.url ?? url
    }

    private static func cleanCredit(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let text = raw.replacingOccurrences(of: #"<[^>]*>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return text.isEmpty ? nil : String(text.prefix(180))
    }
}
