import AppKit
import Testing
@testable import WallpaperWall

struct BackgroundWallpaperProcessTests {
    @Test func stoppedPlanRetainsOnlyTheConfiguration() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BackgroundWallpaperStore(root: root)
        let target = BackgroundWallpaperTarget(file: URL(fileURLWithPath: "/wallpaper.png"), placement: .fit,
                                               backdrop: .black, request: UUID())
        let plan = BackgroundWallpaperPlan(revision: UUID(), targets: ["display": target], playing: false)
        try store.write(plan)
        let saved = try #require(store.plan)
        #expect(saved.revision == plan.revision)
        #expect(saved.targets["display"] == target)
        #expect(saved.activeTargets.isEmpty)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WALLPAPER_WALL_AGENT_TEST"] != nil))
    @MainActor func rendererOutlivesLauncherAndCanBeStoppedAndResumed() async throws {
        _ = NSApplication.shared
        let helperPath = try #require(ProcessInfo.processInfo.environment["WALLPAPER_WALL_AGENT_TEST"])
        let helper = URL(fileURLWithPath: helperPath, isDirectory: true)
        try #require(NSRunningApplication.runningApplications(withBundleIdentifier: BackgroundWallpaperProcess.identifier).isEmpty)
        let workspace = NSWorkspace.shared
        try #require(!workspace.accessibilityDisplayShouldReduceMotion)
        let screen = try #require(NSScreen.screens.first)
        let file = try #require(workspace.desktopImageURL(for: screen)).standardizedFileURL
        try #require(file.isFileURL && FileManager.default.isReadableFile(atPath: file.path))
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BackgroundWallpaperStore(root: root)
        let target = BackgroundWallpaperTarget(file: file, placement: .fill, backdrop: .black, request: UUID())
        let plan = BackgroundWallpaperPlan(revision: UUID(), targets: [DesktopService.id(for: screen): target], playing: true)
        try store.write(plan)
        defer {
            try? store.write(BackgroundWallpaperPlan(revision: UUID(), targets: [:], playing: false))
            if let report = store.report { _ = NSRunningApplication(processIdentifier: report.pid)?.terminate() }
        }

        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        launcher.arguments = ["-g", "-n", helper.path, "--args", BackgroundWallpaperProcess.rootArgument, root.path]
        try launcher.run()
        launcher.waitUntilExit()
        #expect(launcher.terminationStatus == 0)
        let started = try await waitForFrame(store)
        #expect(!launcher.isRunning)
        #expect(NSRunningApplication(processIdentifier: started.pid)?.isTerminated == false)
        print("后台刚开始播放：\(memorySummary(pid: started.pid))")
        try await Task.sleep(for: .seconds(6))
        print("后台稳定播放：\(memorySummary(pid: started.pid))")

        let control = BackgroundWallpaperClient(helper: helper, root: root)
        #expect(control.isEnabled)
        #expect(control.stopAll())
        try await waitForExit(started.pid)
        #expect(control.canResume)

        #expect(control.resume())
        let restarted = try await waitForFrame(store)
        #expect(restarted.pid != started.pid)
        #expect(control.stopAll())
        try await waitForExit(restarted.pid)
        #expect(workspace.desktopImageURL(for: screen)?.standardizedFileURL == file)
    }

    private func waitForFrame(_ store: BackgroundWallpaperStore) async throws -> BackgroundWallpaperReport {
        for _ in 0..<200 {
            if let plan = store.plan, let report = store.report,
               report.revision == plan.revision && report.displayedFrame { return report }
            try await Task.sleep(for: .milliseconds(100))
        }
        Issue.record("后台播放器没有提交画面：\(store.report?.message ?? "无报告")")
        return try #require(nil as BackgroundWallpaperReport?)
    }

    private func waitForExit(_ pid: Int32) async throws {
        for _ in 0..<40 {
            if NSRunningApplication(processIdentifier: pid)?.isTerminated != false { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(NSRunningApplication(processIdentifier: pid)?.isTerminated != false)
    }

    private func memorySummary(pid: Int32) -> String {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/vmmap")
        process.arguments = ["-summary", String(pid)]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return "无法取得内存采样" }
        let result = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let lines = String(decoding: result, as: UTF8.self).split(separator: "\n")
        return lines.filter { $0.hasPrefix("Physical footprint") }
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .joined(separator: "，")
    }
}
