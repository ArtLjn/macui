import AppKit
import SwiftUI

@main
enum WallpaperWallEntry {
    @MainActor static func main() {
        if Bundle.main.bundleIdentifier == BackgroundWallpaperProcess.identifier {
            BackgroundWallpaperProcess.run()
        } else {
            WallpaperWallApp.main()
        }
    }
}

struct WallpaperWallApp: App {
    @NSApplicationDelegateAdaptor(WallpaperWallLifecycle.self) private var appDelegate
    @State private var model = WallModel()
    @State private var showingImporter = false
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("macui", id: "gallery") {
            WallView(model: model, showingImporter: $showingImporter)
                .preferredColorScheme(.dark)
                .frame(minWidth: 890, minHeight: 590)
        }
        .defaultSize(width: 1240, height: 770)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("导入图片…") {
                    showGallery()
                    showingImporter = true
                }
                .keyboardShortcut("o")
            }
        }

        MenuBarExtra("macui", systemImage: "photo.on.rectangle.angled") {
            Text("主显示器 · \(model.currentName)")
            Divider()
            Button("打开macui", action: showGallery)
            Button("换一张") { Task { await model.nextOffline() } }
                .disabled(model.downloaded.isEmpty || model.busy)
            Button("撤销上次切换") { Task { await model.undo() } }
                .disabled(!model.canUndo || model.busy)
            if model.liveWallpaper.isEnabled {
                Button("停止动态壁纸") { model.stopLiveWallpaper() }
                    .disabled(model.busy)
            }
            if model.canCancelDownload {
                Button("取消下载") { model.cancelDownload() }
            }
            if model.canRetry {
                Button("重试失败的显示器") { Task { await model.retryFailedDisplays() } }
                    .disabled(model.busy)
            }
            if let status = model.operationStatus {
                Button(status, action: showGallery)
            }
            Divider()
            Button("退出macui") { NSApplication.shared.terminate(nil) }
        }

        Settings {
            WallSettings(model: model)
                .preferredColorScheme(.dark)
                .tint(WallPalette().accent)
        }
    }

    private func showGallery() {
        openWindow(id: "gallery")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

final class WallpaperWallLifecycle: NSObject, NSApplicationDelegate {
    static let bundledIcon = Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
        .flatMap { NSImage(contentsOf: $0) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let icon = Self.bundledIcon {
            NSApplication.shared.applicationIconImage = icon
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
