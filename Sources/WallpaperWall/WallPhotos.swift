import SwiftUI

struct WallTile: View {
    @Environment(\.wallPalette) private var palette
    let item: Wallpaper

    let model: WallModel
    let active: Bool
    let compact: Bool
    let select: () -> Void
    let visibilityChanged: (Bool) -> Void
    @State private var image: ImagePreview?
    @State private var loadedURL: URL?
    @State private var failed = false
    @State private var hovering = false
    @State private var nearViewport = false

    static func thumbnailPixels(compact: Bool) -> Int { compact ? 260 : 640 }

    var body: some View {
        Group {
            if compact {
                HStack(spacing: 4) {
                    selectionButton {
                        HStack(spacing: 10) {
                            thumbnail.frame(width: 102, height: 58)
                            caption
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    favoriteButton
                }
                .padding(6)
                .background(active ? palette.selection : (hovering ? palette.raised : .clear),
                            in: RoundedRectangle(cornerRadius: 8))
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    selectionButton {
                        thumbnail
                            .aspectRatio(16.0 / 10.0, contentMode: .fit)
                            .overlay {
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(active ? palette.accent : palette.line)
                            }
                    }
                    HStack(alignment: .top, spacing: 6) {
                        caption
                        Spacer(minLength: 2)
                        favoriteButton
                    }
                }
            }
        }
        .onHover { hovering = $0 }
        .onGeometryChange(for: Bool.self) { proxy in
            let frame = proxy.frame(in: .scrollView)
            guard let viewport = proxy.bounds(of: .scrollView), viewport.height > 0 else { return false }
            return frame.maxY >= -100 && frame.minY <= viewport.height + 160
        } action: { visible in
            nearViewport = visible
            visibilityChanged(visible)
        }
        .onDisappear {
            nearViewport = false
            visibilityChanged(false)
        }
        .task(id: nearViewport ? model.thumbnailURL(for: item) : nil) {
            guard nearViewport else { return }
            guard let thumbnailURL = model.thumbnailURL(for: item) else { failed = true; return }
            guard thumbnailURL != loadedURL else { return }
            image = nil
            loadedURL = nil
            failed = false
            do {
                let thumbnail = try await model.vault.preview(at: thumbnailURL, maxPixel: Self.thumbnailPixels(compact: compact))
                guard !Task.isCancelled else { return }
                image = thumbnail
                loadedURL = thumbnailURL
            } catch {
                guard !Task.isCancelled else { return }
                failed = true
            }
        }
    }

    private func selectionButton<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        Button(action: select, label: content)
            .buttonStyle(.plain)
            .accessibilityLabel(item.title)
            .accessibilityAddTraits(active ? [.isSelected] : [])
            .help(item.title)
    }

    private var thumbnail: some View {
        GeometryReader { proxy in
            picture
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.title)
                .font(.system(size: 12, weight: active ? .semibold : .medium))
                .lineLimit(compact ? 2 : 1)
            Text(captionDetails)
                .font(.system(size: 10))
                .foregroundStyle(palette.secondary)
                .lineLimit(1)
        }
    }

    private var captionDetails: String {
        if let size = model.originalSize(for: item) { return "\(item.source.name) · \(size.label)" }
        if let size = item.advertisedSize { return "\(item.source.name) · \(size.label)（标注）" }
        return item.source.name
    }

    private var favoriteButton: some View {
        let favorite = model.entry(for: item)?.favorite == true
        let title = favorite ? "取消收藏" : "收藏"
        return Button(title, systemImage: favorite ? "heart.fill" : "heart") {
            model.toggleFavorite(item)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .font(.system(size: 12))
        .foregroundStyle(favorite ? palette.accent : palette.secondary)
        .opacity(favorite || hovering || active ? 1 : 0.58)
        .help(title)
    }

    @ViewBuilder
    private var picture: some View {
        if let image {
            Image(decorative: image.image, scale: 1)
                .resizable()
                .scaledToFill()
        } else {
            palette.raised
                .overlay {
                    Image(systemName: failed ? "photo.badge.exclamationmark" : "photo")
                        .font(.system(size: 22, weight: .ultraLight))
                        .foregroundStyle(palette.secondary.opacity(0.7))
                }
        }
    }
}

struct WallInspector: View {
    @Environment(\.wallPalette) private var palette
    @Bindable var model: WallModel
    let item: Wallpaper

