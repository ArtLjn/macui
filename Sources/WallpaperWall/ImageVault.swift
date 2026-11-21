import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

struct ImagePreview: Sendable {
    let image: CGImage
    let width: Int
    let height: Int

    var size: PixelSize { PixelSize(width: width, height: height) }
    var dimensions: String { size.label }

    var backdrop: DesktopBackdrop { sampleColor(edgesOnly: true) }
    var ambientColor: DesktopBackdrop { sampleColor(edgesOnly: false) }

    private func sampleColor(edgesOnly: Bool) -> DesktopBackdrop {
        let side = 12
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: 4 * side, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return .black }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        var red = 0.0, green = 0.0, blue = 0.0, total = 0.0
        for y in 0..<side {
            for x in 0..<side {
                if edgesOnly && y != 0 && y != side - 1 && x != 0 && x != side - 1 { continue }
                let offset = (y * side + x) * 4
                let r = Double(data[offset]), g = Double(data[offset + 1]), b = Double(data[offset + 2])
                let weight = edgesOnly ? 1 : 1 + (max(r, g, b) - min(r, g, b)) / 85
                red += r * weight
                green += g * weight
                blue += b * weight
                total += weight
            }
        }
        let scale = (edgesOnly ? 0.40 : 1) / (total * 255)
        return DesktopBackdrop(red: red * scale, green: green * scale, blue: blue * scale)
    }
}

final class VerifiedOriginal: Sendable {
    let file: URL
    let size: PixelSize

    init(file: URL, size: PixelSize) {
        self.file = file
        self.size = size
    }

    deinit { try? FileManager.default.removeItem(at: file) }
}

