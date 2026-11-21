import AppKit
import CoreGraphics

enum Placement: String, CaseIterable, Identifiable, Codable, Sendable {
    case fill = "填满"
    case fit = "适应"

    var id: Self { self }

    func options(backdrop: DesktopBackdrop) -> [NSWorkspace.DesktopImageOptionKey: Any] {
        [
            .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
            .allowClipping: self == .fill,
            .fillColor: self == .fit ? backdrop.color : NSColor.black
        ]
    }

    func scale(from image: PixelSize, to screen: PixelSize) -> Double {
        let width = Double(screen.width) / Double(image.width)
        let height = Double(screen.height) / Double(image.height)
        return self == .fill ? max(width, height) : min(width, height)
    }
}

struct DesktopBackdrop: Hashable, Codable, Sendable {
    static let black = Self(red: 0, green: 0, blue: 0)
    let red: Double
    let green: Double
    let blue: Double

    var color: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1) }
}

struct Display: Identifiable {
    let id: String
    let name: String
    let pixels: PixelSize
}

struct DesktopSnapshot: Codable, Sendable {
    let displayID: String
    let file: URL
    let scaling: UInt?
    let clipping: Bool?
    let fillColor: Data?
}

struct DesktopChange {
    var successful = 0
    var previous: [DesktopSnapshot] = []
    var errors: [String: String] = [:]
}

@MainActor
protocol DesktopChanging {
    var displays: [Display] { get }
    func current(on displayID: String?) -> URL?
    func apply(_ image: URL, to displayIDs: [String], placement: Placement, backdrop: DesktopBackdrop) async -> DesktopChange
    func restore(_ snapshots: [DesktopSnapshot]) async -> DesktopChange
}

@MainActor
struct DesktopService: DesktopChanging {
    private let workspace = NSWorkspace.shared
    private let transition = DesktopTransition()

    var displays: [Display] {
        NSScreen.screens.map { screen in
            let isPrimary = screen == NSScreen.screens.first
            return Display(
                id: Self.id(for: screen), name: isPrimary ? "主显示器" : screen.localizedName,
                pixels: Self.pixels(for: screen)
            )
        }
    }

    static func pixels(for screen: NSScreen) -> PixelSize {
        let size = screen.convertRectToBacking(screen.frame).size
        return PixelSize(width: Int(size.width.rounded()), height: Int(size.height.rounded()))
    }

    func current(on displayID: String?) -> URL? {
        guard let id = displayID, let screen = screen(for: id) else { return nil }
        return workspace.desktopImageURL(for: screen)
    }

    func apply(_ image: URL, to displayIDs: [String], placement: Placement, backdrop: DesktopBackdrop) async -> DesktopChange {
        guard !displayIDs.isEmpty else { return DesktopChange() }
        do {
            try await leaveFullscreen()
        } catch {
            return DesktopChange(errors: Dictionary(displayIDs.map { ($0, error.localizedDescription) }, uniquingKeysWith: { first, _ in first }))
        }
        var result = DesktopChange()
        for id in displayIDs {
            do {
                guard let screen = screen(for: id) else { throw WallpaperError.unavailableDisplay }
                let before = snapshot(of: screen, id: id)
                try await setImage(image, for: screen, id: id, previous: before, options: placement.options(backdrop: backdrop))
                result.successful += 1
                if let before { result.previous.append(before) }
            } catch {
                result.errors[id] = error.localizedDescription
            }
        }
        return result
    }

