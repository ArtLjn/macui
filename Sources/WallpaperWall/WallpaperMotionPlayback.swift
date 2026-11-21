import AppKit
import Observation

@MainActor
@Observable
final class WallpaperMotionPlayback {
    private static let preference = "continueDesktopMotionAfterQuit"
    private let local = LiveDesktopWallpaper()
    private let background: BackgroundWallpaperClient?

    private(set) var continuesAfterQuit: Bool
    var supportsBackground: Bool { background != nil }
    var isEnabled: Bool { local.isEnabled || background?.isEnabled == true }
    var isPreparing: Bool { local.isPreparing || background?.isPreparing == true }
    var message: String? { background?.message ?? local.message }
    var isBackgroundPlaying: Bool { background?.isEnabled == true }
    var canResumeBackground: Bool { continuesAfterQuit && background?.canResume == true }
    var backgroundStatus: String {
        if background?.isPreparing == true { return "正在启动后台播放…" }
        if isBackgroundPlaying { return "后台播放已开启" }
        return "后台播放已停止"
    }

    init(root: URL) {
        let helper = Bundle.main.bundleURL.appending(path: "Contents/Helpers/\(BackgroundWallpaperProcess.bundleName)",
                                                     directoryHint: .isDirectory)
        if FileManager.default.isExecutableFile(atPath: helper.appending(path: "Contents/MacOS/WallpaperWall").path) {
            background = BackgroundWallpaperClient(helper: helper, root: root.appending(path: "Playback", directoryHint: .isDirectory))
            continuesAfterQuit = UserDefaults.standard.object(forKey: Self.preference) as? Bool ?? true
        } else {
            background = nil
            continuesAfterQuit = false
        }
    }

    func setContinuesAfterQuit(_ enabled: Bool) {
        guard let background else { return }
        if !enabled, !background.stopAll() { return }
        continuesAfterQuit = enabled
        UserDefaults.standard.set(enabled, forKey: Self.preference)
    }

    func resumeBackground() {
        guard continuesAfterQuit, let background else { return }
        if background.resume() { local.stopAll() }
    }

    func play(_ image: URL, on ids: [String], placement: Placement, backdrop: DesktopBackdrop) {
        if continuesAfterQuit, let background {
            local.stop(on: ids)
            background.play(image, on: ids, placement: placement, backdrop: backdrop)
        } else {
            background?.dismissMessage()
            local.play(image, on: ids, placement: placement, backdrop: backdrop)
        }
    }

    func stop(on ids: [String]) {
        local.stop(on: ids)
        background?.stop(on: ids)
    }

    func stopAll() {
        local.stopAll()
        background?.stopAll()
    }

    func dismissMessage() {
        local.dismissMessage()
        background?.dismissMessage()
    }
}

@MainActor
@Observable
final class BackgroundWallpaperClient {
    private let helper: URL
    private let store: BackgroundWallpaperStore
    private var plan: BackgroundWallpaperPlan?
    @ObservationIgnored private var observer: Task<Void, Never>?
    @ObservationIgnored private var launch: Task<Void, Never>?
    @ObservationIgnored private var seenReport: BackgroundWallpaperReport?
    @ObservationIgnored private var launchedProcess: NSRunningApplication?
    @ObservationIgnored private var shouldRetryLaunch = false
    private(set) var message: String?
    private(set) var isEnabled = false
    private(set) var isPreparing = false
    var canResume: Bool { !isEnabled && plan?.targets.isEmpty == false }

    init(helper: URL, root: URL) {
        self.helper = helper
        store = BackgroundWallpaperStore(root: root)
        plan = store.plan
        refresh()
        if isEnabled { observe() }
    }

    func play(_ image: URL, on ids: [String], placement: Placement, backdrop: DesktopBackdrop) {
        guard !ids.isEmpty else { return }
        var targets = plan?.activeTargets ?? [:]
        let target = BackgroundWallpaperTarget(file: image.standardizedFileURL, placement: placement,
                                               backdrop: backdrop, request: UUID())
        for id in ids { targets[id] = target }
        if publish(targets, playing: true) { start() }
    }