    private var requiresOriginalSite: Bool {
        item.downloadsOnOriginalSite && model.localImage(for: item) == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            WallPreview(model: model, item: item, fullSize: false)

            VStack(alignment: .leading, spacing: 7) {
                Text(item.title)
                    .font(.system(size: 16, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(credits)
                    .font(.system(size: 12))
                    .foregroundStyle(palette.secondary)
                if let fitNote {
                    Text(fitNote).font(.system(size: 11)).foregroundStyle(palette.secondary)
                }
                Toggle("画质增强", isOn: $model.enhancesWallpaper)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help("轻度降噪和亮度锐化，切换可对比原图")
                    .disabled(model.busy)
            }

            palette.line.frame(height: 1)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    displayControls
                    Spacer(minLength: 6)
                    wallpaperButtons
                }
                VStack(alignment: .leading, spacing: 10) {
                    displayControls
                    wallpaperButtons
                }
            }
            HStack(spacing: 10) {
                let favorite = model.entry(for: item)?.favorite == true
                Button(favorite ? "已收藏" : "收藏", systemImage: favorite ? "heart.fill" : "heart") {
                    model.toggleFavorite(item)
                }
                if model.localImage(for: item) != nil {
                    Label("已保存", systemImage: "checkmark")
                        .foregroundStyle(palette.secondary)
                } else if !requiresOriginalSite {
                    Button("保存离线", systemImage: "arrow.down.to.line") {
                        Task { await model.saveOffline(item) }
                    }
                    .disabled(model.busy || item.source == .local)
                }
                Spacer(minLength: 0)
                if !requiresOriginalSite, let url = item.detail {
                    Link(destination: url) { Label("原站", systemImage: "arrow.up.right") }
                }
            }
            .font(.system(size: 11))
            .buttonStyle(.borderless)
            .foregroundStyle(palette.secondary)
        }
        .id(item.id)
    }

    @ViewBuilder
    private var wallpaperButtons: some View {
        if requiresOriginalSite, let detail = item.detail {
            Link(destination: detail) { Label("去原站下载", systemImage: "arrow.up.right") }
                .buttonStyle(.bordered)
                .help("下载原图后用「导入图片」添加到图库")
        } else {
            HStack(spacing: 8) {
                Button("设为 2.5D 动态壁纸", systemImage: "photo.stack") {
                    Task {
                        await model.apply(item, to: model.selectedDisplayIDs, placement: model.placement, animated: true)
                    }
                }
                .font(.system(size: 12))
                .buttonStyle(.bordered)
                .fixedSize()
                .disabled(model.busy || model.selectedDisplayIDs.isEmpty)
                applyButton
            }
        }
    }

    private var displayControls: some View {
        HStack(spacing: 11) {
            Picker("显示器", selection: $model.targetDisplay) {
                if model.displays.isEmpty { Text("无可用显示器").tag(nil as String?) }
                ForEach(model.displays) { screen in
                    Text("\(screen.name) · \(screen.pixels.label)").tag(Optional(screen.id))
                }
                if model.displays.count > 1 {
                    Text("所有显示器").tag(Optional(WallModel.allDisplays))
                }
            }
            .labelsHidden()
            Picker("显示方式", selection: $model.placement) {
                ForEach(Placement.allCases) { placement in
                    Text(placement.rawValue).tag(placement)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .controlSize(.small)
        .fixedSize()
    }

    private var applyButton: some View {
        Button {
            Task { await model.apply(item, to: model.selectedDisplayIDs, placement: model.placement) }
        } label: {
            Label(model.busy ? "处理中…" : "设为壁纸", systemImage: "display")
                .font(.system(size: 12, weight: .medium))
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .fixedSize()
        .disabled(model.busy || model.selectedDisplayIDs.isEmpty)
    }

    private var credits: String {
        var parts = [item.source.name]
        if let author = item.author, !author.isEmpty { parts.append(author) }
        if let license = item.license { parts.append(license) }
        if let size = model.originalSize(for: item) {
            parts.append("原图 \(size.label)")
        } else if let size = item.advertisedSize {
            parts.append("图源标注 \(size.label)")
        } else {
            parts.append("原图尺寸待验证")
        }
        return parts.joined(separator: "  ·  ")
    }

    private var fitNote: String? {
        guard let screen = model.previewDisplay else { return nil }
        guard let size = model.originalSize(for: item) ?? item.advertisedSize else { return nil }
        let crop = Int((size.cropFraction(for: screen.pixels.aspect) * 100).rounded())
        let targets = model.displays.filter { model.selectedDisplayIDs.contains($0.id) }
        let upscale = targets.map { model.placement.scale(from: size, to: $0.pixels) }.max() ?? 1
        let composition = switch (model.placement, crop) {
        case (_, 0): "与预览屏幕比例一致"
        case (.fill, _): "填满预览屏幕约裁切 \(crop)%"
        case (.fit, _): "保留全图，留边按图片配色"
        }
        if upscale > 1.01 {
            return "\(composition) · \(targets.count > 1 ? "部分显示器" : "该显示器")需放大约 \(Int(upscale * 100 - 100))%"
        }
        return composition
    }
}

struct WallPreview: View {
    @Environment(\.wallPalette) private var palette
    let model: WallModel
    let item: Wallpaper
    let fullSize: Bool
    @State private var image: ImagePreview?
    @State private var backdrop = DesktopBackdrop.black
    @State private var loading = true
    @State private var showingOriginal = false
    @State private var showingEnhancement = false
    @State private var previewItemID: String?
    @Environment(\.displayScale) private var displayScale

    private var localFile: URL? {
        model.localImage(for: item)?.desktop ?? (fullSize ? nil : model.verifiedPreviewFile(for: item))
    }

    private struct Request: Hashable {
        let id: String
        let local: URL?
        let pixels: Int
        let enhanced: Bool
    }

    var body: some View {
        let aspect = model.previewDisplay?.pixels.aspect ?? 1.6
        let request = Request(id: item.id, local: localFile, pixels: Int((fullSize ? 1024 : 640) * displayScale),
                              enhanced: model.enhancesWallpaper)
        Group {
            if fullSize {
                GeometryReader { proxy in
                    let width = min(proxy.size.width, proxy.size.height * aspect)
                    screen.frame(width: width, height: width / aspect)
                        .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                }
            } else {
                screen.aspectRatio(aspect, contentMode: .fit)
            }
        }
        .accessibilityLabel("按显示器比例预览壁纸")
        .task(id: request) { await load(request) }
    }

    private var screen: some View {
        GeometryReader { proxy in
            ZStack {
                model.placement == .fit ? Color(nsColor: backdrop.color) : Color.black
                if let image {
                    Image(decorative: image.image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: model.placement == .fill ? .fill : .fit)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                        .overlay(alignment: .bottomLeading) {
                            if showingEnhancement || !showingOriginal {
                                Text(showingEnhancement ? "增强预览" : "在线预览")
                                    .font(.caption2)
                                    .padding(.horizontal, 7).padding(.vertical, 4)
                                    .background(.black.opacity(0.75), in: Capsule())
                                    .foregroundStyle(.white)
                                    .padding(8)
                            }
                        }
                } else if !loading {
                    Label("预览暂不可用", systemImage: "photo")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.secondary)
                }
                if loading {
                    ProgressView()
                        .controlSize(.small)
                        .padding(8)
                        .background(.black.opacity(0.6), in: Circle())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(8)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(palette.line, lineWidth: 2) }
    }

    private func load(_ request: Request) async {
        if previewItemID != request.id {
            image = nil
            backdrop = .black
            showingOriginal = false
            showingEnhancement = false
            previewItemID = request.id
        }
        loading = true
        if let local = request.local {
            if let preview = try? await model.vault.preview(at: local, maxPixel: request.pixels, enhanced: request.enhanced),
               !Task.isCancelled {
                show(preview, original: true, enhanced: request.enhanced)
            }
        } else {
            let urls = [item.preview, item.thumbnail].compactMap { $0 }
            for (index, url) in urls.enumerated() where index == 0 || url != urls[0] {
                guard !Task.isCancelled else { return }
                if let preview = try? await model.vault.preview(at: url, maxPixel: request.pixels, enhanced: request.enhanced),
                   !Task.isCancelled {
                    show(preview, original: false, enhanced: request.enhanced)
                    break
                }
            }
            if item.downloadsOnOriginalSite, !Task.isCancelled {
                if let detail = try? await model.catalog.detailPreviewURL(for: item), !urls.contains(detail),
                   let preview = try? await model.vault.preview(at: detail, maxPixel: request.pixels, enhanced: request.enhanced),
                   !Task.isCancelled,
                   image == nil || max(preview.image.width, preview.image.height) > max(image?.image.width ?? 0, image?.image.height ?? 0) {
                    show(preview, original: false, enhanced: request.enhanced)
                }
            } else if fullSize, !Task.isCancelled,
               let preview = try? await model.fullPreviewImage(for: item, maxPixel: request.pixels, enhanced: request.enhanced),
               !Task.isCancelled {
                show(preview, original: true, enhanced: request.enhanced)
            }
        }
        if !Task.isCancelled { loading = false }
    }

    private func show(_ preview: ImagePreview, original: Bool, enhanced: Bool) {
        image = preview
        backdrop = preview.backdrop
        showingOriginal = original
        showingEnhancement = enhanced
    }
}
