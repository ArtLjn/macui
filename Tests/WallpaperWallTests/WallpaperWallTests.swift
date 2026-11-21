import AppKit
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import WallpaperWall

struct WallpaperWallTests {
    @Test func chineseSearchAndPaging() throws {
        let url = try #require(OnlineCatalog().firstPage(source: .wallpic, query: "海边/日落"))
        #expect(url.absoluteString.contains("%2F"))
        let pageURL = try #require(OnlineCatalog().firstPage(source: .wallpic, query: "风景"))
        let page = OnlineCatalog.parsePage("""
        <a href="/331.html"><img alt="江边风景-4K 高清免费壁纸" data-src="/wp-content/uploads/river.webp"></a>
        <a href="/331.html"><img src="/wp-content/uploads/duplicate.jpg"></a>
        <a href="/337.html"><img src="https://example.invalid/fake.jpg"></a>
        <a href="/search/风景/page/2">下一页</a>
        """, source: .wallpic, url: pageURL)
        #expect(page.items.map(\.title) == ["江边风景"])
        #expect(page.next?.path.hasSuffix("/page/2") == true)
    }

    @Test func tenwallpaperPrefersPublicUHD() throws {
        let page = try #require(URL(string: "https://www.10wallpaper.com/cn/view/scene.html"))
        let html = """
        <a href="/wallpaper/1024x768/scene.jpg" download="小图">1024</a>
        <a href="/wallpaper/7680x4320/scene.jpg" download="8K">8K</a>
        <a href="/wallpaper/5120x1440/scene.jpg" download="超宽">超宽</a>
        <a href="/wallpaper/3840x2160/scene.jpg" download="4K">4K</a>
        <a href="/wallpaper/5120x3200/scene.jpg" download="5K">5K</a>
        <a href="/wallpaper/5120x3200/scene.jpg" download="重复的5K">5K</a>
        """
        let links = OnlineCatalog.originalLinks(html, source: .tenwallpaper, page: page)
        #expect(links.first?.path == "/wallpaper/3840x2160/scene.jpg")
        #expect(links.count == 3)
        let mac = WallpaperRequirements(preferredScreen: PixelSize(width: 3024, height: 1964))
        let preferred = OnlineCatalog.originalLinks(html, source: .tenwallpaper, page: page, requirements: mac)
        #expect(preferred.first?.path == "/wallpaper/5120x3200/scene.jpg")
    }

    @Test func displayRatioAndActualUHD() {
        let retina = PixelSize(width: 3024, height: 1964)
        let requirements = WallpaperRequirements(screenAspects: [retina.aspect])
        let wide = PixelSize(width: 3840, height: 2160)
        let mac = PixelSize(width: 5120, height: 3200)
        let portrait = PixelSize(width: 2160, height: 3840)
        let ultrawide = PixelSize(width: 5120, height: 2160)
        let faux4K = PixelSize(width: 4500, height: 2048)
        #expect(requirements.issue(for: wide) == nil)
        #expect(requirements.issue(for: mac) == nil)
        #expect(requirements.issue(for: portrait) == .mismatchedAspect(portrait))
        #expect(requirements.issue(for: ultrawide) == .mismatchedAspect(ultrawide))
        #expect(requirements.issue(for: faux4K) == .belowUHD(faux4K))
        #expect(Placement.fill.scale(from: wide, to: retina) < 1)
        #expect(Placement.fill.scale(from: wide, to: PixelSize(width: 5120, height: 2880)) > 1)
        #expect(Placement.fill.scale(from: portrait, to: retina) > Placement.fit.scale(from: portrait, to: retina))
        #expect(WallpaperRequirements(screenAspects: [retina.aspect, portrait.aspect]).issue(for: mac) == .mismatchedAspect(mac))
    }

