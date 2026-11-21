import AppKit
import Observation

enum WallSection: String, CaseIterable, Identifiable {
    case discover = "发现壁纸"
    case library = "我的图库"
    case recent = "最近使用"

    var id: Self { self }

    var icon: String {
        switch self {
        case .discover: "square.grid.2x2"
        case .library: "photo.on.rectangle.angled"
        case .recent: "clock.arrow.circlepath"
        }
    }
}

@MainActor
@Observable
final class WallModel {
    static let allDisplays = "all-displays"

    var section = WallSection.discover
    var query = ""
    var aiSearchEnabled = false
    private(set) var aiSearchNotice: String?
    var source: WallpaperSource?
    var localQuery = ""
    var favoritesOnly = false
    var selected: Wallpaper?
    var enhancesWallpaper = false
    var placement = Placement.fill
    var targetDisplay: String?
    var status: String?
    var catalogNotice: String?
    private(set) var results: [Wallpaper] = []
    private(set) var searching = false
    private(set) var busy = false
    private(set) var displays: [Display] = []
    private(set) var currentFile: URL?
    private(set) var index = LibraryIndex()

    let vault: ImageVault
    let catalog = OnlineCatalog()
    let liveWallpaper: WallpaperMotionPlayback
    private let storage: LibraryStorage
    private let desktop: any DesktopChanging
    private var searchTask: Task<Void, Never>?
    private var sourceQueries: [WallpaperSource: String] = [:]
    private var lastAIQuery: (input: String, terms: AIWallpaperTerms)?
    private var downloadTask: Task<StoredImage, Error>?
    private var nextPages: [WallpaperSource: URL] = [:]
    private var pausedSources = Set<WallpaperSource>()
    private var emptyPageStreak = 0
    private var inspected = Set<String>()
    private var fullPreview: (id: String, original: VerifiedOriginal)?
    private var searchedPortrait = false
    @ObservationIgnored private var thumbnailPrefetch: Task<Void, Never>?
    @ObservationIgnored private var prefetchWindow: (firstID: String?, maxPixel: Int, end: Int)?
    private var started = false
    private var storageError: String?
    private var retry: (item: Wallpaper, image: StoredImage, file: URL, ids: [String], placement: Placement, backdrop: DesktopBackdrop,
                        animated: Bool, keepUndo: Bool)?

