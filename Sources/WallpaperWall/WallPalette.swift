import SwiftUI

struct WallPalette {
    var wallpaper: DesktopBackdrop? = nil

    var canvas: Color { surface(0.084) }
    var sidebar: Color { surface(0.124) }
    var inspector: Color { surface(0.108) }
    var raised: Color { surface(0.162) }
    var selection: Color { surface(0.224) }
    var line: Color { surface(0.21) }
    var secondary: Color { Color(white: 0.73) }
    var accent: Color { surface(0.91, tint: 0.11) }
    var action: Color { surface(0.93, tint: 0.16) }

    private func surface(_ lightness: Double, tint: Double = 0.42) -> Color {
        guard let sample = wallpaper else {
            return Color(red: lightness * 0.97, green: lightness, blue: lightness * 1.02)
        }
        let mean = (sample.red + sample.green + sample.blue) / 3
        // 只保留有限色偏，明亮壁纸也不会抬高整个窗口的亮度。
        func channel(_ value: Double) -> Double {
            max(0, min(1, lightness + min(0.075, max(-0.043, (value - mean) * tint))))
        }
        return Color(red: channel(sample.red), green: channel(sample.green), blue: channel(sample.blue))
    }
}

private struct WallPaletteKey: EnvironmentKey {
    static let defaultValue = WallPalette()
}

extension EnvironmentValues {
    var wallPalette: WallPalette {
        get { self[WallPaletteKey.self] }
        set { self[WallPaletteKey.self] = newValue }
    }
}

enum WallAppearance {
    static let followsWallpaper = "followsDesktopWallpaperColors"
    static let animatesWallpaper = "animatesDesktopWallpaperChanges"
}
