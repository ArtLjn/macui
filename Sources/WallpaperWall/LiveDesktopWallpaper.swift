import AppKit
import CoreGraphics
import Observation

@MainActor
@Observable
final class LiveDesktopWallpaper: NSObject {
    private(set) var message: String?
    var isEnabled: Bool { !pending.isEmpty || !sessions.isEmpty }
    var isPreparing: Bool { !pending.isEmpty }
    var submittedFrames: Int { sessions.values.reduce(0) { $0 + $1.view.submittedFrames } }

    private struct Session {
        let file: URL
        let panel: LiveDesktopPanel
        let view: DepthWallpaperView
    }

    private let workspace = NSWorkspace.shared
    private let loader: DepthWallpaperLoader
    private var pending: [String: UUID] = [:]
    private var sessions: [String: Session] = [:]
    @ObservationIgnored private var requests: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var monitor: Task<Void, Never>?
    @ObservationIgnored private var graphics: DepthWallpaperGraphics?
    @ObservationIgnored private var sleeping = false
    @ObservationIgnored private var sessionActive = true

    init(loader: DepthWallpaperLoader = DepthWallpaperLoader()) {
        self.loader = loader
        super.init()
        let notifications = workspace.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification,
                     NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification] {
            notifications.addObserver(self, selector: #selector(workspaceChanged(_:)), name: name, object: nil)
        }
    }

    func play(_ image: URL, on ids: [String], placement: Placement, backdrop: DesktopBackdrop) {
        guard !ids.isEmpty else { return }
        stop(on: ids)
        guard !workspace.accessibilityDisplayShouldReduceMotion else {
            message = "系统已开启「减少动态效果」，当前使用静态壁纸。"
            return
        }
        let token = UUID()
        for id in ids { pending[id] = token }
        message = "正在本机分析壁纸景深…"
        requests[token] = Task { [weak self, loader] in
            do {
                let asset = try await loader.load(image, backdrop: backdrop)
                try Task.checkCancellation()
                self?.install(asset, file: image, token: token, placement: placement, backdrop: backdrop)
            } catch is CancellationError {
                return
            } catch {
                self?.finish(token, message: (error as? DepthWallpaperError)?.localizedDescription
                             ?? DepthWallpaperError.depthUnavailable.localizedDescription)
            }
        }
    }

    func stop(on ids: [String]) {
        let tokens = Set(ids.compactMap { pending.removeValue(forKey: $0) })
        for token in tokens where !pending.values.contains(token) {
            requests.removeValue(forKey: token)?.cancel()
        }
        for id in ids {
            guard let session = sessions.removeValue(forKey: id) else { continue }
            session.view.setRunning(false)
            session.panel.orderOut(nil)
        }
        if sessions.isEmpty {
            monitor?.cancel()
            monitor = nil
            graphics = nil
        }
        if pending.isEmpty { message = nil }
    }

    func stopAll() {
        stop(on: Array(Set(pending.keys).union(sessions.keys)))
        message = nil
    }

    func dismissMessage() {
        if pending.isEmpty { message = nil }
    }

    private func finish(_ token: UUID, message: String) {
        guard requests.removeValue(forKey: token) != nil else { return }
        pending = pending.filter { $0.value != token }
        if pending.isEmpty { self.message = message }
    }

    private func install(_ asset: DepthWallpaperAsset, file: URL, token: UUID, placement: Placement,
                         backdrop: DesktopBackdrop) {
        let targets = pending.filter { $0.value == token }.map(\.key)
        guard !targets.isEmpty else { return }
        do {
            let graphics = try self.graphics ?? DepthWallpaperGraphics()
            self.graphics = graphics
            let textures = try graphics.textures(for: asset)
            var installed = 0
            for screen in NSScreen.screens {
                let id = DesktopService.id(for: screen)
                guard targets.contains(id) else { continue }
                let view = DepthWallpaperView(graphics: graphics, textures: textures, placement: placement, backdrop: backdrop)
                let panel = LiveDesktopPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                             backing: .buffered, defer: false, screen: screen)
                panel.setFrame(screen.frame, display: false)
                panel.level = .liveWallpaper
                panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
                panel.ignoresMouseEvents = true
                panel.hidesOnDeactivate = false
                panel.animationBehavior = .none
                panel.hasShadow = false
                panel.contentView = view
                sessions[id] = Session(file: file.standardizedFileURL, panel: panel, view: view)
                installed += 1
            }
            let note = switch installed {
            case 0: "目标显示器已断开，已保留静态壁纸。"
            case targets.count: "已开启 2.5D 动态壁纸"
            default: "\(installed) 个屏幕已开启 2.5D，其他屏幕使用静态壁纸。"
            }
            finish(token, message: note)
            refresh()
            if !sessions.isEmpty, monitor == nil {
                monitor = Task { @MainActor [weak self] in
                    while !Task.isCancelled, self != nil {
                        try? await Task.sleep(for: .seconds(1))
                        if !Task.isCancelled { self?.refresh() }
                    }
                }
            }
        } catch {
            finish(token, message: DepthWallpaperError.rendererUnavailable.localizedDescription)
        }
    }

    @objc private func workspaceChanged(_ notification: Notification) {
        switch notification.name {
        case NSWorkspace.screensDidSleepNotification: sleeping = true
        case NSWorkspace.screensDidWakeNotification: sleeping = false
        case NSWorkspace.sessionDidResignActiveNotification: sessionActive = false
        case NSWorkspace.sessionDidBecomeActiveNotification: sessionActive = true
        case NSWorkspace.activeSpaceDidChangeNotification:
            for session in sessions.values {
                session.view.setRunning(false)
                session.panel.orderOut(nil)
            }
            return
        default: break
        }
        refresh()
    }

    private func refresh() {
        guard !sessions.isEmpty else { return }
        let permitted = !sleeping && sessionActive && !workspace.accessibilityDisplayShouldReduceMotion
        let screens = Dictionary(uniqueKeysWithValues: NSScreen.screens.map { (DesktopService.id(for: $0), $0) })
        for (id, session) in sessions {
            guard permitted, let screen = screens[id],
                  workspace.desktopImageURL(for: screen)?.standardizedFileURL == session.file else {
                session.view.setRunning(false)
                session.panel.orderOut(nil)
                continue
            }
            if session.panel.frame != screen.frame { session.panel.setFrame(screen.frame, display: true) }
            if !session.panel.isVisible {
                session.panel.orderFrontRegardless()
                session.view.setRunning(true)
            } else {
                session.view.setRunning(session.panel.occlusionState.contains(.visible))
            }
        }
    }

    private final class LiveDesktopPanel: NSPanel {
        override var canBecomeMain: Bool { false }
        override var canBecomeKey: Bool { false }
    }
}

extension NSWindow.Level {
    static let liveWallpaper = Self(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
    static let wallpaperTransition = Self(rawValue: liveWallpaper.rawValue + 1)
}
