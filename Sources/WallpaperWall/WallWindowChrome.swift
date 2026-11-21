import AppKit
import SwiftUI

struct WallPaneDivider: View {
    let width: CGFloat
    let backgroundOpacity: Double
    let resize: (CGFloat) -> Void
    @Environment(\.wallPalette) private var palette
    @State private var dragStart: CGFloat?
    @State private var hovering = false

    var body: some View {
        Rectangle()
            .fill(hovering ? palette.secondary : palette.line)
            .frame(width: 1)
            .frame(width: 5)
            .background(palette.canvas.opacity(backgroundOpacity))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let initial = dragStart ?? width
                    dragStart = initial
                    resize(initial + value.translation.width)
                }
                .onEnded { _ in dragStart = nil })
            .onHover { over in
                hovering = over
                if over { NSCursor.resizeLeftRight.set() }
                else { NSCursor.arrow.set() }
            }
            .accessibilityHidden(true)
    }
}

struct WallWindowMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .windowBackground
        view.blendingMode = .withinWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

struct WallScreenObserver: NSViewRepresentable {
    let onScreen: (String?) -> Void

    func makeNSView(context: Context) -> ScreenView { ScreenView() }
    func updateNSView(_ view: ScreenView, context: Context) { view.onScreen = onScreen }

    final class ScreenView: NSView {
        var onScreen: ((String?) -> Void)?

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeScreenNotification, object: window)
            super.viewWillMove(toWindow: newWindow)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            NotificationCenter.default.addObserver(self, selector: #selector(screenChanged),
                                                   name: NSWindow.didChangeScreenNotification, object: window)
            Task { @MainActor [weak self] in self?.screenChanged() }
        }

        @objc private func screenChanged() {
            onScreen?(window?.screen.map { DesktopService.id(for: $0) })
        }
    }
}

struct WallWindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}

    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}