    @Test func compoundChineseSearchKeepsEveryConcept() throws {
        let search = WallpaperSearch("4K 海边日落壁纸")
        #expect(search.wallhavenQuery == "coast sunset")
        #expect(search.chineseFallback == "海边")
        #expect(search.matches("海岸的夕阳，橘色天空"))
        #expect(!search.matches("海边日出"))
        #expect(!search.matches("山顶的日落"))
        #expect(WallpaperSearch("莫干山下雪").wallhavenQuery == nil)
        let catalog = OnlineCatalog()
        let url = try #require(catalog.firstPage(source: .wallhaven, query: "海边日落", portrait: true))
        #expect(url.query()?.contains("sorting=relevance") == true)
        #expect(url.query()?.contains("ratios=portrait") == true)
        #expect(catalog.firstPage(source: .wallhaven, query: "莫干山下雪") == nil)
        let chineseURL = try #require(catalog.firstPage(source: .wallpic, query: "海边"))
        let page = OnlineCatalog.parsePage("""
        <a href="/331.html"><img alt="海岸夕阳" data-src="/wp-content/uploads/sunset.webp"></a>
        <a href="/332.html"><img alt="海边日出" data-src="/wp-content/uploads/sunrise.webp"></a>
        <a href="/search/海边/page/2">下一页</a>
        """, source: .wallpic, url: chineseURL, search: search)
        #expect(page.items.map(\.title) == ["海岸夕阳"])
        #expect(page.next != nil)
    }

    @Test func parsesNativeSourceMetadataAndBingOriginalURL() throws {
        let url = try #require(OnlineCatalog().firstPage(source: .wallhaven, query: "海边日落"))
        #expect(url.absoluteString.contains("coast"))
        let page = try HDPhotoSources.wallhavenPage("""
        {"data":[{"id":"7jmgey","url":"https://wallhaven.cc/w/7jmgey",
        "path":"https://w.wallhaven.cc/full/7j/wallhaven-7jmgey.png","dimension_x":3840,"dimension_y":2400,
        "purity":"sfw","category":"general","thumbs":{"small":"https://th.wallhaven.cc/small/7j/7jmgey.jpg",
        "original":"https://th.wallhaven.cc/orig/7j/7jmgey.jpg"}}],
        "meta":{"current_page":1,"last_page":2}}
        """, at: url)
        #expect(page.items.first?.advertisedSize == PixelSize(width: 3840, height: 2400))
        #expect(page.items.first?.thumbnail?.path.hasPrefix("/small/") == true)
        #expect(page.items.first?.preview?.path.hasPrefix("/orig/") == true)
        #expect(page.next?.query()?.contains("page=2") == true)
        let bing = try HDPhotoSources.bingPage("""
        {"images":[{"urlbase":"/th?id=OHR.Ocean_ZH-CN123","title":"海边日落","copyright":"摄影师"}]}
        """, query: "日落")
        let item = try #require(bing.items.first)
        #expect(item.original?.absoluteString == "https://www.bing.com/th?id=OHR.Ocean_ZH-CN123_UHD.jpg")
        #expect(item.thumbnail?.absoluteString.hasSuffix("_320x180.jpg") == true)
        #expect(item.advertisedSize == nil)
        let unrelated = try HDPhotoSources.bingPage("""
        {"images":[{"urlbase":"/th?id=OHR.Sunset_ZH-CN123","title":"港口的清晨","copyright":"摄影师"}]}
        """, query: "日落")
        #expect(unrelated.items.isEmpty)
    }

