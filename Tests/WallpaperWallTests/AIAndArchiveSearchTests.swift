import Foundation
import Testing
@testable import WallpaperWall

struct AIAndArchiveSearchTests {
    @Test func aiKeywordsAreValidatedAndRouted() throws {
        let reply = #"{"choices":[{"message":{"content":"```json\n{\"english\":\" misty  forest \",\"chinese\":\"薄雾 森林\"}\n```"}}]}"#
        let terms = try AIWallpaperSearch.terms(from: Data(reply.utf8))
        #expect(terms.query(for: .wallhaven) == "misty forest")
        #expect(terms.query(for: .commons) == "misty forest")
        #expect(terms.query(for: .wallpic) == "薄雾 森林")

        let invalid = #"{"choices":[{"message":{"content":"{\"english\":\"https://example.com\",\"chinese\":\"森林\"}"}}]}"#
        #expect(throws: AIWallpaperSearchError.self) { try AIWallpaperSearch.terms(from: Data(invalid.utf8)) }
        #expect(throws: AIWallpaperSearchError.self) {
            try AIWallpaperSearch.terms(from: Data(#"{"choices":[{"message":{"content":null}}]}"#.utf8))
        }
    }

    @Test func modelEndpointIsNormalizedAndLimitsHTTP() {
        #expect(AIWallpaperConfiguration.endpoint(for: " https://example.com/v1/ ")?.path == "/v1/chat/completions")
        #expect(AIWallpaperConfiguration.endpoint(for: "https://example.com/v1/chat/completions")?.path == "/v1/chat/completions")
        #expect(AIWallpaperConfiguration.endpoint(for: "http://127.0.0.1:8000/v1")?.port == 8000)
        #expect(AIWallpaperConfiguration.endpoint(for: "http://example.com/v1") == nil)
        #expect(AIWallpaperConfiguration.endpoint(for: "https://user@example.com/v1") == nil)
        #expect(AIWallpaperConfiguration.endpoint(for: "https://example.com/v1?access_token=x") == nil)
    }

    @Test func wallhavenPortraitFilterAndDomesticDefaults() throws {
        let search = WallpaperSearch("美女")
        #expect(search.wallhavenQuery == "female portrait")
        #expect(WallpaperSource.featured == [.bizhicang, .tenwallpaper])
        #expect(!WallpaperSource.online.contains(.nasa))
        #expect(!WallpaperSource.online.contains(.hao))
        #expect(!WallpaperSource.online.contains(.netbian))
        let catalog = OnlineCatalog()
        let url = try #require(catalog.firstPage(source: .wallhaven, query: "美女"))
        let parameters = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        #expect(parameters?.first { $0.name == "categories" }?.value == "001")
        #expect(parameters?.first { $0.name == "purity" }?.value == "100")
        #expect(parameters?.first { $0.name == "ratios" }?.value == "landscape")
        #expect(catalog.firstPage(source: .nasa, query: "星云") == nil)
        #expect(catalog.firstPage(source: .hao, query: "美女") == nil)
        #expect(catalog.firstPage(source: .netbian, query: "美女") == nil)
        #expect(try JSONDecoder().decode(WallpaperSource.self, from: Data(#""nasa""#.utf8)) == .nasa)
        #expect(try JSONDecoder().decode(WallpaperSource.self, from: Data(#""hao""#.utf8)) == .hao)
        #expect(try JSONDecoder().decode(WallpaperSource.self, from: Data(#""netbian""#.utf8)) == .netbian)
    }

    @Test func commonsPreservesCreditsAndContinuation() throws {
        let catalog = OnlineCatalog()
        let url = try #require(catalog.firstPage(source: .commons, query: "misty forest", portrait: true))
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        #expect(query?.first { $0.name == "gsrsearch" }?.value == "misty forest incategory:\"Quality images\" filew:>2159 fileh:>3839 filetype:bitmap")
        let page = try ArchivePhotoSources.commonsPage("""
        {"continue":{"gsroffset":16,"continue":"gsroffset||"},"query":{"pages":[
          {"pageid":42,"index":1,"title":"File:Misty forest.jpg","imageinfo":[
            {"url":"https://upload.wikimedia.org/wikipedia/commons/a/ab/Forest.jpg",
             "thumburl":"https://thumb.wikimedia.org/wikipedia/commons/thumb/a/ab/Forest.jpg/960px-Forest.jpg",
             "descriptionurl":"https://commons.wikimedia.org/wiki/File:Misty_forest.jpg","width":3072,
             "height":4608,"size":5000000,"mime":"image/jpeg","extmetadata":{
               "Artist":{"value":"<a href='https://example.com'>Photographer</a>"},"LicenseShortName":{"value":"CC BY 4.0"}}}]},
          {"pageid":43,"index":2,"title":"File:Offsite.jpg","imageinfo":[
            {"url":"https://upload.wikimedia.org.example.com/wikipedia/commons/a/ab/Forest.jpg",
             "thumburl":"https://thumb.wikimedia.org/wikipedia/commons/thumb/a/ab/Forest.jpg/960px-Forest.jpg",
             "descriptionurl":"https://commons.wikimedia.org/wiki/File:Offsite.jpg","width":3840,"height":2160,
             "size":5000000,"mime":"image/jpeg"}]}]}}
        """, at: url)
        #expect(page.items.map(\.id) == ["commons:42"])
        let item = try #require(page.items.first)
        #expect(item.author == "Photographer")
        #expect(item.license == "CC BY 4.0")
        #expect(item.advertisedSize == PixelSize(width: 3072, height: 4608))
        #expect(page.next?.query()?.contains("gsroffset=16") == true)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WALLPAPER_WALL_LIVE_TEST"] == "1"))
    func livePortraitSearchUsesScreenSizedPortraits() async throws {
        let catalog = OnlineCatalog()
        let query = "美女"
        let wallhaven = try #require(catalog.firstPage(source: .wallhaven, query: query))
        let tenwallpaper = try #require(catalog.firstPage(source: .tenwallpaper, query: query))
        async let native = catalog.page(source: .wallhaven, at: wallhaven, query: query)
        async let chinese = catalog.page(source: .tenwallpaper, at: tenwallpaper, query: query)
        let nativeItems = try await native.items
        let chineseItems = try await chinese.items
        #expect(!nativeItems.isEmpty)
        #expect(nativeItems.allSatisfy { $0.advertisedSize?.isUHD == true && ($0.advertisedSize?.aspect ?? 0) > 1 })
        #expect(!chineseItems.isEmpty)
        #expect(chineseItems.allSatisfy { WallpaperSearch(query).matches($0.title) })
        print("美女搜索：Wallhaven 横屏人像 \(nativeItems.count) 张，10wallpaper 匹配 \(chineseItems.count) 张")
    }
}