actor ImageVault {
    static let maximumBytes = 50 * 1024 * 1024
    let root: URL
    private lazy var enhancer = WallpaperEnhancer()
    private let cache = NSCache<NSString, CachedPreview>()
    private var previewLoads: [String: PreviewLoad] = [:]

    private struct PreviewLoad {
        let task: Task<ImagePreview, Error>
        var waiters: Set<UUID>
    }

    private final class CachedPreview {
        let value: ImagePreview
        init(_ value: ImagePreview) { self.value = value }
    }

    init(root: URL) {
        self.root = root
        cache.totalCostLimit = 96 * 1024 * 1024
    }

    func importFile(_ url: URL) throws -> StoredImage {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
        return try store(Self.readFile(url))
    }

    func verifyOriginal(_ candidates: [URL], requirements: WallpaperRequirements = WallpaperRequirements()) async throws -> VerifiedOriginal {
        var lastError: Error = WallpaperError.missingUHD
        for url in candidates {
            do {
                let data = try await Self.downloadData(url)
                try Task.checkCancellation()
                return try cacheVerifiedOriginal(data, requirements: requirements)
            } catch {
                try Task.checkCancellation()
                lastError = error
            }
        }
        throw lastError
    }

    func cacheVerifiedOriginal(_ data: Data, requirements: WallpaperRequirements = WallpaperRequirements()) throws -> VerifiedOriginal {
        let source = try Self.imageSource(for: data)
        let size = try Self.pixelSize(of: source)
        if let issue = requirements.issue(for: size) { throw issue }
        _ = try Self.decode(source, maxPixel: 420)
        let file = FileManager.default.temporaryDirectory.appending(path: "WallpaperWall-\(UUID().uuidString)")
        try data.write(to: file, options: .atomic)
        return VerifiedOriginal(file: file, size: size)
    }

    func save(_ original: VerifiedOriginal, requirements: WallpaperRequirements, destination: URL?, title: String) throws -> StoredImage {
        try Task.checkCancellation()
        return try store(Self.readFile(original.file), requirements: requirements, destination: destination, title: title)
    }

    func validateLocal(_ image: StoredImage, requirements: WallpaperRequirements) throws {
        let source = try Self.imageSource(for: Self.readFile(image.original))
        let size = try Self.pixelSize(of: source)
        if let issue = requirements.issue(for: size) { throw issue }
    }

    func preview(at url: URL, maxPixel: Int, enhanced: Bool = false) async throws -> ImagePreview {
        try Task.checkCancellation()
        let key = "\(enhanced):\(maxPixel):\(url.absoluteString)"
        if let existing = cache.object(forKey: key as NSString) { return existing.value }

        let waiter = UUID()
        let task: Task<ImagePreview, Error>
        if let pending = previewLoads[key] {
            task = pending.task
            previewLoads[key]?.waiters.insert(waiter)
        } else {
            task = Task { try await loadPreview(at: url, maxPixel: maxPixel, enhanced: enhanced, key: key) }
            previewLoads[key] = PreviewLoad(task: task, waiters: [waiter])
        }
        defer { releasePreview(key, waiter: waiter) }
        return try await withTaskCancellationHandler {
            let result = try await task.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            Task { await self.releasePreview(key, waiter: waiter) }
        }
    }

    private func releasePreview(_ key: String, waiter: UUID) {
        guard var pending = previewLoads[key], pending.waiters.remove(waiter) != nil else { return }
        if pending.waiters.isEmpty {
            previewLoads.removeValue(forKey: key)
            pending.task.cancel()
        } else {
            previewLoads[key] = pending
        }
    }

    func preloadThumbnails(_ urls: [URL], maxPixel: Int) async {
        await withTaskGroup(of: Void.self) { group in
            var upcoming = urls.makeIterator()
            for _ in 0..<min(2, urls.count) {
                guard let url = upcoming.next() else { break }
                group.addTask { _ = try? await self.preview(at: url, maxPixel: maxPixel) }
            }
            for await _ in group {
                guard !Task.isCancelled, let url = upcoming.next() else { continue }
                group.addTask { _ = try? await self.preview(at: url, maxPixel: maxPixel) }
            }
        }
    }

    private func loadPreview(at url: URL, maxPixel: Int, enhanced: Bool, key: String) async throws -> ImagePreview {
        try Task.checkCancellation()
        let source: CGImageSource
        if url.isFileURL {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                throw WallpaperError.invalidImage
            }
            let options = [kCGImageSourceShouldCache: false] as CFDictionary
            source = try Self.checkedSource(CGImageSourceCreateWithURL(url as CFURL, options))
        } else {
            let (bytes, response) = try await SourceHTTP.previewSession.data(for: SourceHTTP.request(for: url))
            try SourceHTTP.check(response, for: url)
            guard bytes.count <= 12 * 1024 * 1024 else { throw WallpaperError.oversized }
            source = try Self.imageSource(for: bytes)
        }
        try Task.checkCancellation()
        let size = try Self.pixelSize(of: source)
        let decoded = try Self.decode(source, maxPixel: maxPixel)
        let image = enhanced ? try enhancer.render(decoded) : decoded
        let value = ImagePreview(image: image, width: size.width, height: size.height)
        cache.setObject(CachedPreview(value), forKey: key as NSString, cost: image.bytesPerRow * image.height)
        return value
    }

    nonisolated var enhancementFolder: URL {
        root.appending(path: "Enhanced", directoryHint: .isDirectory)
    }

    nonisolated func enhancedLocation(for file: URL) -> URL {
        let fingerprint = SHA256.hash(data: Data(file.standardizedFileURL.path.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return enhancementFolder.appending(path: "v1-\(fingerprint).png")
    }

    func enhancedDesktop(for file: URL) throws -> URL {
        try Task.checkCancellation()
        let destination = enhancedLocation(for: file)
        if FileManager.default.isReadableFile(atPath: destination.path) { return destination }
        let source = try Self.checkedSource(CGImageSourceCreateWithURL(file as CFURL, nil))
        let size = try Self.pixelSize(of: source)
        let decoded = try Self.decode(source, maxPixel: max(size.width, size.height))
        let processed = try enhancer.render(decoded)
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: enhancementFolder, withIntermediateDirectories: true)
        let staging = enhancementFolder.appending(path: ".\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: staging) }
        guard let encoder = CGImageDestinationCreateWithURL(staging as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw WallpaperError.enhancementFailed }
        CGImageDestinationAddImage(encoder, processed, nil)
        guard CGImageDestinationFinalize(encoder) else { throw WallpaperError.enhancementFailed }
        try Task.checkCancellation()
        do {
            try FileManager.default.moveItem(at: staging, to: destination)
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
            guard FileManager.default.isReadableFile(atPath: destination.path) else { throw error }
        }
        return destination
    }

    private static func readFile(_ url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw WallpaperError.invalidImage }
        guard (values.fileSize ?? 0) <= maximumBytes else { throw WallpaperError.oversized }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= maximumBytes else { throw WallpaperError.oversized }
        return data
    }

    private static func downloadData(_ url: URL) async throws -> Data {
        let slowerHosts = [WallpaperSource.tenwallpaper.host, "upload.wikimedia.org"]
        let session = slowerHosts.contains(url.host() ?? "") ? SourceHTTP.slowImageSession : SourceHTTP.session
        let (location, response) = try await session.download(for: SourceHTTP.request(for: url))
        defer { try? FileManager.default.removeItem(at: location) }
        try SourceHTTP.check(response, for: url)
        return try readFile(location)
    }

    private static func imageSource(for data: Data) throws -> CGImageSource {
        try checkedSource(CGImageSourceCreateWithData(data as CFData, nil))
    }

    private static func checkedSource(_ candidate: CGImageSource?) throws -> CGImageSource {
        guard let source = candidate,
              let type = CGImageSourceGetType(source),
              [UTType.jpeg, .png, .heic, .webP, .tiff].contains(UTType(type as String)),
              CGImageSourceGetCount(source) > 0,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete
        else { throw WallpaperError.invalidImage }
        return source
    }

    private static func decode(_ source: CGImageSource, maxPixel: Int) throws -> CGImage {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { throw WallpaperError.invalidImage }
        return image
    }

    private static func dimensions(of source: CGImageSource) throws -> (width: Int, height: Int, orientation: Int, rotated: Bool) {
        guard let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = info[kCGImagePropertyPixelWidth] as? Int,
              let height = info[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0
        else { throw WallpaperError.invalidImage }
        guard PixelSize(width: width, height: height).isSupported else { throw WallpaperError.oversized }
        let orientation = info[kCGImagePropertyOrientation] as? Int ?? 1
        return (width, height, orientation, (5...8).contains(orientation))
    }

    private static func pixelSize(of source: CGImageSource) throws -> PixelSize {
        let info = try dimensions(of: source)
        return PixelSize(width: info.rotated ? info.height : info.width, height: info.rotated ? info.width : info.height)
    }

    func store(
        _ data: Data, requirements: WallpaperRequirements = WallpaperRequirements(),
        destination: URL? = nil, title: String? = nil
    ) throws -> StoredImage {
        let source = try Self.imageSource(for: data)
        guard let type = CGImageSourceGetType(source),
              let ext = UTType(type as String)?.preferredFilenameExtension
        else { throw WallpaperError.invalidImage }
        let (width, height, orientation, rotated) = try Self.dimensions(of: source)
        let pixels = PixelSize(width: rotated ? height : width, height: rotated ? width : height)
        if let issue = requirements.issue(for: pixels) { throw issue }
        let usesOriginal = [UTType.jpeg.identifier, UTType.png.identifier].contains(type as String)
            && orientation == 1 && CGImageSourceGetCount(source) == 1
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let directory = root.appending(path: "Images", directoryHint: .isDirectory)
        let fileName: String
        if destination != nil, let title {
            let readable = title.unicodeScalars.prefix(42).map { character in
                CharacterSet.alphanumerics.contains(character) || character == " " ? String(character) : "_"
            }.joined().trimmingCharacters(in: .whitespaces)
            fileName = readable.isEmpty ? hash : "\(readable) - \(hash.prefix(16))"
        } else {
            fileName = hash
        }
        if let destination,
           (try? destination.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true {
            throw WallpaperError.unavailableFolder
        }
        let original = (destination ?? directory).appending(path: "\(fileName).\(ext)")
        let image = try Self.decode(source, maxPixel: usesOriginal ? 420 : max(width, height))
        let hasAlpha = [CGImageAlphaInfo.first, .last, .premultipliedFirst, .premultipliedLast].contains(image.alphaInfo)
        let desktopType: UTType = hasAlpha ? .png : .jpeg
        let desktop = usesOriginal ? original : directory.appending(path: "\(hash)-desktop.\(hasAlpha ? "png" : "jpg")")
        let stored = StoredImage(
            original: original, desktop: desktop, width: pixels.width, height: pixels.height
        )
        if stored.isAvailable { return stored }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !usesOriginal {
            let converted = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                converted, desktopType.identifier as CFString, 1, nil
            ) else { throw WallpaperError.invalidImage }
            let options = hasAlpha ? nil : [kCGImageDestinationLossyCompressionQuality: 0.97] as CFDictionary
            CGImageDestinationAddImage(destination, image, options)
            guard CGImageDestinationFinalize(destination) else { throw WallpaperError.invalidImage }
            try (converted as Data).write(to: desktop, options: .atomic)
        }
        try data.write(to: original, options: .atomic)
        return stored
    }
}

struct LibraryStorage {
    let root: URL
    private var indexURL: URL { root.appending(path: "Library.json") }

    func load() throws -> LibraryIndex {
        do {
            return try JSONDecoder().decode(LibraryIndex.self, from: Data(contentsOf: indexURL))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return LibraryIndex()
        }
    }

    func save(_ index: LibraryIndex) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(index).write(to: indexURL, options: .atomic)
    }
}
