import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct WallView: View {
    @Bindable var model: WallModel
    @Binding var showingImporter: Bool
    @State private var showingPreview = false
    @State private var dropTarget = false
    @State private var hoveredSidebarRow: String?
    @State private var hoveredControl: String?
    @State private var nearViewportItems = Set<String>()
    @State private var windowDisplayID: String?
    @State private var wallpaperColor: DesktopBackdrop?
    @AppStorage(WallAppearance.followsWallpaper) private var followsWallpaper = true
    @AppStorage("showsLibrarySidebar") private var showsSidebar = true
    @AppStorage("showsDesktopPreview") private var showsInspector = true
    @AppStorage("librarySidebarWidth") private var sidebarWidth = 214.0
    @AppStorage("galleryListWidth") private var galleryWidth = 373.0
    @FocusState private var searchFocused: Bool
    @FocusState private var gridFocused: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    private var palette: WallPalette {
        WallPalette(wallpaper: followsWallpaper && contrast != .increased ? wallpaperColor : nil)
    }

    private var shellOpacity: Double {
        reduceTransparency || contrast == .increased || !followsWallpaper ? 1 : 0.64
    }

    private let topics = ["全部", "人物写真", "人物插画", "国风", "自然风光", "城市夜景", "极简"]
    private let railWidth = 64.0
    private let columns = [GridItem(.adaptive(minimum: 162, maximum: 360), spacing: 13, alignment: .top)]

    var body: some View {
        GeometryReader { frame in
            let navMax = max(178, min(290, frame.size.width - (showsInspector ? 668 : 370)))
            let nav = showsSidebar ? min(navMax, max(178, sidebarWidth)) : railWidth
            let listMax = max(300, frame.size.width - nav - 364)
            let list = min(listMax, max(300, galleryWidth))
            HStack(spacing: 0) {
                sidebar.frame(width: nav, alignment: .leading).clipped()
                WallPaneDivider(width: nav, backgroundOpacity: shellOpacity) {
                    sidebarWidth = min(navMax, max(178, $0))
                }
                .allowsHitTesting(showsSidebar)
                workspace.frame(width: showsInspector ? list : nil)
                if showsInspector {
                    WallPaneDivider(width: list, backgroundOpacity: shellOpacity) { galleryWidth = min(listMax, max(300, $0)) }
                    inspector.frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.24), value: showsSidebar)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.24), value: showsInspector)
        }
        .ignoresSafeArea(.container, edges: .top)
        .background { windowBackground }
        .background {
            WallScreenObserver { windowDisplayID = $0 }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .environment(\.wallPalette, palette)
        .tint(palette.accent)
        .task { model.start() }
        .task(id: TintRequest(displayID: windowDisplayID, followsWallpaper: followsWallpaper)) {
            await followWallpaperColor()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            model.refreshDisplays()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshDisplays()
        }
        .onChange(of: model.targetDisplay) { _, _ in model.previewDisplayChanged() }
        .onChange(of: model.placement) { _, _ in model.previewDisplayChanged() }
        .fileImporter(
            isPresented: $showingImporter, allowedContentTypes: [.jpeg, .png, .heic, .webP, .tiff],
            allowsMultipleSelection: true
        ) { outcome in
            switch outcome {
            case .success(let files): Task { await model.importFiles(files) }
            case .failure(let error): model.status = error.localizedDescription
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty, !model.busy else { return false }
            Task { await model.importFiles(files) }
            return true
        } isTargeted: { dropTarget = $0 }
        .overlay {
            if dropTarget {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(palette.accent, style: StrokeStyle(lineWidth: 2, dash: [7]))
                    .padding(5)
                    .allowsHitTesting(false)
            }
        }
        .sheet(isPresented: $showingPreview) { enlargedPreview }
        .background {
            Button("搜索壁纸") { searchFocused = true }
                .keyboardShortcut("f")
                .hidden()
                .accessibilityHidden(true)
        }
    }

    private var workspace: some View {
        VStack(spacing: 0) {
            header
            gallery
            if model.canCancelDownload {
                statusBar("正在下载壁纸…")
            } else if let status = model.operationStatus {
                statusBar(status)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.canvas.opacity(shellOpacity))
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                if showsSidebar {
                    Spacer()
                    iconButton("隐藏导航栏", icon: "sidebar.left", action: toggleSidebar)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 43)
            .background { WallWindowDragArea() }

            HStack(spacing: 0) {
                VStack(spacing: 6) {
                    ForEach(WallSection.allCases) { section in
                        iconButton(section.rawValue, icon: section.icon, selected: model.section == section) {
                            model.selectSection(section)
                        }
                    }
                    Spacer()
                    SettingsLink {
                        Image(systemName: "gearshape")
                            .font(.system(size: 15))
                            .frame(width: 29, height: 30)
                            .foregroundStyle(palette.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("设置")
                    .help("设置与下载位置")
                }
                .padding(.vertical, 7)
                .frame(width: railWidth)
                Rectangle().fill(palette.line)
                    .frame(width: 1)
                    .padding(.vertical, 8)
                    .opacity(showsSidebar ? 1 : 0)

                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 9) {
                        Image(nsImage: WallpaperWallLifecycle.bundledIcon ?? NSApplication.shared.applicationIconImage)
                            .renderingMode(.original)
                            .resizable()
                            .frame(width: 25, height: 25)
                        Text("macui")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 18)
                    sidebarOptions
                    displaySummary
                }
                .frame(maxWidth: .infinity)
                .opacity(showsSidebar ? 1 : 0)
                .allowsHitTesting(showsSidebar)
                .accessibilityHidden(!showsSidebar)
            }
        }
        .background(palette.sidebar.opacity(shellOpacity))
    }

    private var sidebarOptions: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 3) {
                switch model.section {
                case .discover:
                    sidebarHeading("题材")
                    ForEach(topics, id: \.self) { topic in
                        let term = topic == "全部" ? "" : topic
                        sidebarRow(topic, active: model.query == term) {
                            model.query = term
                            model.search()
                        }
                    }
                    sidebarHeading("图源").padding(.top, 14)
                    sidebarRow(WallpaperSource.featuredName, active: model.source == nil) { model.source = nil }
                    ForEach(WallpaperSource.online, id: \.self) { source in
                        sidebarRow(source.name, active: model.source == source) { model.source = source }
                    }
                case .library:
                    sidebarHeading("图库")
                    sidebarRow("全部图片", active: !model.favoritesOnly) { setFavorites(false) }
                    sidebarRow("收藏", active: model.favoritesOnly) { setFavorites(true) }
                case .recent:
                    sidebarHeading("记录")
                    sidebarRow("最近使用", active: true) { model.selectSection(.recent) }
                }
            }
            .padding(.horizontal, 8)
        }
        .scrollIndicators(.hidden)
    }

    private var displaySummary: some View {
        HStack(spacing: 10) {
            Image(systemName: "display")
                .font(.system(size: 13))
                .foregroundStyle(palette.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                Text("主显示器")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.secondary)
                Text(model.currentName)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .help(model.currentName)
            }
            Spacer(minLength: 4)
            if model.canUndo {
                iconButton("撤销换图", icon: "arrow.uturn.backward") { Task { await model.undo() } }
                    .disabled(model.busy)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }

    private var header: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if !showsSidebar {
                    iconButton("显示导航栏", icon: "sidebar.left", action: toggleSidebar)
                }
                Label(model.section.rawValue, systemImage: model.section.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                if !showsInspector {
                    iconButton("显示预览栏", icon: "sidebar.right", action: toggleInspector)
                }
                if model.section != .recent {
                    browseMenu
                }
                iconButton("导入图片", icon: "plus") { showingImporter = true }
                    .disabled(model.busy)
            }
            .padding(.leading, 13)
            .padding(.trailing, 8)
            .frame(height: 43)
            .background { WallWindowDragArea() }
            palette.line.frame(height: 1)
            if model.section == .discover {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 7) {
                        searchField(model.aiSearchEnabled ? "描述想找的壁纸" : "搜索壁纸", value: $model.query) {
                            model.search()
                            gridFocused = true
                        }
                        Button {
                            model.aiSearchEnabled.toggle()
                            if !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                model.search()
                            } else {
                                searchFocused = true
                            }
                        } label: {
                            Label("AI 搜索", systemImage: "sparkle.magnifyingglass")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(model.aiSearchEnabled ? palette.accent : palette.secondary)
                                .padding(.horizontal, 9)
                                .frame(height: 32)
                                .background(model.aiSearchEnabled ? palette.selection : palette.raised,
                                            in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(model.aiSearchEnabled ? [.isSelected] : [])
                        .help("将壁纸描述发送给配置的模型，转换为图库搜索关键词")
                    }
                    if let notice = model.aiSearchNotice {
                        Text(notice)
                            .font(.caption)
                            .foregroundStyle(palette.secondary)
                            .lineLimit(2)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            } else if model.section == .library {
                searchField("搜索我的图库", value: $model.localQuery) {
                    model.selected = model.visibleItems.first
                    gridFocused = true
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .onChange(of: model.localQuery) { _, _ in
                    model.selected = model.visibleItems.first
                }
            }
        }
        .onChange(of: model.source) { _, _ in model.search() }
    }

    private var browseMenu: some View {
        Menu {
            if model.section == .discover {
                Text("保存和应用时验证 4K 原图")
                Toggle("匹配显示器比例", isOn: Binding(
                    get: { model.matchScreen }, set: { model.changeMatchScreen($0) }
                ))
                Menu("图源") {
                    Picker("图源", selection: $model.source) {
                        Text(WallpaperSource.featuredName).tag(nil as WallpaperSource?)
                        ForEach(WallpaperSource.online, id: \.self) { source in
                            Text(source.name).tag(Optional(source))
                        }
                    }
                    .labelsHidden()
                }
            } else {
                Picker("图库范围", selection: Binding(
                    get: { model.favoritesOnly }, set: { setFavorites($0) }
                )) {
                    Text("全部图片").tag(false)
                    Text("收藏").tag(true)
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 14))
                .foregroundStyle(palette.secondary)
                .frame(width: 24, height: 28)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("筛选")
        .help("筛选")
    }

    private var gallery: some View {
        ScrollViewReader { proxy in
            ScrollView {
                let items = model.visibleItems
                VStack(alignment: .leading, spacing: 14) {
                    if model.section == .discover, let notice = model.catalogNotice {
                        Label(notice, systemImage: "wifi.exclamationmark")
                            .font(.system(size: 12))
                            .foregroundStyle(palette.secondary)
                    }
                    if items.isEmpty {
                        emptyGallery
                    } else if showsInspector {
                        LazyVStack(spacing: 3) {
                            ForEach(items) { item in
                                galleryItem(item, among: items, compact: true)
                            }
                        }
                    } else {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                            ForEach(items) { item in
                                galleryItem(item, among: items, compact: false)
                            }
                        }
                    }
                    if model.section == .discover, !items.isEmpty, model.searching || model.hasMore {
                        HStack {
                            Spacer()
                            if model.searching {
                                ProgressView().controlSize(.small).accessibilityLabel("正在加载")
                            } else {
                                Button(model.catalogNotice == nil ? "加载更多" : "继续加载") { model.loadMore() }
                                    .buttonStyle(.bordered)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 8)
                    }
                }
                .padding(.horizontal, showsInspector ? 8 : 18)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: model.searching) { _, searching in
                if !searching { continueLoading(model.visibleItems) }
            }
            .onDisappear { model.cancelThumbnailPrefetch() }
            .focusable()
            .focusEffectDisabled()
            .focused($gridFocused)
            .onKeyPress(.leftArrow) {
                model.selectRelative(-1)
                if let id = model.selected?.id { proxy.scrollTo(id) }
                return .handled
            }
            .onKeyPress(.rightArrow) {
                model.selectRelative(1)
                if let id = model.selected?.id { proxy.scrollTo(id) }
                return .handled
            }
            .onKeyPress(.upArrow) {
                model.selectRelative(-1)
                if let id = model.selected?.id { proxy.scrollTo(id) }
                return .handled
            }
            .onKeyPress(.downArrow) {
                model.selectRelative(1)
                if let id = model.selected?.id { proxy.scrollTo(id) }
                return .handled
            }
            .onKeyPress(.space) {
                guard model.selected != nil else { return .ignored }
                showingPreview = true
                return .handled
            }
        }
    }

    private func galleryItem(_ item: Wallpaper, among items: [Wallpaper], compact: Bool) -> some View {
        WallTile(item: item, model: model, active: model.selected?.id == item.id, compact: compact) {
            model.selected = item
            gridFocused = true
        } visibilityChanged: { visible in
            if visible {
                nearViewportItems.insert(item.id)
                model.prefetchThumbnails(in: items, after: item, maxPixel: WallTile.thumbnailPixels(compact: compact))
                continueLoading(items)
            } else {
                nearViewportItems.remove(item.id)
            }
        }
        .id(item.id)
    }

    private func continueLoading(_ items: [Wallpaper]) {
        if model.section == .discover, items.suffix(6).contains(where: { nearViewportItems.contains($0.id) }) {
            model.loadMore(automatically: true)
        }
    }

    @ViewBuilder
    private var emptyGallery: some View {
        if model.section == .discover && model.searching {
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("正在加载壁纸…").foregroundStyle(palette.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 220)
        } else if model.section == .discover {
            ContentUnavailableView {
                Label("没有找到符合条件的壁纸", systemImage: "photo")
            } description: {
                Text("试试其他关键词、图源或筛选条件。")
            } actions: {
                if model.hasMore { Button("继续查找") { model.loadMore() } }
            }
            .frame(minHeight: 225)
        } else if model.section == .library {
            ContentUnavailableView {
                Label(model.favoritesOnly ? "暂无收藏" : "没有符合条件的图片", systemImage: "photo.on.rectangle")
            } description: {
                Text("导入电脑里的图片，也可以在macui收藏和下载。")
            } actions: {
                Button("导入图片…") { showingImporter = true }
            }
            .frame(minHeight: 225)
        } else {
            ContentUnavailableView("暂无使用记录", systemImage: "clock", description: Text("应用后的壁纸会出现在这里。"))
                .frame(minHeight: 225)
        }
    }

    private var inspector: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label("桌面预览", systemImage: "display")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(palette.secondary)
                Spacer()
                iconButton("放大预览（空格）", icon: "arrow.up.left.and.arrow.down.right") { showingPreview = true }
                    .disabled(model.selected == nil)
                iconButton("隐藏预览栏", icon: "sidebar.right", action: toggleInspector)
            }
            .padding(.horizontal, 13)
            .frame(height: 43)
            .background { WallWindowDragArea() }
            palette.line.frame(height: 1)
            if let item = model.selected {
                ScrollView {
                    WallInspector(model: model, item: item)
                        .padding(17)
                }
            } else {
                ContentUnavailableView("选择一张壁纸", systemImage: "display")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(palette.inspector.opacity(shellOpacity))
    }

    private var enlargedPreview: some View {
        VStack(spacing: 16) {
            HStack {
                Text(model.selected?.title ?? "桌面预览")
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Toggle("画质增强", isOn: $model.enhancesWallpaper)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(model.busy)
                Button("完成") { showingPreview = false }
                    .keyboardShortcut(.cancelAction)
            }
            if let item = model.selected {
                WallPreview(model: model, item: item, fullSize: true)
                    .frame(maxHeight: .infinity)

                HStack {
                    Button("上一张", systemImage: "chevron.left") { model.selectRelative(-1) }
                        .keyboardShortcut(.leftArrow, modifiers: [])
                    Button("下一张", systemImage: "chevron.right") { model.selectRelative(1) }
                        .keyboardShortcut(.rightArrow, modifiers: [])
                    Spacer()
                    if item.downloadsOnOriginalSite, model.localImage(for: item) == nil, let detail = item.detail {
                        Link(destination: detail) { Label("去原站下载", systemImage: "arrow.up.right") }
                    } else {
                        Button("设为 2.5D 动态壁纸") {
                            Task {
                                await model.apply(item, to: model.selectedDisplayIDs, placement: model.placement, animated: true)
                            }
                            showingPreview = false
                        }
                        .disabled(model.busy || model.selectedDisplayIDs.isEmpty)
                        Button("设为壁纸") {
                            Task { await model.apply(item, to: model.selectedDisplayIDs, placement: model.placement) }
                            showingPreview = false
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(palette.action)
                        .foregroundStyle(.black)
                        .disabled(model.busy || model.selectedDisplayIDs.isEmpty)
                    }
                }
            }
        }
        .padding(22)
        .frame(width: 840, height: 565)
        .background(palette.canvas)
    }

    private func searchField(_ title: String, value: Binding<String>, submit: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(palette.secondary)
            TextField(title, text: value)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onSubmit(submit)
            if !value.wrappedValue.isEmpty {
                Button("清空搜索", systemImage: "xmark.circle.fill") {
                    value.wrappedValue = ""
                    submit()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(palette.secondary)
            }
            if model.section == .discover {
                Button("搜索", systemImage: "return", action: submit)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(palette.secondary)
                    .help("搜索")
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 32)
        .background(palette.raised, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(searchFocused ? palette.accent.opacity(0.45) : palette.line)
        }
    }

    private func toggleSidebar() {
        if reduceMotion {
            showsSidebar.toggle()
        } else {
            withAnimation(.easeInOut(duration: 0.24)) {
                showsSidebar.toggle()
            }
        }
    }

    private func toggleInspector() {
        if reduceMotion {
            showsInspector.toggle()
        } else {
            withAnimation(.easeInOut(duration: 0.24)) {
                showsInspector.toggle()
            }
        }
    }

    private func setFavorites(_ enabled: Bool) {
        model.favoritesOnly = enabled
        model.selected = model.visibleItems.first
    }

    private func sidebarHeading(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(palette.secondary)
            .padding(.horizontal, 9)
            .padding(.bottom, 4)
    }

    private func sidebarRow(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).lineLimit(1)
                .font(.system(size: 12, weight: active ? .medium : .regular))
                .foregroundStyle(active ? palette.accent : palette.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(
                    active ? palette.selection : (hoveredSidebarRow == title ? palette.raised : .clear),
                    in: RoundedRectangle(cornerRadius: 7)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering { hoveredSidebarRow = title }
            else if hoveredSidebarRow == title { hoveredSidebarRow = nil }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: hoveredSidebarRow)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: active)
        .accessibilityAddTraits(active ? [.isSelected] : [])
    }

    private func iconButton(
        _ title: String, icon: String, selected: Bool = false, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(selected ? palette.accent : palette.secondary)
                .frame(width: 29, height: 29)
                .background(
                    selected ? palette.selection : (hoveredControl == title ? palette.raised : .clear),
                    in: RoundedRectangle(cornerRadius: 7)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering { hoveredControl = title }
            else if hoveredControl == title { hoveredControl = nil }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: hoveredControl)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: selected)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .help(title)
    }

    @ViewBuilder
    private var windowBackground: some View {
        if reduceTransparency || contrast == .increased || !followsWallpaper {
            palette.canvas
        } else {
            WallWindowMaterial()
                .overlay(palette.canvas.opacity(wallpaperColor == nil ? 0.25 : 0.91))
        }
    }

    private struct TintRequest: Equatable {
        let displayID: String?
        let followsWallpaper: Bool
    }

    private func followWallpaperColor() async {
        guard followsWallpaper else {
            wallpaperColor = nil
            return
        }
        var lastFile: URL?
        var initialized = false
        while !Task.isCancelled {
            let file = model.desktopFile(on: windowDisplayID)
            if !initialized || file != lastFile {
                let color: DesktopBackdrop?
                if let file, let sample = try? await model.vault.preview(at: file, maxPixel: 72) {
                    color = sample.ambientColor
                } else {
                    color = nil
                }
                guard !Task.isCancelled else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.38)) {
                    wallpaperColor = color
                }
                initialized = true
                lastFile = file
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func statusBar(_ message: String) -> some View {
        HStack(spacing: 10) {
            Text(message)
                .font(.system(size: 12))
                .lineLimit(3)
                .accessibilityIdentifier("操作反馈")
            Spacer(minLength: 4)
            if model.canCancelDownload {
                Button("取消下载") { model.cancelDownload() }
            } else if model.canRetry {
                Button("重试失败的屏幕") { Task { await model.retryFailedDisplays() } }
                    .disabled(model.busy)
            }
            if model.liveWallpaper.isEnabled {
                Button("停止动态壁纸") { model.stopLiveWallpaper() }
                    .disabled(model.busy)
            }
            if !model.canCancelDownload && !model.liveWallpaper.isPreparing {
                Button("关闭提示", systemImage: "xmark") { model.dismissStatus() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 17)
        .padding(.vertical, 10)
        .background(palette.raised)
    }
}