    func stop(on ids: [String]) {
        guard let plan else { return }
        let targets = plan.targets.filter { !ids.contains($0.key) }
        guard targets.count != plan.targets.count else { return }
        _ = publish(targets, playing: isEnabled && !targets.isEmpty)
    }

    @discardableResult
    func stopAll() -> Bool {
        guard let plan, plan.playing else { message = nil; return true }
        return publish(plan.targets, playing: false)
    }

    @discardableResult
    func resume() -> Bool {
        guard !isEnabled, let plan else { return false }
        let currentScreens = NSScreen.screens
        let targets = plan.targets.filter { id, target in
            guard let screen = currentScreens.first(where: { DesktopService.id(for: $0) == id }) else { return false }
            return NSWorkspace.shared.desktopImageURL(for: screen)?.standardizedFileURL == target.file
        }
        guard !targets.isEmpty else {
            message = "当前桌面已换图，请从预览重新设置 2.5D 壁纸。"
            return false
        }
        guard publish(targets, playing: true) else { return false }
        start()
        return true
    }

    func dismissMessage() { if !isPreparing { message = nil } }

    @discardableResult
    private func publish(_ targets: [String: BackgroundWallpaperTarget], playing: Bool) -> Bool {
        let next = BackgroundWallpaperPlan(revision: UUID(), targets: targets, playing: playing)
        do {
            try store.write(next)
            plan = next
            isEnabled = playing
            isPreparing = playing
            message = playing ? "正在启动后台壁纸播放器…" : nil
            seenReport = nil
            shouldRetryLaunch = playing
            if !playing {
                observer?.cancel()
                observer = nil
            }
            return true
        } catch {
            message = "无法更新后台壁纸配置。\(error.localizedDescription)"
            return false
        }
    }

    private func start() {
        observe()
        guard launch == nil else { return }
        launch = Task { [weak self] in
            guard let self else { return }
            defer { launch = nil }
            let options = NSWorkspace.OpenConfiguration()
            options.activates = false
            options.addsToRecentItems = false
            options.allowsRunningApplicationSubstitution = false
            options.arguments = [BackgroundWallpaperProcess.rootArgument, store.root.path]
            do {
                launchedProcess = try await NSWorkspace.shared.openApplication(at: helper, configuration: options)
            } catch {
                if plan?.playing == true {
                    isEnabled = false
                    isPreparing = false
                    shouldRetryLaunch = false
                    message = "后台壁纸播放器启动失败。\(error.localizedDescription)"
                }
            }
            refresh()
        }
    }

    private func observe() {
        guard observer == nil else { return }
        observer = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled, let self else { return }
                refresh()
                if !isEnabled && launch == nil {
                    observer = nil
                    return
                }
            }
        }
    }

    private func refresh() {
        guard let plan, plan.playing else { return }
        if let report = store.report, report.revision == plan.revision {
            shouldRetryLaunch = false
            let alive = NSRunningApplication(processIdentifier: report.pid)?.isTerminated == false
            isEnabled = alive && report.enabled
            isPreparing = alive && report.preparing
            if report != seenReport {
                message = report.message
                seenReport = report
            }
            if report.enabled && !alive { message = "后台播放已结束，可在设置中恢复。" }
        } else if launch == nil {
            let alive = launchedProcess?.isTerminated == false
                || NSRunningApplication.runningApplications(withBundleIdentifier: BackgroundWallpaperProcess.identifier)
                    .contains { $0.bundleURL?.standardizedFileURL == helper.standardizedFileURL && !$0.isTerminated }
            if !alive && isPreparing {
                if shouldRetryLaunch {
                    shouldRetryLaunch = false
                    start()
                    return
                }
                message = "后台播放已结束，可在设置中恢复。"
            }
            isEnabled = alive
            isPreparing = alive
        }
    }
}
