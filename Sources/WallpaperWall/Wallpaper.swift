import Foundation

enum WallpaperSource: String, Codable, CaseIterable, Sendable {
    case wallpic, tenwallpaper, bizhicang, hao, netbian, wallhaven, bing, commons, nasa, local

    static let online: [Self] = [.bizhicang, .tenwallpaper, .wallpic, .wallhaven, .bing, .commons]
    static let featured: [Self] = [.bizhicang, .tenwallpaper]
    static let featuredName = "国内精选"

    var name: String {
        switch self {
        case .wallpic: "Wallpic"
        case .tenwallpaper: "10wallpaper 中文"
        case .bizhicang: "壁纸仓"
        case .hao: "哲风壁纸"
        case .netbian: "彼岸图网"
        case .wallhaven: "Wallhaven"
        case .bing: "Bing 每日"
        case .commons: "Wikimedia Commons"
        case .nasa: "NASA 图库"
        case .local: "本机导入"
        }
    }

    var host: String {
        switch self {
        case .wallpic: "www.wallpic.cn"
        case .tenwallpaper: "www.10wallpaper.com"
        case .bizhicang: "www.bizhicang.com"
        case .hao: "haowallpaper.com"
        case .netbian: "pic.netbian.com"
        case .wallhaven: "wallhaven.cc"
        case .bing: "www.bing.com"
        case .commons: "commons.wikimedia.org"
        case .nasa, .local: ""
        }
    }
}

struct PixelSize: Codable, Hashable, Sendable {
    static let maximumArea = 75_000_000

    let width: Int
    let height: Int

    var isSupported: Bool { width > 0 && height > 0 && width <= Self.maximumArea / height }
    var isUHD: Bool { max(width, height) >= 3840 && min(width, height) >= 2160 }
    var aspect: Double { Double(width) / Double(height) }
    var label: String { "\(width) × \(height)" }

    func cropFraction(for screenAspect: Double) -> Double {
        1 - min(aspect / screenAspect, screenAspect / aspect)
    }
}

struct WallpaperRequirements: Sendable {
    static let maximumCrop = 0.18
    var screenAspects: [Double] = []
    var preferredScreen: PixelSize?

    func issue(for size: PixelSize) -> WallpaperError? {
        if !size.isUHD { return .belowUHD(size) }
        if screenAspects.contains(where: { size.cropFraction(for: $0) > Self.maximumCrop }) {
            return .mismatchedAspect(size)
        }
        return nil
    }
}

struct Wallpaper: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let title: String
    let source: WallpaperSource
    let detail: URL?
    var author: String? = nil
    var thumbnail: URL? = nil
    var preview: URL? = nil
    var original: URL? = nil
    var advertisedSize: PixelSize? = nil
    var license: String? = nil

    var downloadsOnOriginalSite: Bool { (source == .netbian || source == .hao) && original == nil }
}

struct StoredImage: Codable, Hashable, Sendable {
    let original: URL
    let desktop: URL
    let width: Int
    let height: Int

    var size: PixelSize { PixelSize(width: width, height: height) }
    var dimensions: String { size.label }
    var isAvailable: Bool {
        FileManager.default.isReadableFile(atPath: original.path)
            && FileManager.default.isReadableFile(atPath: desktop.path)
    }
}

struct LibraryEntry: Codable, Sendable {
    var wallpaper: Wallpaper
    var image: StoredImage?
    var favorite = false
    var savedAt: Date?
    var usedAt: Date?
}

struct LibraryIndex: Codable, Sendable {
    var entries: [String: LibraryEntry] = [:]
    var undo: [DesktopSnapshot] = []
    var matchScreen: Bool? = nil
    var downloadFolder: URL? = nil
}

enum WallpaperError: LocalizedError, Equatable {
    case badResponse
    case invalidImage
    case enhancementFailed
    case oversized
    case missingImage
    case unavailableDisplay
    case fullscreenExitUnconfirmed
    case desktopChangeUnconfirmed
    case missingPreviousWallpaper
    case belowUHD(PixelSize)
    case missingUHD
    case mismatchedAspect(PixelSize)
    case unavailableFolder
    case downloadOnOriginalSite

    var errorDescription: String? {
        switch self {
        case .badResponse: "图源暂时无法访问，请稍后重试。"
        case .invalidImage: "无法打开这张图片，支持 JPEG、PNG、HEIC、WebP 和 TIFF。"
        case .enhancementFailed: "无法增强这张壁纸。关闭「画质增强」后可使用原图。"
        case .oversized: "图片超过 50 MB 或 7500 万像素，无法导入。"
        case .missingImage: "没有找到可用的图片。可以打开原站查看。"
        case .unavailableDisplay: "目标显示器已断开，请重新选择。"
        case .fullscreenExitUnconfirmed: "未能返回普通桌面，请退出全屏后重试。"
        case .desktopChangeUnconfirmed: "macOS 未确认桌面壁纸已切换，请重试。"
        case .missingPreviousWallpaper: "系统提供的上一张壁纸文件已无法访问。"
        case .belowUHD(let size): "这张图实际是 \(size.label)，低于 4K。请选择更高分辨率的图片。"
        case .missingUHD: "这个图源没有提供可用的 4K 文件。"
        case .mismatchedAspect(let size): "填满目标显示器时会裁掉较多内容（\(size.label)）。可改用「适应」或关闭比例筛选。"
        case .unavailableFolder: "无法访问下载目录，请重新选择一个文件夹。"
        case .downloadOnOriginalSite: "请在原站下载原图，再导入 macui。"
        }
    }
}
