import AppKit
import CoreGraphics
import ImageIO
import QuartzCore

@MainActor
final class DesktopTransition {
    private var overlays: [String: Overlay] = [:]

    private struct Overlay {
        let panel: DesktopPanel
        var task: Task<Void, Never>?
    }

    func cover(_ screen: NSScreen, id: String, previous: DesktopSnapshot?, next file: URL) {
        cancel(for: id)
        guard UserDefaults.standard.object(forKey: WallAppearance.animatesWallpaper) as? Bool ?? true,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let previous, previous.file.standardizedFileURL != file.standardizedFileURL,
              ["jpg", "jpeg", "png", "heic", "webp", "tif", "tiff"].contains(previous.file.pathExtension.lowercased()),
              let source = CGImageSourceCreateWithURL(previous.file as CFURL, nil),
              CGImageSourceGetCount(source) == 1,
              let image = NSImage(contentsOf: previous.file), image.size.width > 0, image.size.height > 0
        else { return }

        let panel = DesktopPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false, screen: screen)
        panel.setFrame(screen.frame, display: false)
        // 覆盖旧壁纸的窗口位于系统桌面与桌面图标之间。
        panel.level = .wallpaperTransition
        panel.collectionBehavior = [.stationary, .transient, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .none
        panel.hasShadow = false
        panel.contentView = DesktopFrame(image: image, snapshot: previous)
        overlays[id] = Overlay(panel: panel)
        panel.orderFrontRegardless()
    }

    func reveal(for id: String) {
        guard let panel = overlays[id]?.panel else { return }
        overlays[id]?.task = Task { @MainActor [weak self, weak panel] in
            try? await Task.sleep(for: .milliseconds(55))
            guard !Task.isCancelled, let panel else { return }
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.40
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().alphaValue = 0
            }
            guard !Task.isCancelled else { return }
            self?.cancel(for: id)
        }
    }

    func cancel(for id: String) {
        guard let overlay = overlays.removeValue(forKey: id) else { return }
        overlay.task?.cancel()
        overlay.panel.orderOut(nil)
    }

    private final class DesktopPanel: NSPanel {
        override var canBecomeMain: Bool { false }
        override var canBecomeKey: Bool { false }
    }

    private final class DesktopFrame: NSView {
        let image: NSImage
        let scaling: UInt?
        let clipping: Bool
        let fill: NSColor

        init(image: NSImage, snapshot: DesktopSnapshot) {
            self.image = image
            scaling = snapshot.scaling
            clipping = snapshot.clipping ?? false
            fill = snapshot.fillColor.flatMap {
                try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: $0)
            } ?? .black
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override var isOpaque: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            fill.setFill()
            dirtyRect.fill()
            var destination = bounds
            if scaling != NSImageScaling.scaleAxesIndependently.rawValue {
                let x = bounds.width / image.size.width
                let y = bounds.height / image.size.height
                var scale = clipping ? max(x, y) : min(x, y)
                if scaling == NSImageScaling.scaleNone.rawValue { scale = 1 }
                if scaling == NSImageScaling.scaleProportionallyDown.rawValue { scale = min(1, scale) }
                let width = image.size.width * scale, height = image.size.height * scale
                destination = NSRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2,
                                     width: width, height: height)
            }
            image.draw(in: destination, from: .zero, operation: .sourceOver, fraction: 1,
                       respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        }
    }
}
