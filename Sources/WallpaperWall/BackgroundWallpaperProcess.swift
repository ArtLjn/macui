import AppKit
import Darwin

struct BackgroundWallpaperTarget: Codable, Hashable {
    let file: URL
    let placement: Placement
    let backdrop: DesktopBackdrop
    let request: UUID
}

struct BackgroundWallpaperPlan: Codable {
    let revision: UUID
    let targets: [String: BackgroundWallpaperTarget]
    let playing: Bool

    var activeTargets: [String: BackgroundWallpaperTarget] { playing ? targets : [:] }
}

struct BackgroundWallpaperReport: Codable, Equatable {
    let revision: UUID
    let pid: Int32
    let enabled: Bool
    let preparing: Bool
    let displayedFrame: Bool
    let message: String?
}

struct BackgroundWallpaperStore {
    let root: URL

    var plan: BackgroundWallpaperPlan? { read("Plan.json") }
    var report: BackgroundWallpaperReport? { read("Report.json") }

    func write(_ plan: BackgroundWallpaperPlan) throws { try write(plan, to: "Plan.json") }
    func write(_ report: BackgroundWallpaperReport) throws { try write(report, to: "Report.json") }

    private func read<Value: Decodable>(_ name: String) -> Value? {
        guard let data = try? Data(contentsOf: root.appending(path: name)) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    private func write(_ value: some Encodable, to name: String) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: root.appending(path: name), options: .atomic)
    }
}

@MainActor
final class BackgroundWallpaperProcess {
    static let identifier = "local.wallpaperwall.mac.motion"
    static let bundleName = "WallpaperMotion.app"
    static let rootArgument = "--motion-state-root"

    private let store: BackgroundWallpaperStore
    private let renderer: LiveDesktopWallpaper
    private var applied: BackgroundWallpaperPlan?
    private var report: BackgroundWallpaperReport?
    private var idleSince: ContinuousClock.Instant?

    private init(store: BackgroundWallpaperStore) {
        self.store = store
        let resources = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Resources", directoryHint: .isDirectory)
        let model = resources.appending(path: "DepthAnythingV2SmallF16P6.mlmodelc", directoryHint: .isDirectory)
        renderer = LiveDesktopWallpaper(loader: DepthWallpaperLoader(modelURL: model))
    }

    static func run() {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: rootArgument), args.indices.contains(flag + 1),
              args[flag + 1].hasPrefix("/") else { return }
        let root = URL(fileURLWithPath: args[flag + 1], isDirectory: true)
        guard let plan = BackgroundWallpaperStore(root: root).plan, !plan.activeTargets.isEmpty else { return }

        // 同一份播放状态只允许一个后台播放器占用。
        let lock = open(root.appending(path: "Player.lock").path, O_RDWR | O_CREAT, S_IRUSR | S_IWUSR)
        guard lock >= 0 else { return }
        defer { close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { return }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let process = Self(store: BackgroundWallpaperStore(root: root))
        let observation = Task { await process.monitor() }
        withExtendedLifetime(process) { app.run() }
        observation.cancel()
    }

    private func monitor() async {
        while !Task.isCancelled {
            guard let next = store.plan else {
                renderer.stopAll()
                break
            }
            if applied?.revision != next.revision {
                update(next)
            }
            publish(next)
            if next.activeTargets.isEmpty || (!renderer.isEnabled && renderer.message != nil) {
                if let idleSince, ContinuousClock.now - idleSince >= .seconds(1) { break }
                if idleSince == nil { idleSince = .now }
            } else {
                idleSince = nil
            }
            try? await Task.sleep(for: .milliseconds(350))
        }
        renderer.stopAll()
        NSApplication.shared.stop(nil)
        // 唤醒 AppKit 事件循环，让无界面进程也能退出。
        if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                                           timestamp: 0, windowNumber: 0, context: nil,
                                           subtype: 0, data1: 0, data2: 0) {
            NSApplication.shared.postEvent(event, atStart: false)
        }
    }

    private func update(_ next: BackgroundWallpaperPlan) {
        let old = applied?.activeTargets ?? [:]
        let new = next.activeTargets
        let changed = new.filter { old[$0.key] != $0.value }
        renderer.stop(on: old.keys.filter { old[$0] != new[$0] })
        for (target, displays) in Dictionary(grouping: changed, by: \.value) {
            guard target.file.isFileURL else { continue }
            renderer.play(target.file, on: displays.map(\.key), placement: target.placement, backdrop: target.backdrop)
        }
        applied = next
        idleSince = nil
    }

    private func publish(_ next: BackgroundWallpaperPlan) {
        let latest = BackgroundWallpaperReport(revision: next.revision, pid: getpid(), enabled: renderer.isEnabled,
                                                preparing: renderer.isPreparing, displayedFrame: renderer.submittedFrames > 0,
                                                message: renderer.message)
        if latest != report, (try? store.write(latest)) != nil { report = latest }
    }
}
