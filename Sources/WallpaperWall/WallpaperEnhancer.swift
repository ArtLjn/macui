import CoreImage
import CoreImage.CIFilterBuiltins

struct WallpaperEnhancer {
    private let context = CIContext(options: [.cacheIntermediates: false])

    func render(_ image: CGImage) throws -> CGImage {
        let source = CIImage(cgImage: image)
        let denoise = CIFilter.noiseReduction()
        denoise.inputImage = source.clampedToExtent()
        denoise.noiseLevel = 0.009
        denoise.sharpness = 0.25
        let sharpen = CIFilter.sharpenLuminance()
        sharpen.inputImage = denoise.outputImage
        sharpen.sharpness = 0.38
        guard let output = sharpen.outputImage,
              let colorSpace = image.colorSpace.flatMap({ $0.model == .rgb ? $0 : nil })
                ?? CGColorSpace(name: CGColorSpace.sRGB),
              let result = context.createCGImage(
                output.cropped(to: source.extent), from: source.extent, format: .RGBA8, colorSpace: colorSpace
              )
        else { throw WallpaperError.enhancementFailed }
        return result
    }
}
