import CoreGraphics
import CoreML
import CoreVideo
import ImageIO

struct DepthField: Sendable {
    static let horizontalMotion: Float = 0.016
    static let verticalMotion: Float = 0.009

    let width: Int
    let height: Int
    let pixels: [UInt8]

    init?(width: Int, height: Int, values: [Float]) {
        guard width > 1, height > 1, values.count == width * height else { return nil }
        let finite = values.filter(\.isFinite).sorted()
        guard finite.count > values.count / 2 else { return nil }
        let low = finite[finite.count / 50]
        let high = finite[finite.count - 1 - finite.count / 50]
        guard high - low > max(0.0001, abs(high) * 0.001) else { return nil }
        let normalized = values.map { raw in
            let unit = raw.isFinite ? (raw - low) / (high - low) : 0.5
            let value = min(1, max(0, (unit - 0.1) / 0.8))
            return value * value * (3 - 2 * value)
        }
        let horizontal = Self.smooth(normalized, width: width, height: height, horizontal: true)
        let field = Self.smooth(horizontal, width: width, height: height, horizontal: false)
        let xWeight = Self.horizontalMotion * Float(width)
        let yWeight = Self.verticalMotion * Float(height)
        var maxSlope: Float = 0
        // 为 8 位深度纹理的量化误差留余量，防止细轮廓在运动时折返。
        for y in 0..<(height - 1) {
            for x in 0..<(width - 1) {
                let index = y * width + x
                let a = field[index], b = field[index + 1]
                let c = field[index + width], d = field[index + width + 1]
                let dx = max(abs(a - b), abs(c - d))
                let dy = max(abs(a - c), abs(b - d))
                maxSlope = max(maxSlope, xWeight * dx + yWeight * dy)
            }
        }
        let limit = 0.5 - (xWeight + yWeight) / 255
        let contrast = maxSlope > 0 ? min(1, limit / maxSlope) : 1
        self.width = width
        self.height = height
        pixels = field.map { UInt8((((($0 - 0.5) * contrast) + 0.5) * 255).rounded()) }
    }

    private static func smooth(_ field: [Float], width: Int, height: Int, horizontal: Bool) -> [Float] {
        let sigma = max(1, Double(horizontal ? width : height) * 0.012)
        let radius = Int(ceil(sigma * 3))
        let weights = (-radius...radius).map { Float(exp(-Double($0 * $0) / (2 * sigma * sigma))) }
        let total = weights.reduce(0, +)
        return field.indices.map { index in
            let x = index % width, y = index / width
            var sum: Float = 0
            for offset in -radius...radius {
                let sx = horizontal ? min(width - 1, max(0, x + offset)) : x
                let sy = horizontal ? y : min(height - 1, max(0, y + offset))
                sum += field[sy * width + sx] * weights[offset + radius]
            }
            return sum / total
        }
    }
}

struct DepthWallpaperAsset: Sendable {
    let width: Int
    let height: Int
    let bgra: Data
    let depth: DepthField

    init(image: CGImage, depth: DepthField, backdrop: DesktopBackdrop = .black) throws {
        let width = image.width, height = image.height
        let stride = width * 4
        var pixels = Data(count: stride * height)
        // 先由 Core Graphics 做色彩管理并统一字节顺序，再按相同格式上传纹理。
        try pixels.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let canvas = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                         bytesPerRow: stride, space: space,
                                         bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue |
                                             CGImageAlphaInfo.premultipliedFirst.rawValue)
            else { throw DepthWallpaperError.rendererUnavailable }
            let rect = CGRect(x: 0, y: 0, width: width, height: height)
            canvas.setFillColor(red: backdrop.red, green: backdrop.green, blue: backdrop.blue, alpha: 1)
            canvas.fill(rect)
            canvas.draw(image, in: rect)
        }
        self.width = width
        self.height = height
        self.bgra = pixels
        self.depth = depth
    }
}

enum DepthWallpaperError: LocalizedError {
    case modelUnavailable, depthUnavailable, rendererUnavailable

    var errorDescription: String? {
        switch self {
        case .modelUnavailable: "景深模型不可用，已保留静态壁纸。"
        case .depthUnavailable: "这张图无法生成有效景深，已保留静态壁纸。"
        case .rendererUnavailable: "无法启动 2.5D 渲染，已保留静态壁纸。"
        }
    }
}