    func restore(_ snapshots: [DesktopSnapshot]) async -> DesktopChange {
        guard !snapshots.isEmpty else { return DesktopChange() }
        do {
            try await leaveFullscreen()
        } catch {
            let errors = snapshots.map { ($0.displayID, error.localizedDescription) }
            return DesktopChange(errors: Dictionary(errors, uniquingKeysWith: { first, _ in first }))
        }
        var result = DesktopChange()
        for snapshot in snapshots {
            do {
                guard let screen = screen(for: snapshot.displayID) else { throw WallpaperError.unavailableDisplay }
                guard FileManager.default.isReadableFile(atPath: snapshot.file.path)
                else { throw WallpaperError.missingPreviousWallpaper }
                var options: [NSWorkspace.DesktopImageOptionKey: Any] = [:]
                options[.imageScaling] = snapshot.scaling
                options[.allowClipping] = snapshot.clipping
                if let data = snapshot.fillColor,
                   let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data) {
                    options[.fillColor] = color
                }
                let before = self.snapshot(of: screen, id: snapshot.displayID)
                try await setImage(snapshot.file, for: screen, id: snapshot.displayID, previous: before, options: options)
                result.successful += 1
            } catch {
                result.errors[snapshot.displayID] = error.localizedDescription
            }
        }
        return result
    }

    private func leaveFullscreen() async throws {
        guard let window = NSApp?.windows.first(where: {
            $0.canBecomeMain && $0.isOnActiveSpace && $0.styleMask.contains(.fullScreen)
        }) else { return }
        // macOS 会把当前全屏窗口视为独立空间，退出后才对普通桌面设置壁纸。
        let (events, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let center = NotificationCenter.default
        let observer = center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: nil) { _ in
            continuation.yield(())
        }
        defer {
            center.removeObserver(observer)
            continuation.finish()
        }
        window.toggleFullScreen(nil)
        let exited = await withTaskGroup(of: Bool.self) { tasks in
            tasks.addTask {
                for await _ in events { return true }
                return false
            }
            tasks.addTask {
                try? await Task.sleep(for: .seconds(5))
                return false
            }
            let value = await tasks.next() ?? false
            tasks.cancelAll()
            return value
        }
        try Task.checkCancellation()
        guard exited, try await waitUntil(timeout: .seconds(1), { window.isOnActiveSpace }) else {
            throw WallpaperError.fullscreenExitUnconfirmed
        }
    }

    private func setImage(_ image: URL, for screen: NSScreen, id: String, previous: DesktopSnapshot?,
                          options: [NSWorkspace.DesktopImageOptionKey: Any]) async throws {
        transition.cover(screen, id: id, previous: previous, next: image)
        do {
            try workspace.setDesktopImageURL(image, for: screen, options: options)
            let expected = image.standardizedFileURL
            let confirmed = try await waitUntil(timeout: .seconds(3)) {
                workspace.desktopImageURL(for: screen)?.standardizedFileURL == expected
            }
            guard confirmed else { throw WallpaperError.desktopChangeUnconfirmed }
        } catch {
            transition.cancel(for: id)
            throw error
        }
        transition.reveal(for: id)
    }

    private func waitUntil(timeout: Duration, _ predicate: () -> Bool) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !predicate() {
            guard clock.now < deadline else { return false }
            try await Task.sleep(for: .milliseconds(80))
        }
        return true
    }

    private func snapshot(of screen: NSScreen, id: String) -> DesktopSnapshot? {
        guard let file = workspace.desktopImageURL(for: screen), file.isFileURL,
              FileManager.default.isReadableFile(atPath: file.path) else { return nil }
        let options = workspace.desktopImageOptions(for: screen) ?? [:]
        let color = (options[.fillColor] as? NSColor).flatMap {
            try? NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true)
        }
        return DesktopSnapshot(
            displayID: id, file: file, scaling: (options[.imageScaling] as? NSNumber)?.uintValue,
            clipping: (options[.allowClipping] as? NSNumber)?.boolValue, fillColor: color
        )
    }

    private func screen(for id: String) -> NSScreen? {
        NSScreen.screens.first { Self.id(for: $0) == id }
    }

    static func id(for screen: NSScreen) -> String {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return screen.localizedName }
        if let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() {
            return CFUUIDCreateString(nil, uuid) as String
        }
        return number.stringValue
    }
}