    init(
        root: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "WallpaperWall", directoryHint: .isDirectory),
        desktop: any DesktopChanging = DesktopService()
    ) {
        storage = LibraryStorage(root: root)
        vault = ImageVault(root: root)
        liveWallpaper = WallpaperMotionPlayback(root: root)
        self.desktop = desktop
        do {
            index = try storage.load()
        } catch {
            storageError = "无法读取图库，原索引已保留。\(error.localizedDescription)"
            status = storageError
        }
        refreshDisplays()
    }

    var hasMore: Bool { !nextPages.isEmpty }
    var canUndo: Bool { !index.undo.isEmpty }
    var canRetry: Bool { retry != nil }
    var canCancelDownload: Bool { downloadTask != nil }
    var operationStatus: String? { liveWallpaper.message ?? status }
    var matchScreen: Bool { index.matchScreen ?? true }
    var customDownloadFolder: URL? { index.downloadFolder }
    var downloadFolder: URL {
        index.downloadFolder ?? vault.root.appending(path: "Images", directoryHint: .isDirectory)
    }
    var currentName: String {
        guard let currentFile else { return "系统桌面" }
        return index.entries.values
            .filter { matchesDesktop($0.image, file: currentFile) }
            .max { ($0.usedAt ?? .distantPast) < ($1.usedAt ?? .distantPast) }?.wallpaper.title
            ?? "系统桌面"
    }

    private func matchesDesktop(_ image: StoredImage?, file: URL?) -> Bool {
        guard let image, let target = file?.standardizedFileURL else { return false }
        if image.desktop.standardizedFileURL == target { return true }
        return target.deletingLastPathComponent().path == vault.enhancementFolder.path
            && vault.enhancedLocation(for: image.desktop).standardizedFileURL == target
    }

    var previewDisplay: Display? {
        displays.first { $0.id == targetDisplay } ?? displays.first
    }

    var downloaded: [LibraryEntry] {
        index.entries.values.filter { localImage(for: $0.wallpaper) != nil }
            .sorted { ($0.savedAt ?? .distantPast) > ($1.savedAt ?? .distantPast) }
    }

    var visibleItems: [Wallpaper] {
        switch section {
        case .discover: return discoverItems
        case .library:
            return index.entries.values
                .filter { $0.favorite || (!favoritesOnly && localImage(for: $0.wallpaper) != nil) }
                .sorted { ($0.savedAt ?? .distantPast) > ($1.savedAt ?? .distantPast) }
                .map(\.wallpaper)
                .filter { localQuery.isEmpty || $0.title.localizedCaseInsensitiveContains(localQuery) }
        case .recent:
            return index.entries.values.filter { $0.usedAt != nil && originalSize(for: $0.wallpaper) != nil }
                .sorted { ($0.usedAt ?? .distantPast) > ($1.usedAt ?? .distantPast) }
                .map(\.wallpaper)
        }
    }

    private var discoverItems: [Wallpaper] {
        let requirements = imageRequirements()
        return results.filter { item in
            guard let size = originalSize(for: item) ?? item.advertisedSize else { return true }
            return requirements.issue(for: size) == nil
        }
    }

    func start() {
        guard !started else { return }
        started = true
        search()
    }

    func selectSection(_ newSection: WallSection) {
        cancelThumbnailPrefetch()
        section = newSection
        selected = visibleItems.first
    }

    func selectRelative(_ offset: Int) {
        let items = visibleItems
        guard !items.isEmpty else { return }
        guard let index = items.firstIndex(where: { $0.id == selected?.id }) else {
            selected = items.first
            return
        }
        selected = items[min(max(index + offset, 0), items.count - 1)]
    }

    func refreshDisplays() {
        displays = desktop.displays
        if targetDisplay != Self.allDisplays && !displays.contains(where: { $0.id == targetDisplay }) {
            targetDisplay = displays.first?.id
        }
        currentFile = desktop.current(on: displays.first?.id)
    }

    func desktopFile(on displayID: String?) -> URL? {
        desktop.current(on: displayID ?? displays.first?.id)
    }

    func imageRequirements(for ids: [String]? = nil, placement: Placement? = nil) -> WallpaperRequirements {
        let ids = ids ?? selectedDisplayIDs
        let targets = displays.filter { ids.contains($0.id) }.map(\.pixels)
        let aspects = matchScreen && (placement ?? self.placement) == .fill ? targets.map(\.aspect) : []
        let preferred = targets.max { $0.width * $0.height < $1.width * $1.height }
        return WallpaperRequirements(screenAspects: aspects, preferredScreen: preferred)
    }

    func changeMatchScreen(_ enabled: Bool) {
        guard enabled != matchScreen else { return }
        var next = index
        next.matchScreen = enabled
        guard commit(next) else { return }
        cancelDownload()
        previewDisplayChanged()
    }

    func previewDisplayChanged() {
        cancelThumbnailPrefetch()
        emptyPageStreak = 0
        let portrait = previewDisplay.map { $0.pixels.aspect < 1 } ?? false
        if section == .discover, started, portrait != searchedPortrait,
           source == nil || source == .wallhaven || source == .commons || source == .bizhicang {
            search()
            return
        }
        if section == .discover, visibleItems.allSatisfy({ $0.id != selected?.id }) {
            selected = visibleItems.first
        }
    }

    func changeDownloadFolder(_ url: URL?) {
        if let url, !url.isFileURL || (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true {
            status = WallpaperError.unavailableFolder.localizedDescription
            return
        }
        var next = index
        next.downloadFolder = url?.standardizedFileURL
        if commit(next) { status = "下载位置已更新" }
    }

    func openDownloadFolder() {
        do {
            if customDownloadFolder == nil {
                try FileManager.default.createDirectory(at: downloadFolder, withIntermediateDirectories: true)
            }
            if !NSWorkspace.shared.open(downloadFolder) { throw WallpaperError.unavailableFolder }
        } catch {
            status = error.localizedDescription
        }
    }

    func entry(for item: Wallpaper) -> LibraryEntry? { index.entries[item.id] }
    func localImage(for item: Wallpaper) -> StoredImage? {
        guard let image = entry(for: item)?.image, image.size.isUHD, image.isAvailable else { return nil }
        return image
    }

    func thumbnailURL(for item: Wallpaper) -> URL? {
        localImage(for: item)?.original ?? item.thumbnail ?? item.preview
    }

    func prefetchThumbnails(in items: [Wallpaper], after item: Wallpaper, maxPixel: Int) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        if let window = prefetchWindow,
           (window.firstID != items.first?.id || window.maxPixel != maxPixel) {
            cancelThumbnailPrefetch()
        }
        let start = index + 1
        let end = min(start + 6, items.count)
        let previousEnd = prefetchWindow?.end ?? 0
        guard start < end, end > previousEnd, start + 2 >= previousEnd else { return }
        let urls = items[start..<end].compactMap { thumbnailURL(for: $0) }
        thumbnailPrefetch?.cancel()
        prefetchWindow = (items.first?.id, maxPixel, end)
        thumbnailPrefetch = Task(priority: .utility) { [vault] in
            await vault.preloadThumbnails(urls, maxPixel: maxPixel)
        }
    }

    func cancelThumbnailPrefetch() {
        thumbnailPrefetch?.cancel()
        thumbnailPrefetch = nil
        prefetchWindow = nil
    }

    func originalSize(for item: Wallpaper) -> PixelSize? {
        localImage(for: item)?.size ?? (fullPreview?.id == item.id ? fullPreview?.original.size : nil)
    }

    func verifiedPreviewFile(for item: Wallpaper) -> URL? {
        fullPreview?.id == item.id ? fullPreview?.original.file : nil
    }

    func fullPreviewImage(for item: Wallpaper, maxPixel: Int, enhanced: Bool = false) async throws -> ImagePreview {
        if let saved = localImage(for: item) {
            return try await vault.preview(at: saved.desktop, maxPixel: maxPixel, enhanced: enhanced)
        }
        if fullPreview?.id == item.id, let original = fullPreview?.original {
            return try await vault.preview(at: original.file, maxPixel: maxPixel, enhanced: enhanced)
        }
        let requirements = WallpaperRequirements(preferredScreen: previewDisplay?.pixels)
        let urls = try await catalog.originalURLs(for: item, requirements: requirements)
        let original = try await vault.verifyOriginal(urls, requirements: requirements)
        try Task.checkCancellation()
        fullPreview = (item.id, original)
        return try await vault.preview(at: original.file, maxPixel: maxPixel, enhanced: enhanced)
    }

    func search() {
        searchTask?.cancel()
        cancelThumbnailPrefetch()
        pausedSources = []
        emptyPageStreak = 0
        results = []
        if section == .discover { selected = nil }
        fullPreview = nil
        catalogNotice = nil
        aiSearchNotice = nil
        inspected = []
        nextPages = [:]
        sourceQueries = [:]
        let input = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let search = WallpaperSearch(input)
        let source = source
        let useAI = aiSearchEnabled && !search.text.isEmpty
        let portrait = previewDisplay.map { $0.pixels.aspect < 1 } ?? false
        searchedPortrait = portrait
        searching = true
        searchTask = Task {
            var terms: AIWallpaperTerms?
            if useAI {
                do {
                    if let recent = lastAIQuery, recent.input == input {
                        terms = recent.terms
                    } else {
                        let configuration = try AIWallpaperConfiguration.load()
                        let expanded = try await AIWallpaperSearch.expand(input, configuration: configuration)
                        try Task.checkCancellation()
                        terms = expanded
                        lastAIQuery = (input, expanded)
                    }
                    if let terms { aiSearchNotice = "AI 关键词 · \(terms.chinese) · \(terms.english)" }
                } catch {
                    guard !Task.isCancelled else { return }
                    let reason = (error as? AIWallpaperSearchError)?.errorDescription ?? "暂时无法连接模型。"
                    aiSearchNotice = "\(reason)已切回普通搜索。"
                }
            }
            guard !Task.isCancelled else { return }

            let sources = source.map { [$0] } ?? WallpaperSource.featured
            sourceQueries = Dictionary(uniqueKeysWithValues: sources.map { source in
                let topic = WallpaperSource.featured.contains(source) ? search.domesticTopic : nil
                return (source, topic ?? terms?.query(for: source) ?? input)
            })
            nextPages = Dictionary(uniqueKeysWithValues: sourceQueries.compactMap { source, term in
                catalog.firstPage(source: source, query: term, portrait: portrait, peopleOnly: search.isPortraitPhotography)
                    .map { (source, $0) }
            })
            if nextPages.isEmpty, let source, search.containsChinese {
                searching = false
                catalogNotice = "\(source.name) 暂无这个中文词的对应关键词。可以用英文、开启 AI 搜索，或选择「国内精选」。"
                return
            }
            await fetchPages(nextPages, queries: sourceQueries, featured: search.text.isEmpty)
        }
    }

    func invalidateAISearch() {
        lastAIQuery = nil
        if aiSearchEnabled, !WallpaperSearch(query).text.isEmpty { search() }
    }

    func loadMore(automatically: Bool = false) {
        guard !searching && hasMore else { return }
        if automatically {
            guard section == .discover, emptyPageStreak < 2 else { return }
        } else {
            emptyPageStreak = 0
        }
        let pages = automatically ? nextPages.filter { !pausedSources.contains($0.key) } : nextPages
        guard !pages.isEmpty else { return }
        searching = true
        let queries = sourceQueries
        let featured = queries.values.allSatisfy { WallpaperSearch($0).text.isEmpty }
        searchTask = Task { await fetchPages(pages, queries: queries, featured: featured) }
    }

    private enum SearchEvent: Sendable {
        case page(WallpaperSource, CatalogPage)
        case sourceFailed(WallpaperSource)
    }

    private func fetchPages(_ pages: [WallpaperSource: URL], queries: [WallpaperSource: String], featured: Bool) async {
        guard !Task.isCancelled else { return }
        catalogNotice = nil
        var failures: [String] = []
        var batches: [WallpaperSource: [Wallpaper]] = [:]
        let initialCount = discoverItems.count
        let portrait = searchedPortrait
        await withTaskGroup(of: SearchEvent.self) { group in
            for source in WallpaperSource.online {
                guard let url = pages[source], let term = queries[source] else { continue }
                group.addTask { [catalog] in
                    do { return .page(source, try await catalog.page(source: source, at: url, query: term, portrait: portrait)) }
                    catch { return .sourceFailed(source) }
                }
            }
            for await event in group {
                guard !Task.isCancelled else { group.cancelAll(); break }
                switch event {
                case .page(let source, let page):
                    pausedSources.remove(source)
                    nextPages[source] = page.next == pages[source] ? nil : page.next
                    let unique = page.items.filter { inspected.insert($0.id).inserted }
                    let targets = displays.filter { selectedDisplayIDs.contains($0.id) }.map(\.pixels)
                    let ranked = featured ? unique.sorted { discoveryScore($0, screens: targets) < discoveryScore($1, screens: targets) } : unique
                    batches[source] = ranked
                case .sourceFailed(let source):
                    pausedSources.insert(source)
                    failures.append(source.name)
                }
            }
        }
        guard !Task.isCancelled else { return }
        let ordered = WallpaperSource.online.compactMap { batches[$0] }
        for row in 0..<(ordered.map(\.count).max() ?? 0) {
            for batch in ordered where row < batch.count { results.append(batch[row]) }
        }
        if section == .discover && selected == nil { selected = visibleItems.first }
        let count = discoverItems.count
        emptyPageStreak = count > initialCount ? 0 : emptyPageStreak + 1
        searching = false
        if count == 0 {
            loadMore(automatically: true)
            if searching { return }
        }
        if !failures.isEmpty {
            catalogNotice = "\(failures.sorted().joined(separator: "、"))暂时无法访问，可重新加载。"
        } else if count == initialCount {
            catalogNotice = "本页没有匹配的壁纸。可以继续查找或换一个关键词。"
        }
    }

    private func discoveryScore(_ item: Wallpaper, screens: [PixelSize]) -> Double {
        guard let size = originalSize(for: item) ?? item.advertisedSize else { return WallpaperRequirements.maximumCrop }
        return screens.map { screen in
            let upscale = max(0, placement.scale(from: size, to: screen) - 1)
            return upscale + (placement == .fill ? size.cropFraction(for: screen.aspect) : 0)
        }.max() ?? 0
    }

    func toggleFavorite(_ item: Wallpaper) {
        var entry = index.entries[item.id] ?? LibraryEntry(wallpaper: item)
        entry.wallpaper = item
        entry.favorite.toggle()
        if entry.savedAt == nil { entry.savedAt = Date() }
        var next = index
        if !entry.favorite && entry.image == nil { next.entries.removeValue(forKey: item.id) }
        else { next.entries[item.id] = entry }
        _ = commit(next)
    }

    func importFiles(_ urls: [URL]) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        var added: [(Wallpaper, StoredImage)] = []
        var failures: [String] = []
        for url in urls {
            do {
                let image = try await vault.importFile(url)
                let id = "local:\(image.original.deletingPathExtension().lastPathComponent)"
                let item = index.entries[id]?.wallpaper ?? Wallpaper(
                    id: id, title: url.deletingPathExtension().lastPathComponent,
                    source: .local, detail: nil
                )
                added.append((item, image))
            } catch {
                failures.append("\(url.lastPathComponent)：\(error.localizedDescription)")
            }
        }
        var next = index
        for (item, image) in added {
            var entry = next.entries[item.id] ?? LibraryEntry(wallpaper: item)
            entry.image = image
            entry.savedAt = Date()
            next.entries[item.id] = entry
        }
        if let first = added.first, commit(next) {
            section = .library
            favoritesOnly = false
            localQuery = ""
            selected = first.0
        }
        if let first = failures.first {
            status = failures.count == 1 ? first : "\(failures.count) 张图片无法导入。\(first)"
        }
    }

    func saveOffline(_ item: Wallpaper) async {
        guard !busy, localImage(for: item) == nil else { return }
        busy = true
        defer { busy = false }
        do {
            let image = try await downloadedImage(for: item, requirements: WallpaperRequirements(preferredScreen: previewDisplay?.pixels))
            if record(image, for: item) { status = "已保存到我的图库" }
        } catch is CancellationError {
            status = "已取消下载"
        } catch {
            status = error.localizedDescription
        }
    }

    var selectedDisplayIDs: [String] {
        if targetDisplay == Self.allDisplays { return displays.map(\.id) }
        return targetDisplay.map { [$0] } ?? []
    }

    func apply(_ item: Wallpaper, to ids: [String], placement: Placement, animated: Bool = false) async {
        guard !busy, !ids.isEmpty else { return }
        let enhance = enhancesWallpaper
        liveWallpaper.dismissMessage()
        busy = true
        retry = nil
        defer { busy = false }
        do {
            let image = try await downloadedImage(for: item, requirements: imageRequirements(for: ids, placement: placement))
            if enhance { status = "正在本机增强壁纸画质…" }
            let file = enhance ? try await vault.enhancedDesktop(for: image.desktop) : image.desktop
            let backdrop = placement == .fit ? try await vault.preview(at: file, maxPixel: 96).backdrop : .black
            guard record(image, for: item) else { return }
            await applyStored(item, image: image, file: file, ids: ids, placement: placement, backdrop: backdrop,
                              animated: animated, keepUndo: false)
        } catch is CancellationError {
            status = "已取消下载，桌面壁纸没有变化"
        } catch {
            status = error.localizedDescription
        }
    }

    func retryFailedDisplays() async {
        guard !busy, let retry else { return }
        busy = true
        defer { busy = false }
        await applyStored(
            retry.item, image: retry.image, file: retry.file, ids: retry.ids, placement: retry.placement, backdrop: retry.backdrop,
            animated: retry.animated, keepUndo: retry.keepUndo
        )
    }

    func nextOffline() async {
        guard let primary = displays.first else { return }
        let requirements = imageRequirements(for: [primary.id])
        var seen = Set<URL>()
        let items = downloaded.filter {
            guard let image = $0.image, requirements.issue(for: image.size) == nil else { return false }
            return seen.insert(image.desktop.standardizedFileURL).inserted
        }
        guard !items.isEmpty else { status = "图库里没有符合当前画质和屏幕比例的壁纸。"; return }
        let current = items.firstIndex { matchesDesktop($0.image, file: currentFile) }
        if current != nil && items.count == 1 {
            status = "图库里只有当前这张壁纸。"
            return
        }
        let next = current.map { items[($0 + 1) % items.count] } ?? items[0]
        await apply(next.wallpaper, to: [primary.id], placement: placement)
    }

    func undo() async {
        guard !busy, canUndo else { return }
        busy = true
        defer { busy = false }
        retry = nil
        let result = await desktop.restore(index.undo)
        let restoredIDs = index.undo.map(\.displayID).filter { result.errors[$0] == nil }
        liveWallpaper.stop(on: restoredIDs)
        let primary = displays.first?.id
        let restoredPrimary = index.undo.first { $0.displayID == primary && result.errors[$0.displayID] == nil }
        var next = index
        next.undo.removeAll { result.errors[$0.displayID] == nil }
        refreshDisplays()
        if let restoredPrimary { currentFile = restoredPrimary.file }
        if commit(next) {
            status = changeMessage(result, completed: "已撤销换图")
        }
    }

    private func downloadedImage(for item: Wallpaper, requirements: WallpaperRequirements) async throws -> StoredImage {
        if let image = localImage(for: item) {
            try await vault.validateLocal(image, requirements: requirements)
            return image
        }
        if item.source == .local { throw WallpaperError.missingUHD }
        let destination = customDownloadFolder
        let cached = fullPreview?.id == item.id ? fullPreview?.original : nil
        let task = Task { [catalog, vault] in
            do {
                let original: VerifiedOriginal
                if let cached, requirements.issue(for: cached.size) == nil {
                    original = cached
                } else {
                    let urls = try await catalog.originalURLs(for: item, requirements: requirements)
                    original = try await vault.verifyOriginal(urls, requirements: requirements)
                }
                return try await vault.save(original, requirements: requirements, destination: destination, title: item.title)
            } catch {
                try Task.checkCancellation()
                throw error
            }
        }
        downloadTask = task
        defer { downloadTask = nil }
        return try await task.value
    }

    func cancelDownload() { downloadTask?.cancel() }

    func stopLiveWallpaper() {
        liveWallpaper.stopAll()
        status = "已恢复静态壁纸"
    }

    func dismissStatus() {
        liveWallpaper.dismissMessage()
        status = nil
    }

    private func record(_ image: StoredImage, for item: Wallpaper) -> Bool {
        var entry = index.entries[item.id] ?? LibraryEntry(wallpaper: item)
        entry.wallpaper = item
        entry.image = image
        if entry.savedAt == nil { entry.savedAt = Date() }
        var next = index
        next.entries[item.id] = entry
        return commit(next)
    }

    private func applyStored(
        _ item: Wallpaper, image: StoredImage, file: URL, ids: [String], placement: Placement, backdrop: DesktopBackdrop,
        animated: Bool, keepUndo: Bool
    ) async {
        let validIDs = ids.filter { imageRequirements(for: [$0], placement: placement).issue(for: image.size) == nil }
        var result = await desktop.apply(file, to: validIDs, placement: placement, backdrop: backdrop)
        for id in ids where !validIDs.contains(id) {
            result.errors[id] = WallpaperError.mismatchedAspect(image.size).localizedDescription
        }
        let failedIDs = ids.filter { result.errors[$0] != nil }
        retry = failedIDs.isEmpty ? nil :
            (item, image, file, failedIDs, placement, backdrop, animated, keepUndo || result.successful > 0)
        refreshDisplays()
        if let primary = displays.first?.id, validIDs.contains(primary), result.errors[primary] == nil {
            currentFile = file
        }
        if result.successful > 0 {
            let succeeded = validIDs.filter { result.errors[$0] == nil }
            if !animated { liveWallpaper.stop(on: succeeded) }
            var next = index
            next.undo = (keepUndo ? next.undo : []) + result.previous
            next.entries[item.id]?.usedAt = Date()
            guard commit(next) else { return }
            if animated { liveWallpaper.play(file, on: succeeded, placement: placement, backdrop: backdrop) }
        }
        let completed = file == image.desktop ? "已设为桌面壁纸" : "已设为增强壁纸"
        status = changeMessage(result, completed: completed)
    }

    private func changeMessage(_ result: DesktopChange, completed: String) -> String {
        guard !result.errors.isEmpty else { return completed }
        let details = result.errors.sorted { $0.key < $1.key }.map { id, message in
            "\(displays.first { $0.id == id }?.name ?? "目标显示器")：\(message)"
        }.joined(separator: "  ")
        return result.successful > 0 ? "\(result.successful) 个屏幕已完成。\(details)" : details
    }

    private func commit(_ next: LibraryIndex) -> Bool {
        if let storageError {
            status = storageError
            return false
        }
        do {
            try storage.save(next)
            index = next
            return true
        } catch {
            status = "无法保存图库。\(error.localizedDescription)"
            return false
        }
    }
}
