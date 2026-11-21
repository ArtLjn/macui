import Foundation

enum HDPhotoSources {
    private struct WallhavenResponse: Decodable {
        struct Meta: Decodable {
            let current_page: Int
            let last_page: Int
        }
        struct Photo: Decodable {
            struct Thumbs: Decodable {
                let small: URL?
                let large: URL?
                let original: URL?
            }
            let id: String
            let url: URL
            let path: URL
            let dimension_x: Int
            let dimension_y: Int
            let purity: String
            let category: String
            let thumbs: Thumbs?
            let file_size: Int?
        }
        let data: [Photo]
        let meta: Meta
    }

    private struct BingResponse: Decodable {
        struct Photo: Decodable {
            let urlbase: String
            let title: String
            let copyright: String
            let copyrightlink: URL?
        }
        let images: [Photo]
    }

    static func wallhavenPage(_ json: String, at url: URL) throws -> CatalogPage {
        let response = try JSONDecoder().decode(WallhavenResponse.self, from: Data(json.utf8))
        let items = response.data.compactMap { photo -> Wallpaper? in
            let dimensions = PixelSize(width: photo.dimension_x, height: photo.dimension_y)
            guard photo.purity == "sfw", dimensions.isUHD, dimensions.isSupported,
                  (photo.file_size ?? 0) <= ImageVault.maximumBytes,
                  OnlineCatalog.isHTTPS(photo.url, host: "wallhaven.cc"),
                  OnlineCatalog.isHTTPS(photo.path, host: "w.wallhaven.cc"),
                  photo.path.path.hasPrefix("/full/") else { return nil }
            func thumbnail(_ url: URL?, path: String) -> URL? {
                url.flatMap {
                    OnlineCatalog.isHTTPS($0, host: "th.wallhaven.cc") && $0.path.hasPrefix(path) ? $0 : nil
                }
            }
            // orig 缩略图保留原图比例，避免大图预览二次裁切。
            let preview = thumbnail(photo.thumbs?.original, path: "/orig/")
            let tile = thumbnail(photo.thumbs?.small, path: "/small/")
                ?? thumbnail(photo.thumbs?.large, path: "/lg/") ?? preview
            let title = switch photo.category {
            case "anime": "动漫插画"
            case "people": "人物壁纸"
            default: "精选壁纸"
            }
            return Wallpaper(
                id: photo.url.absoluteString, title: "\(title) · \(photo.id)", source: .wallhaven,
                detail: photo.url, thumbnail: tile, preview: preview, original: photo.path, advertisedSize: dimensions
            )
        }
        let next: URL?
        if response.meta.current_page < response.meta.last_page,
           var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.queryItems = (components.queryItems ?? []).filter { $0.name != "page" }
                + [URLQueryItem(name: "page", value: "\(response.meta.current_page + 1)")]
            next = components.url
        } else {
            next = nil
        }
        return CatalogPage(items: items, next: next)
    }

    static func bingPage(_ json: String, query: String, at url: URL? = nil) throws -> CatalogPage {
        let response = try JSONDecoder().decode(BingResponse.self, from: Data(json.utf8))
        let search = WallpaperSearch(query)
        let items = response.images.compactMap { photo -> Wallpaper? in
            let title = photo.title.isEmpty ? photo.copyright : photo.title
            guard search.matches("\(title) \(photo.copyright)") else { return nil }
            guard let base = URLComponents(string: photo.urlbase), base.host == nil, base.path == "/th",
                  let id = base.queryItems?.first(where: { $0.name == "id" })?.value,
                  id.hasPrefix("OHR."),
                  id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) })
            else { return nil }
            func imageURL(_ suffix: String) -> URL? {
                var components = URLComponents()
                components.scheme = "https"
                components.host = WallpaperSource.bing.host
                components.path = "/th"
                components.queryItems = [URLQueryItem(name: "id", value: "\(id)_\(suffix).jpg")]
                return components.url
            }
            guard let original = imageURL("UHD") else { return nil }
            let detail = photo.copyrightlink.flatMap {
                OnlineCatalog.isHTTPS($0, host: WallpaperSource.bing.host) ? $0 : nil
            }
            return Wallpaper(
                id: "bing:\(id)", title: title, source: .bing, detail: detail,
                author: photo.copyright, thumbnail: imageURL("320x180"), preview: imageURL("1920x1080"),
                original: original
            )
        }
        var next: URL?
        if response.images.count >= 8, let url,
           var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           var parameters = components.queryItems,
           let index = parameters.firstIndex(where: { $0.name == "idx" && $0.value == "0" }) {
            parameters[index].value = "8"
            components.queryItems = parameters
            next = components.url
        }
        return CatalogPage(items: items, next: next)
    }
}
