import MetalKit
import QuartzCore

@MainActor
final class DepthWallpaperGraphics {
    let device: any MTLDevice
    let queue: any MTLCommandQueue
    let pipeline: any MTLRenderPipelineState
    static let pixelFormat: MTLPixelFormat = .bgra8Unorm_srgb

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw DepthWallpaperError.rendererUnavailable
        }
        let shaders = try device.makeLibrary(source: Self.shaders, options: nil)
        let description = MTLRenderPipelineDescriptor()
        description.vertexFunction = shaders.makeFunction(name: "wallpaperVertex")
        description.fragmentFunction = shaders.makeFunction(name: "wallpaperFragment")
        description.colorAttachments[0].pixelFormat = Self.pixelFormat
        self.device = device
        self.queue = queue
        pipeline = try device.makeRenderPipelineState(descriptor: description)
    }

    struct Textures {
        let image: any MTLTexture
        let depth: any MTLTexture
    }

    private struct Uniforms {
        let geometry: SIMD4<Float>
        let motion: SIMD4<Float>
        let fill: SIMD4<Float>
    }

    func textures(for asset: DepthWallpaperAsset) throws -> Textures {
        let imageFormat = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.pixelFormat, width: asset.width,
                                                                    height: asset.height, mipmapped: false)
        imageFormat.usage = .shaderRead
        guard let image = device.makeTexture(descriptor: imageFormat) else {
            throw DepthWallpaperError.rendererUnavailable
        }
        asset.bgra.withUnsafeBytes { bytes in
            guard let address = bytes.baseAddress else { return }
            image.replace(region: MTLRegionMake2D(0, 0, asset.width, asset.height), mipmapLevel: 0,
                          withBytes: address, bytesPerRow: asset.width * 4)
        }
        let field = asset.depth
        let description = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: field.width,
                                                                     height: field.height, mipmapped: false)
        description.usage = .shaderRead
        guard let depth = device.makeTexture(descriptor: description) else {
            throw DepthWallpaperError.rendererUnavailable
        }
        field.pixels.withUnsafeBytes { bytes in
            guard let address = bytes.baseAddress else { return }
            depth.replace(region: MTLRegionMake2D(0, 0, field.width, field.height), mipmapLevel: 0,
                          withBytes: address, bytesPerRow: field.width)
        }
        return Textures(image: image, depth: depth)
    }

    func encode(_ encoder: any MTLRenderCommandEncoder, textures: Textures, screenAspect: Float,
                placement: Placement, camera: SIMD2<Float>, fill: SIMD4<Float>) {
        let imageAspect = Float(textures.image.width) / Float(textures.image.height)
        let x = min(1, screenAspect / imageAspect), y = min(1, imageAspect / screenAspect)
        let geometry = placement == .fill ? SIMD4(x, y, 1, 1) : SIMD4(1, 1, y, x)
        var uniforms = Uniforms(geometry: geometry, motion: SIMD4(camera.x, camera.y, 0, 0), fill: fill)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(textures.image, index: 0)
        encoder.setFragmentTexture(textures.depth, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }

    private static let shaders = """
        #include <metal_stdlib>
        using namespace metal;

        struct WallVertexOut {
            float4 position [[position]];
            float2 uv;
        };

        struct WallUniforms {
            float4 geometry;
            float4 motion;
            float4 fill;
        };

        vertex WallVertexOut wallpaperVertex(uint index [[vertex_id]]) {
            const float2 points[] = {{-1, -1}, {3, -1}, {-1, 3}};
            float2 point = points[index];
            return {float4(point, 0, 1), float2(point.x * 0.5 + 0.5, 0.5 - point.y * 0.5)};
        }

        fragment float4 wallpaperFragment(WallVertexOut pixel [[stage_in]],
                                         texture2d<float> image [[texture(0)]],
                                         texture2d<float> depth [[texture(1)]],
                                         constant WallUniforms& values [[buffer(0)]]) {
            constexpr sampler smoothImage(coord::normalized, address::clamp_to_edge, filter::linear);
            float2 local = (pixel.uv - 0.5) / values.geometry.zw + 0.5;
            if (any(local < 0) || any(local > 1)) return values.fill;
            float2 motion = values.motion.xy;
            float2 origin = (local - 0.5) * values.geometry.xy * (1 - abs(motion) * 1.05) + 0.5;
            float distance = depth.sample(smoothImage, origin).r;
            return image.sample(smoothImage, origin - motion * (distance - 0.5));
        }
        """
}

@MainActor
final class DepthWallpaperView: MTKView, MTKViewDelegate {
    private let graphics: DepthWallpaperGraphics
    private let textures: DepthWallpaperGraphics.Textures
    private let placement: Placement
    private let fill: SIMD4<Float>
    private var lastDraw: CFTimeInterval?
    private var elapsed: Float = 0
    private(set) var submittedFrames = 0

    init(graphics: DepthWallpaperGraphics, textures: DepthWallpaperGraphics.Textures, placement: Placement,
         backdrop: DesktopBackdrop) {
        self.graphics = graphics
        self.textures = textures
        self.placement = placement
        func linear(_ value: Double) -> Float {
            Float(value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4))
        }
        fill = SIMD4(linear(backdrop.red), linear(backdrop.green), linear(backdrop.blue), 1)
        super.init(frame: .zero, device: graphics.device)
        colorPixelFormat = DepthWallpaperGraphics.pixelFormat
        colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        preferredFramesPerSecond = 30
        (layer as? CAMetalLayer)?.maximumDrawableCount = 2
        autoResizeDrawable = false
        isPaused = true
        delegate = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("无法从归档恢复动态壁纸视图") }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        let size = convertToBacking(bounds).size
        guard size.width > 0, size.height > 0 else { return }
        let ratio = min(1, 4096 / max(size.width, size.height))
        drawableSize = CGSize(width: (size.width * ratio).rounded(), height: (size.height * ratio).rounded())
    }

    func setRunning(_ running: Bool) {
        guard isPaused == running else { return }
        lastDraw = nil
        isPaused = !running
        if running {
            updateDrawableSize()
        } else {
            releaseDrawables()
        }
    }

    static func camera(at elapsed: Float) -> SIMD2<Float> {
        let start = min(1, elapsed / 1.2)
        let entrance = start * start * (3 - 2 * start)
        return SIMD2(
            (sin(elapsed * 0.48) * 0.78 + sin(elapsed * 0.83) * 0.22) * DepthField.horizontalMotion * entrance,
            (sin(elapsed * 0.37) * 0.80 + sin(elapsed * 0.61) * 0.20) * DepthField.verticalMotion * entrance
        )
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let pass = currentRenderPassDescriptor, let drawable = currentDrawable,
              let commands = graphics.queue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        let now = CACurrentMediaTime()
        if let lastDraw { elapsed += Float(min(now - lastDraw, 0.06)) }
        lastDraw = now
        let screenAspect = Float(drawableSize.width / drawableSize.height)
        graphics.encode(encoder, textures: textures, screenAspect: screenAspect, placement: placement,
                        camera: Self.camera(at: elapsed), fill: fill)
        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
        submittedFrames += 1
    }
}