    @Test @MainActor func importOfflineAndReload() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appending(path: "待导入.png")
        try writeFixture(at: input)
        let vaultURL = root.appending(path: "库")
        let model = WallModel(root: vaultURL)
        await model.importFiles([input, input])
        let wallpaper = try #require(model.selected)
        #expect(model.section == .library)
        #expect(model.visibleItems.count == 1)
        #expect(model.downloaded.count == 1)
        model.toggleFavorite(wallpaper)
        try FileManager.default.removeItem(at: input)
        let reloaded = WallModel(root: vaultURL)
        let stored = try #require(reloaded.localImage(for: wallpaper))
        let preview = try await reloaded.vault.preview(at: stored.original, maxPixel: 80)
        #expect(preview.dimensions == "3840 × 2400")
        #expect(reloaded.entry(for: wallpaper)?.favorite == true)
    }

    @Test @MainActor func partialApplyRetryAndRestore() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appending(path: "新图片.png")
        try writeFixture(at: input)
        let desktop = TestDesktop()
        let previous = desktop.files
        let storage = root.appending(path: "图库")
        let model = WallModel(root: storage, desktop: desktop)
        await model.importFiles([input])
        let item = try #require(model.selected)
        await model.apply(item, to: ["left", "portrait"], placement: .fill)
        #expect(desktop.applyTargets.isEmpty)
        #expect(model.status?.contains("裁掉较多内容") == true)
        await model.apply(item, to: ["left", "right"], placement: .fit)
        #expect(model.canRetry)
        #expect(model.canUndo)
        #expect(model.currentName == "新图片")
        #expect(model.entry(for: item)?.usedAt != nil)
        #expect(desktop.files["right"] == previous["right"])
        #expect(desktop.backdrop?.blue ?? 0 > 0)
        desktop.unavailable = []
        await model.retryFailedDisplays()
        #expect(desktop.applyTargets == [["left", "right"], ["right"]])
        #expect(!model.canRetry)
        let reloaded = WallModel(root: storage, desktop: desktop)
        await reloaded.undo()
        #expect(!reloaded.canUndo)
        #expect(desktop.files == previous)
    }

    @Test @MainActor func downloadDirectoryPersistsAndKeepsOriginal() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let destination = root.appending(path: "自选目录")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appending(path: "原始文件.png")
        try writeFixture(at: input)
        let data = try Data(contentsOf: input)
        let appStorage = root.appending(path: "图库")
        let model = WallModel(root: appStorage, desktop: TestDesktop())
        model.changeDownloadFolder(destination)
        let reloaded = WallModel(root: appStorage, desktop: TestDesktop())
        #expect(reloaded.downloadFolder.path == destination.path)
        let stored = try await reloaded.vault.store(data, destination: reloaded.customDownloadFolder, title: "海边/风景")
        #expect(stored.original.deletingLastPathComponent().path == destination.path)
        #expect(stored.original.lastPathComponent.hasPrefix("海边_风景"))
        #expect(try Data(contentsOf: stored.original) == data)
        let small = root.appending(path: "小图.png")
        try writeFixture(at: small, width: 32, height: 24)
        let smallData = try Data(contentsOf: small)
        let smallPreview = try await reloaded.vault.preview(at: small, maxPixel: 20)
        #expect(smallPreview.size == PixelSize(width: 32, height: 24))
        await #expect(throws: WallpaperError.belowUHD(PixelSize(width: 32, height: 24))) {
            try await reloaded.vault.store(smallData, requirements: WallpaperRequirements(),
                                           destination: destination, title: "禁止下载")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).count == 1)
    }

    @Test func rejectNonImage() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appending(path: "不是图片.jpg")
        try Data("<html>文件不可用</html>".utf8).write(to: input)
        let vault = ImageVault(root: root)
        await #expect(throws: WallpaperError.invalidImage) {
            try await vault.importFile(input)
        }
    }

    @Test func rotatedFileProducesUprightDesktopCopy() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "旋转原件.tiff")
        try writeFixture(at: file, type: .tiff, orientation: 6)
        let vault = ImageVault(root: root)
        let stored = try await vault.importFile(file)
        #expect(stored.size == PixelSize(width: 2400, height: 3840))
        #expect(stored.original != stored.desktop)
        let preview = try await vault.preview(at: stored.desktop, maxPixel: 300)
        #expect(preview.size == stored.size)
        #expect(preview.image.width < preview.image.height)
    }

    @Test func preloadedThumbnailReusesDecodedImage() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "缩略图.png")
        try writeFixture(at: file, width: 480, height: 320)
        let vault = ImageVault(root: root)
        await vault.preloadThumbnails([file], maxPixel: 260)
        let first = try await vault.preview(at: file, maxPixel: 260)
        let second = try await vault.preview(at: file, maxPixel: 260)
        #expect(first.image === second.image)
        #expect(first.image.width == 260)
    }

    @Test @MainActor func appliesEnhancedCopyAndKeepsOriginalForUndo() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appending(path: "画质测试.png")
        try writeFixture(at: input)
        let desktop = TestDesktop()
        let model = WallModel(root: root.appending(path: "图库"), desktop: desktop)
        await model.importFiles([input])
        let item = try #require(model.selected)
        let saved = try #require(model.localImage(for: item))
        let originalBytes = try Data(contentsOf: saved.original)

        let before = try await model.vault.preview(at: saved.desktop, maxPixel: 180)
        let after = try await model.vault.preview(at: saved.desktop, maxPixel: 180, enhanced: true)
        #expect(before.image !== after.image)
        #expect(before.dimensions == after.dimensions)

        model.enhancesWallpaper = true
        await model.apply(item, to: ["left"], placement: .fit)
        let enhancedFile = try #require(desktop.files["left"])
        #expect(enhancedFile != saved.desktop)
        #expect(enhancedFile == model.vault.enhancedLocation(for: saved.desktop))
        #expect(model.currentName == "画质测试")
        #expect(model.status == "已设为增强壁纸")
        let processed = try await model.vault.preview(at: enhancedFile, maxPixel: 180)
        #expect(processed.size == saved.size)
        let date = try enhancedFile.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let reused = try await model.vault.enhancedDesktop(for: saved.desktop)
        #expect(reused == enhancedFile)
        #expect(try reused.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == date)
        #expect(try Data(contentsOf: saved.original) == originalBytes)
        #expect(model.localImage(for: item)?.desktop == saved.desktop)

        model.enhancesWallpaper = false
        await model.apply(item, to: ["left"], placement: .fit)
        #expect(desktop.files["left"] == saved.desktop)
        await model.undo()
        #expect(desktop.files["left"] == enhancedFile)
        #expect(model.currentName == "画质测试")
    }

    @Test @MainActor func wallpaperTintKeepsSurfacesDarkAndDistinct() throws {
        let warm = WallPalette(wallpaper: DesktopBackdrop(red: 1, green: 0.55, blue: 0.18))
        let cool = WallPalette(wallpaper: DesktopBackdrop(red: 0.14, green: 0.56, blue: 1))
        let warmBase = try #require(NSColor(warm.canvas).usingColorSpace(.sRGB))
        let coolBase = try #require(NSColor(cool.canvas).usingColorSpace(.sRGB))
        let warmSidebar = try #require(NSColor(warm.sidebar).usingColorSpace(.sRGB))
        #expect(warmBase.redComponent > warmBase.blueComponent + 0.08)
        #expect(coolBase.blueComponent > coolBase.redComponent + 0.08)
        #expect(warmBase.alphaComponent == 1)
        #expect(warmBase.redComponent < 0.2)
        #expect(warmSidebar.greenComponent > warmBase.greenComponent)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WALLPAPER_WALL_DESKTOP_TEST"] == "1"))
    @MainActor func liveDesktopPlacementAndRestore() async throws {
        _ = NSApplication.shared
        let workspace = NSWorkspace.shared
        let screen = try #require(NSScreen.screens.first)
        let previous = try #require(workspace.desktopImageURL(for: screen))
        let options = try #require(workspace.desktopImageOptions(for: screen))
        try #require(previous.isFileURL && !previous.path.hasPrefix("/System/"))
        try #require(["jpg", "jpeg", "png"].contains(previous.pathExtension.lowercased()))
        try #require(FileManager.default.isReadableFile(atPath: previous.path))
        let service = DesktopService()
        let display = try #require(service.displays.first)
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "桌面测试.png")
        try writeFixture(at: file, height: 2160)
        defer {
            if workspace.desktopImageURL(for: screen)?.standardizedFileURL != previous.standardizedFileURL {
                try? workspace.setDesktopImageURL(previous, for: screen, options: options)
            }
        }
        let vault = ImageVault(root: root)
        let preview = try await vault.preview(at: file, maxPixel: 96)
        let applied = await service.apply(file, to: [display.id], placement: .fit, backdrop: preview.backdrop)
        #expect(applied.successful == 1)
        let desktopLevel = NSWindow.Level.wallpaperTransition.rawValue
        if !workspace.accessibilityDisplayShouldReduceMotion,
           UserDefaults.standard.object(forKey: WallAppearance.animatesWallpaper) as? Bool ?? true {
            let cover = try #require(NSApp.windows.first { $0.level.rawValue == desktopLevel && $0.isVisible })
            #expect(cover.ignoresMouseEvents)
            #expect(!cover.canBecomeKey)
            #expect(cover.level.rawValue < Int(CGWindowLevelForKey(.desktopIconWindow)))
        }
        let appliedFile = try await waitForDesktop(service, id: display.id, expected: file)
        #expect(appliedFile)
        let liveOptions = workspace.desktopImageOptions(for: screen)
        #expect((liveOptions?[.allowClipping] as? NSNumber)?.boolValue == false)
        if let color = (liveOptions?[.fillColor] as? NSColor)?.usingColorSpace(.sRGB) {
            #expect(abs(Double(color.blueComponent) - preview.backdrop.blue) < 0.03)
        } else {
            Issue.record("没有读到适应模式的桌面配色")
        }
        let restored = await service.restore(applied.previous)
        #expect(restored.successful == 1)
        let restoredFile = try await waitForDesktop(service, id: display.id, expected: previous)
        #expect(restoredFile)
        for _ in 0..<35 {
            if !NSApp.windows.contains(where: { $0.level.rawValue == desktopLevel && $0.isVisible }) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(!NSApp.windows.contains { $0.level.rawValue == desktopLevel && $0.isVisible })
    }

    @MainActor private func waitForDesktop(_ service: DesktopService, id: String, expected: URL) async throws -> Bool {
        for _ in 0..<20 {
            if service.current(on: id)?.standardizedFileURL == expected.standardizedFileURL { return true }
            try await Task.sleep(for: .milliseconds(150))
        }
        return false
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WALLPAPER_WALL_LIVE_TEST"] == "1"),
          arguments: WallpaperSource.online.filter { !WallpaperSource.featured.contains($0) })
    func liveSourcesPreviewAndDownloads(source: WallpaperSource) async throws {
        let catalog = OnlineCatalog()
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = ImageVault(root: root)
        let query = switch source {
        case .bing: ""
        case .commons: "misty forest"
        default: "风景"
        }
        let url = try #require(catalog.firstPage(source: source, query: query))
        let start = ContinuousClock().now
        let page = try await catalog.page(source: source, at: url, query: query)
        let sample = try #require(page.items.first, "\(source.name) 没有返回结果")
        let thumb = try #require(sample.thumbnail)
        let preview = try await vault.preview(at: thumb, maxPixel: 450)
        #expect(preview.width >= 200)
        let browseTime = start.duration(to: ContinuousClock().now)
        let requirement = WallpaperRequirements(preferredScreen: PixelSize(width: 3024, height: 1964))
        let urls = try await catalog.originalURLs(for: sample, requirements: requirement)
        let urlToVerify = try #require(urls.first)
        do {
            let original = try await vault.verifyOriginal([urlToVerify], requirements: requirement)
            #expect(original.size.isUHD)
            print("\(source.name)：返回 \(page.items.count) 张，首图 \(browseTime)，验证原图 \(original.size.label)")
        } catch WallpaperError.belowUHD(let size) where source == .wallpic {
            #expect(!size.isUHD)
            print("\(source.name)：首图 \(browseTime)，公开图片 \(size.label)，已拦截")
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WALLPAPER_WALL_LIVE_TEST"] == "1"))
    func liveCompoundSearch() async throws {
        let catalog = OnlineCatalog()
        let query = "海边日落"
        let url = try #require(catalog.firstPage(source: .wallhaven, query: query))
        let page = try await catalog.page(source: .wallhaven, at: url, query: query)
        #expect(!page.items.isEmpty)
        #expect(page.items.allSatisfy { $0.thumbnail != nil })
    }

    private func writeFixture(at url: URL, width: Int = 3840, height: Int = 2400,
                              type: UTType = .png, orientation: Int = 1) throws {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.22, green: 0.43, blue: 0.57, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let destination = try #require(
            CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
    }
}

@MainActor
private final class TestDesktop: DesktopChanging {
    let displays = [
        Display(id: "left", name: "主显示器", pixels: PixelSize(width: 3024, height: 1964)),
        Display(id: "right", name: "外接显示器", pixels: PixelSize(width: 3840, height: 2160)),
        Display(id: "portrait", name: "竖屏", pixels: PixelSize(width: 2160, height: 3840))
    ]
    var files = ["left": URL(fileURLWithPath: "/left.jpg"), "right": URL(fileURLWithPath: "/right.jpg")]
    var unavailable: Set<String> = ["right"]
    var applyTargets: [[String]] = []
    var backdrop: DesktopBackdrop?

    func current(on displayID: String?) -> URL? { files[displayID ?? ""] }

    func apply(_ image: URL, to displayIDs: [String], placement: Placement, backdrop: DesktopBackdrop) async -> DesktopChange {
        applyTargets.append(displayIDs)
        self.backdrop = backdrop
        var result = DesktopChange()
        for id in displayIDs {
            if unavailable.contains(id) {
                result.errors[id] = "屏幕已断开"
            } else if let previous = files.updateValue(image, forKey: id) {
                result.successful += 1
                result.previous.append(DesktopSnapshot(
                    displayID: id, file: previous, scaling: nil, clipping: nil, fillColor: nil
                ))
            }
        }
        return result
    }

    func restore(_ snapshots: [DesktopSnapshot]) async -> DesktopChange {
        for snapshot in snapshots { files[snapshot.displayID] = snapshot.file }
        return DesktopChange(successful: snapshots.count)
    }
}
