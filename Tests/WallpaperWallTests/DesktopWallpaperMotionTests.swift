import AppKit
import ImageIO
import MetalKit
import Testing
import UniformTypeIdentifiers
@testable import WallpaperWall

struct DesktopWallpaperMotionTests {
    @Test func depthRejectsFlatMapsAndKeepsNearAndFarDistinct() throws {
        #expect(DepthField(width: 20, height: 10, values: Array(repeating: 1, count: 200)) == nil)
        let values: [Float] = (0..<200).map { $0 % 20 < 10 ? 0.1 : 1 }
        let depth = try #require(DepthField(width: 20, height: 10, values: values))
        #expect(depth.pixels[2] < 24)
        #expect(depth.pixels[17] > 230)
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    @MainActor func metalPreservesJPEGColors() throws {
        let context = try canvas(width: 128, height: 64)
        context.setFillColor(red: 0.78, green: 0.39, blue: 0.22, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        context.setFillColor(red: 0.20, green: 0.56, blue: 0.76, alpha: 1)
        context.fill(CGRect(x: 64, y: 0, width: 64, height: 64))
        let photo = try #require(context.makeImage())
        let data = NSMutableData()
        let encoder = try #require(
            CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        )
        CGImageDestinationAddImage(encoder, photo, nil)
        try #require(CGImageDestinationFinalize(encoder))
        let source = try #require(CGImageSourceCreateWithData(data, nil))
        try assertMetalColors(decodedPhoto(source), locations: [(32, 32), (96, 32)])

        if let path = ProcessInfo.processInfo.environment["WALLPAPER_WALL_COLOR_TEST"] {
            let url = URL(fileURLWithPath: path)
            let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
            let image = try decodedPhoto(source)
            try assertMetalColors(image, locations: [
                (image.width / 5, image.height / 7),
                (image.width / 2, image.height / 3),
                (image.width * 4 / 5, image.height * 2 / 3)
            ])
        }
    }

    @MainActor private func assertMetalColors(_ photo: CGImage, locations: [(Int, Int)]) throws {
        let depth = try #require(DepthField(width: 2, height: 2, values: [0, 1, 0, 1]))
        let graphics = try DepthWallpaperGraphics()
        let textures = try graphics.textures(for: DepthWallpaperAsset(image: photo, depth: depth))
        let format = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb,
                                                               width: photo.width, height: photo.height, mipmapped: false)
        format.storageMode = .shared
        format.usage = .renderTarget
        let output = try #require(graphics.device.makeTexture(descriptor: format))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = output
        pass.colorAttachments[0].storeAction = .store
        let commands = try #require(graphics.queue.makeCommandBuffer())
        let encoder = try #require(commands.makeRenderCommandEncoder(descriptor: pass))
        graphics.encode(encoder, textures: textures, screenAspect: Float(photo.width) / Float(photo.height),
                        placement: .fill, camera: .zero, fill: SIMD4(0, 0, 0, 1))
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        #expect(commands.status == .completed)

        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        for (x, y) in locations {
            let pixel = try #require(photo.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
            let context = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            let expected = try #require(context.data).assumingMemoryBound(to: UInt8.self)
            var actual = [UInt8](repeating: 0, count: 4)
            actual.withUnsafeMutableBytes { bytes in
                if let address = bytes.baseAddress {
                    output.getBytes(address, bytesPerRow: 4, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
                }
            }
            #expect(abs(Int(actual[2]) - Int(expected[0])) <= 3)
            #expect(abs(Int(actual[1]) - Int(expected[1])) <= 3)
            #expect(abs(Int(actual[0]) - Int(expected[2])) <= 3)
        }
    }

    private func decodedPhoto(_ source: CGImageSource) throws -> CGImage {
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 4096
        ] as CFDictionary
        return try #require(CGImageSourceCreateThumbnailAtIndex(source, 0, options))
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    @MainActor func metalMovesCloseAndDistantPixelsInOppositeDirections() throws {
        let width = 400, height = 96
        let context = try canvas(width: width, height: height)
        context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill([CGRect(x: 90, y: 20, width: 12, height: 56), CGRect(x: 290, y: 20, width: 12, height: 56)])
        let photo = try #require(context.makeImage())
        let field: [Float] = (0..<1024).map { $0 % 64 < 32 ? 0 : 1 }
        let depth = try #require(DepthField(width: 64, height: 16, values: field))
        let graphics = try DepthWallpaperGraphics()
        let textures = try graphics.textures(for: DepthWallpaperAsset(image: photo, depth: depth))
        let description = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: width,
                                                                     height: height, mipmapped: false)
        description.storageMode = .shared
        description.usage = .renderTarget
        let output = try #require(graphics.device.makeTexture(descriptor: description))
        func positions(at time: Float) throws -> [Int] {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = output
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store
            let commands = try #require(graphics.queue.makeCommandBuffer())
            let encoder = try #require(commands.makeRenderCommandEncoder(descriptor: pass))
            graphics.encode(encoder, textures: textures, screenAspect: Float(width) / Float(height), placement: .fill,
                            camera: DepthWallpaperView.camera(at: time), fill: SIMD4(0, 0, 0, 1))
            encoder.endEncoding()
            commands.commit()
            commands.waitUntilCompleted()
            #expect(commands.status == .completed)
            var line = [UInt8](repeating: 0, count: width * 4)
            line.withUnsafeMutableBytes { bytes in
                if let address = bytes.baseAddress {
                    output.getBytes(address, bytesPerRow: width * 4,
                                    from: MTLRegionMake2D(0, height / 2, width, 1), mipmapLevel: 0)
                }
            }
            return [0..<(width / 2), (width / 2)..<width].compactMap { columns in
                let bright = columns.filter { line[$0 * 4 + 2] > 200 }
                #expect(bright.count >= 9)
                return bright.first
            }
        }
        let rest = try positions(at: 0)
        let moved = try positions(at: 2.4)
        #expect(rest == [90, 290])
        try #require(moved.count == 2)
        #expect(moved[0] <= rest[0] - 2)
        #expect(moved[1] >= rest[1] + 2)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WALLPAPER_WALL_DEPTH_TEST"] != nil))
    @MainActor func actualCoreMLWallpaperAnimatesAndStops() async throws {
        _ = NSApplication.shared
        let path = try #require(ProcessInfo.processInfo.environment["WALLPAPER_WALL_DEPTH_TEST"])
        let modelURL = URL(fileURLWithPath: path)
        let workspace = NSWorkspace.shared
        try #require(!workspace.accessibilityDisplayShouldReduceMotion)
        let screen = try #require(NSScreen.screens.first)
        let previous = try #require(workspace.desktopImageURL(for: screen))
        let options = try #require(workspace.desktopImageOptions(for: screen))
        try #require(previous.isFileURL && !previous.path.hasPrefix("/System/"))
        try #require(["jpg", "jpeg", "png"].contains(previous.pathExtension.lowercased()))
        try #require(FileManager.default.isReadableFile(atPath: previous.path))
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file: URL
        if let photo = ProcessInfo.processInfo.environment["WALLPAPER_WALL_COLOR_TEST"] {
            file = URL(fileURLWithPath: photo)
            try #require(FileManager.default.isReadableFile(atPath: file.path))
        } else {
            file = root.appending(path: "景深实机测试.png")
            try saveScene(to: file)
        }
        let id = DesktopService.id(for: screen)
        let desktop = DesktopService()
        let motion = LiveDesktopWallpaper(loader: DepthWallpaperLoader(modelURL: modelURL))
        defer {
            motion.stopAll()
            if workspace.desktopImageURL(for: screen)?.standardizedFileURL != previous.standardizedFileURL {
                try? workspace.setDesktopImageURL(previous, for: screen, options: options)
            }
        }
        let result = await desktop.apply(file, to: [id], placement: .fill, backdrop: .black)
        #expect(result.successful == 1)
        motion.play(file, on: [id], placement: .fill, backdrop: .black)
        for _ in 0..<200 {
            if motion.submittedFrames >= 15 || (!motion.isPreparing && !motion.isEnabled) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(motion.message == "已开启 2.5D 动态壁纸")
        #expect(motion.submittedFrames >= 15)
        let panel = try #require(NSApp.windows.first { $0.level == .liveWallpaper && $0.isVisible })
        #expect(panel.ignoresMouseEvents && !panel.canBecomeKey)
        #expect(panel.level.rawValue < Int(CGWindowLevelForKey(.desktopIconWindow)))
        workspace.notificationCenter.post(name: NSWorkspace.screensDidSleepNotification, object: workspace)
        #expect(!panel.isVisible)
        let paused = motion.submittedFrames
        try await Task.sleep(for: .milliseconds(200))
        #expect(motion.submittedFrames == paused)
        workspace.notificationCenter.post(name: NSWorkspace.screensDidWakeNotification, object: workspace)
        #expect(panel.isVisible)
        motion.stopAll()
        #expect(!motion.isEnabled && !panel.isVisible)
        #expect(desktop.current(on: id)?.standardizedFileURL == file.standardizedFileURL)
        #expect(await desktop.restore(result.previous).successful == 1)
        for _ in 0..<20 {
            if desktop.current(on: id)?.standardizedFileURL == previous.standardizedFileURL { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(desktop.current(on: id)?.standardizedFileURL == previous.standardizedFileURL)
    }

    private func canvas(width: Int, height: Int) throws -> CGContext {
        try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                               space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    }

    private func saveScene(to file: URL) throws {
        let context = try canvas(width: 1920, height: 1280)
        context.setFillColor(red: 0.53, green: 0.71, blue: 0.86, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 1920, height: 1280))
        context.setFillColor(red: 0.18, green: 0.36, blue: 0.32, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 1920, height: 580))
        context.setFillColor(red: 0.72, green: 0.62, blue: 0.45, alpha: 1)
        context.addLines(between: [CGPoint(x: 250, y: 0), CGPoint(x: 1640, y: 0),
                                   CGPoint(x: 960, y: 600), CGPoint(x: 910, y: 600)])
        context.fillPath()
        for index in 0..<7 {
            let size = Double(8 - index) * 50
            context.setFillColor(red: 0.12, green: 0.23 + Double(index) * 0.035, blue: 0.18, alpha: 1)
            context.fillEllipse(in: CGRect(x: 44 + Double(index) * 110, y: 260 + Double(index) * 42,
                                           width: size, height: size * 1.6))
        }
        let image = try #require(context.makeImage())
        let encoder = try #require(CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(encoder, image, nil)
        try #require(CGImageDestinationFinalize(encoder))
    }
}