actor DepthWallpaperLoader {
    private let modelURL: URL?
    private var recent: [(URL, DepthField)] = []

    init(modelURL: URL? = Bundle.main.url(forResource: "DepthAnythingV2SmallF16P6", withExtension: "mlmodelc")) {
        self.modelURL = modelURL
    }

    func load(_ file: URL, backdrop: DesktopBackdrop, placement: Placement,
              displays: [PixelSize]) throws -> DepthWallpaperAsset {
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else {
            throw WallpaperError.invalidImage
        }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Self.textureLimit(source, placement: placement, displays: displays)
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            throw WallpaperError.invalidImage
        }
        let key = file.standardizedFileURL
        let depth: DepthField
        if let index = recent.firstIndex(where: { $0.0 == key }) {
            depth = recent.remove(at: index).1
        } else {
            depth = try autoreleasepool { try estimate(image) }
        }
        try Task.checkCancellation()
        recent.insert((key, depth), at: 0)
        if recent.count > 6 { recent.removeLast() }
        return try DepthWallpaperAsset(image: image, depth: depth, backdrop: backdrop)
    }

    private static func textureLimit(_ source: CGImageSource, placement: Placement, displays: [PixelSize]) -> Int {
        guard let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = info[kCGImagePropertyPixelWidth] as? Int,
              let height = info[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else { return 4096 }
        let rotated = (5...8).contains(info[kCGImagePropertyOrientation] as? Int ?? 1)
        let image = PixelSize(width: rotated ? height : width, height: rotated ? width : height)
        guard let scale = displays.map({ placement.scale(from: image, to: $0) }).max() else { return 4096 }
        // 按目标屏幕所需的像素上传纹理，并给 2.5D 的轻微裁切留余量。
        return min(4096, max(1, Int(ceil(Double(max(width, height)) * min(1, scale * 1.025)))))
    }

    private func estimate(_ image: CGImage) throws -> DepthField {
        guard let modelURL else { throw DepthWallpaperError.modelUnavailable }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        guard let model = try? MLModel(contentsOf: modelURL, configuration: configuration),
              let input = model.modelDescription.inputDescriptionsByName["image"]?.imageConstraint else {
            throw DepthWallpaperError.modelUnavailable
        }
        let buffer = try Self.inputBuffer(image, width: input.pixelsWide, height: input.pixelsHigh)
        let features = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: buffer)])
        let prediction = try model.prediction(from: features)
        guard let output = prediction.featureValue(for: "depth")?.imageBufferValue,
              let depth = Self.depthField(output) else {
            throw DepthWallpaperError.depthUnavailable
        }
        return depth
    }

    private static func inputBuffer(_ image: CGImage, width: Int, height: Int) throws -> CVPixelBuffer {
        var destination: CVPixelBuffer?
        let attributes = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                  attributes, &destination) == kCVReturnSuccess,
              let destination, CVPixelBufferLockBaseAddress(destination, []) == kCVReturnSuccess else {
            throw DepthWallpaperError.depthUnavailable
        }
        defer { CVPixelBufferUnlockBaseAddress(destination, []) }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let address = CVPixelBufferGetBaseAddress(destination),
              let canvas = CGContext(data: address, width: width, height: height, bitsPerComponent: 8,
                                     bytesPerRow: CVPixelBufferGetBytesPerRow(destination), space: space,
                                     bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { throw DepthWallpaperError.depthUnavailable }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        canvas.setFillColor(gray: 0, alpha: 1)
        canvas.fill(rect)
        canvas.interpolationQuality = .high
        canvas.draw(image, in: rect)
        return destination
    }

    private static func depthField(_ output: CVPixelBuffer) -> DepthField? {
        guard CVPixelBufferGetPixelFormatType(output) == kCVPixelFormatType_OneComponent16Half,
              CVPixelBufferLockBaseAddress(output, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(output, .readOnly) }
        guard let address = CVPixelBufferGetBaseAddress(output) else { return nil }
        let sourceWidth = CVPixelBufferGetWidth(output), sourceHeight = CVPixelBufferGetHeight(output)
        let ratio = min(1, 256.0 / Double(max(sourceWidth, sourceHeight)))
        let width = Int(Double(sourceWidth) * ratio), height = Int(Double(sourceHeight) * ratio)
        guard width > 1, height > 1 else { return nil }
        let row = CVPixelBufferGetBytesPerRow(output) / MemoryLayout<Float16>.stride
        let pixels = address.assumingMemoryBound(to: Float16.self)
        let values = (0..<(width * height)).map { index in
            let y = (index / width) * sourceHeight / height
            let x = (index % width) * sourceWidth / width
            return Float(pixels[y * row + x])
        }
        return DepthField(width: width, height: height, values: values)
    }
}
