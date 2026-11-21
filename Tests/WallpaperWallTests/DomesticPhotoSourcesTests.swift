import Foundation
import Testing
@testable import WallpaperWall

struct DomesticPhotoSourcesTests {
    @Test func storehouseSearchSkipsCloudSharesAndPreservesTheQuery() throws {
        let url = try #require(OnlineCatalog().firstPage(source: .bizhicang, query: "美女"))
        let page = try DomesticPhotoSources.storehouseSearch("""
        {"page":1,"pages":2,"results":[
          {"filename":"biz-00463","title":"横屏人像","width":3840,"height":2160,
           "thumbnail_url":"https://img.bizhicang.com/thumbs/biz-00463.jpg",
           "download_url":"https://t-1308607921.cos.ap-shanghai.myqcloud.com/images/biz-00463.jpg"},
          {"filename":"biz-00470","title":"网盘条目","width":3840,"height":2400,
           "thumbnail_url":"https://img.bizhicang.com/thumbs/biz-00470.jpg",
           "download_url":"https://pan.quark.cn/s/abc"},
          {"filename":"biz-00480","title":"竖屏人像","width":2160,"height":3840,
           "thumbnail_url":"https://img.bizhicang.com/thumbs/biz-00480.jpg",
           "download_url":"https://img.bizhicang.com/images/biz-00480.jpg"},
          {"filename":"biz-00481","title":"小图","width":1920,"height":1080,
           "thumbnail_url":"https://img.bizhicang.com/thumbs/biz-00481.jpg",
           "download_url":"https://img.bizhicang.com/images/biz-00481.jpg"},
          {"filename":"biz-00482","title":"原图标识不符","width":3840,"height":2160,
           "thumbnail_url":"https://img.bizhicang.com/thumbs/biz-00482.jpg",
           "download_url":"https://img.bizhicang.com/images/biz-00483.jpg"}
        ]}
        """, at: url, portrait: false)
        #expect(page.items.map(\.title) == ["横屏人像"])
        #expect(page.items.first?.original?.path == "/images/biz-00463.jpg")
        let next = try #require(page.next)
        let fields = URLComponents(url: next, resolvingAgainstBaseURL: false)?.queryItems
        #expect(fields?.first { $0.name == "q" }?.value == "美女")
        #expect(fields?.first { $0.name == "page" }?.value == "2")
    }

    @Test func storehouseDiscoveryUsesOnlyTheNextCatalogPage() throws {
        let url = try #require(OnlineCatalog().firstPage(source: .bizhicang, query: "", portrait: true))
        let page = DomesticPhotoSources.storehouseCatalog("""
        <div class="wallpaper-item" data-title="竖屏人像" data-res="2160×3840"
             data-url="/p/biz-10676.html" data-dl="https://img.bizhicang.com/images/biz-10676.jpg"
             data-img="https://img.bizhicang.com/thumbs/biz-10676.jpg"></div>
        <a href="/computer/2/">电脑</a><a href="/mobile/2/">下一页</a>
        """, at: url, portrait: true)
        #expect(page.items.map(\.title) == ["竖屏人像"])
        #expect(page.next?.path(percentEncoded: false) == "/mobile/2/")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WALLPAPER_WALL_LIVE_TEST"] == "1"))
    func liveStorehouseDiscoveryAndPagination() async throws {
        let catalog = OnlineCatalog()
        let url = try #require(catalog.firstPage(source: .bizhicang, query: ""))
        let first = try await catalog.page(source: .bizhicang, at: url)
        #expect(!first.items.isEmpty)
        let next = try #require(first.next)
        let second = try await catalog.page(source: .bizhicang, at: next)
        #expect(second.items.contains { item in !first.items.contains { $0.id == item.id } })
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WALLPAPER_WALL_LIVE_TEST"] == "1"),
          arguments: WallpaperSource.featured)
    func liveDomesticPortraitDownload(source: WallpaperSource) async throws {
        let catalog = OnlineCatalog()
        let query = try #require(WallpaperSearch("美女").domesticTopic)
        let url = try #require(catalog.firstPage(source: source, query: query))
        let page = try await catalog.page(source: source, at: url, query: query)
        let item = try #require(page.items.first)
        let thumb = try #require(item.thumbnail)
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = ImageVault(root: root)
        let preview = try await vault.preview(at: thumb, maxPixel: 450)
        #expect(preview.width >= 200)
        let requirements = WallpaperRequirements(preferredScreen: PixelSize(width: 3024, height: 1964))
        let urls = try await catalog.originalURLs(for: item, requirements: requirements)
        let original = try await vault.verifyOriginal(urls, requirements: requirements)
        let saved = try await vault.save(original, requirements: requirements, destination: nil, title: item.title)
        #expect(original.size.isUHD)
        #expect(saved.isAvailable)
        print("\(source.name) · 检索 \(page.items.count) 张 · \(item.title) · 原图 \(original.size.label) 已保存")
    }
}
