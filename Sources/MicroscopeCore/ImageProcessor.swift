import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Metal
import Vision

public final class ImageProcessor {
    public let context: CIContext
    private var previous: CGImage?
    private var previousLuma: [Float] = []
    private var previousSize = CGSize.zero
    private var smoother = MotionSmoother()
    private var priorStrength: StabilizationStrength = .off
    private var priorLock = false
    public init() {
        if let device = MTLCreateSystemDefaultDevice() {
            context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        } else { context = CIContext(options: [.cacheIntermediates: false]) }
    }
    public func reset() { previous = nil; previousLuma = []; smoother.reset() }

    public func process(_ input: CIImage, settings: PipelineSettings) -> ProcessedFrame {
        let size = input.extent.size
        if size != previousSize || priorStrength != settings.stabilization || priorLock != settings.lock { reset() }
        previousSize = size; priorStrength = settings.stabilization; priorLock = settings.lock
        let analysis = input.transformed(by: CGAffineTransform(scaleX: 512 / size.width, y: 512 / size.width))
        let rect = CGRect(origin: .zero, size: CGSize(width: 512, height: max(1, (size.height * 512 / size.width).rounded())))
        var rgba = [UInt8](repeating: 0, count: Int(rect.width * rect.height) * 4)
        context.render(analysis, toBitmap: &rgba, rowBytes: Int(rect.width) * 4, bounds: rect, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        let luma = stride(from: 0, to: rgba.count, by: 4).map { (Float(rgba[$0]) * 0.2126 + Float(rgba[$0 + 1]) * 0.7152 + Float(rgba[$0 + 2]) * 0.0722) / 255 }
        let w = Int(rect.width), h = Int(rect.height)
        let mean = luma.reduce(0, +) / Float(luma.count)
        let variance = luma.reduce(Float(0)) { $0 + ($1 - mean) * ($1 - mean) } / Float(luma.count)
        var gradient: Float = 0
        if h > 2 {
            for y in 1..<(h - 1) { for x in 1..<(w - 1) {
                let i = y * w + x
                gradient += abs(luma[i + 1] - luma[i - 1]) + abs(luma[i + w] - luma[i - w])
            } }
        }
        let focus = min(100, Double(gradient) / Double(max(1, (w - 2) * (h - 2))) * 500)
        var translation: CGPoint?
        var status = settings.stabilization == .off ? "Off" : "Acquiring"
        if settings.stabilization != .off, let current = context.createCGImage(analysis, from: rect) {
            if let previous, variance > 0.001 {
                let request = VNTranslationalImageRegistrationRequest(targetedCGImage: previous)
                do {
                    try VNImageRequestHandler(cgImage: current).perform([request])
                    if let observation = request.results?.first as? VNImageTranslationAlignmentObservation {
                        // Vision aligns the targeted reference to the handler image; invert for compensation.
                        let t = observation.alignmentTransform
                        // Verify registration with normalized image correlation; confidence alone is insufficient on featureless frames.
                        let quality = Self.correlation(reference: previousLuma, current: luma, width: w, height: h, dx: Int((-t.tx).rounded()), dy: Int(t.ty.rounded()))
                        if observation.confidence >= 0.3 && abs(t.tx) < rect.width * 0.12 && abs(t.ty) < rect.height * 0.12 && quality > 0.65 {
                            translation = CGPoint(x: -t.tx * size.width / rect.width, y: -t.ty * size.width / rect.width)
                            status = settings.lock ? "Subject lock" : "Tracking"
                        } else { status = "Unreliable · releasing" }
                    }
                } catch { status = "Tracking unavailable" }
            } else if previous != nil { status = "Low texture · releasing" }
            self.previous = current; previousLuma = luma
        }
        let margin = settings.stabilization.margin
        let offset = smoother.update(translation: translation, strength: settings.stabilization, locked: settings.lock,
                                     limit: CGSize(width: size.width * margin, height: size.height * margin))
        var image = input
        if margin > 0 {
            image = image.transformed(by: CGAffineTransform(translationX: offset.x, y: offset.y))
            let crop = input.extent.insetBy(dx: size.width * margin, dy: size.height * margin)
            image = image.cropped(to: crop).transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
                .transformed(by: CGAffineTransform(scaleX: 1 / (1 - 2 * margin), y: 1 / (1 - 2 * margin)))
        }
        let presented = Self.present(image, settings: settings)
        let preview = (settings.peaking?.enabled == true || settings.workArea != nil) ? Self.preview(image, settings: settings) : presented
        return ProcessedFrame(image: presented, preview: preview, stabilized: image, source: input, focus: focus, tracking: status, margin: margin)
    }

    /// Viewer-only focus aid. Analyze before software sharpening, then apply exactly the
    /// same rotation, mirror and viewport to the mask as to the clean capture image.
    public static func preview(_ stabilized: CIImage, settings: PipelineSettings) -> CIImage {
        let original = present(stabilized, settings: settings)
        var clean = original
        var workMask: CIImage?
        if let area = settings.workArea {
            let extent = original.extent
            let selected = CGRect(x: area.x * extent.width, y: area.y * extent.height, width: area.width * extent.width, height: area.height * extent.height).intersection(extent)
            let mask = CIImage(color: .white).cropped(to: selected).composited(over: CIImage(color: .black).cropped(to: extent))
            let dim = original.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: -2])
            clean = original.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: dim, kCIInputMaskImageKey: mask])
            workMask = mask
        }
        guard let peaking = settings.peaking, peaking.enabled else { return clean }
        let sensitivity = peaking.sensitivity.isFinite ? min(1, max(0, peaking.sensitivity)) : 0.5
        let extent = stabilized.extent
        let edges = stabilized.clampedToExtent()
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
            .applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: 1])
            .applyingFilter("CIColorThreshold", parameters: ["inputThreshold": 0.09 - sensitivity * 0.08])
            .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: 1.5])
            .cropped(to: extent)
        var maskSettings = settings
        maskSettings.image = ImageSettings()
        maskSettings.image.rotation = settings.image.rotation
        maskSettings.image.flipH = settings.image.flipH
        maskSettings.image.flipV = settings.image.flipV
        var mask = present(edges, settings: maskSettings)
        if let workMask { mask = mask.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: workMask]) }
        let red = CIImage(color: CIColor(red: 1, green: 0.08, blue: 0.12)).cropped(to: clean.extent)
        return red.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: clean, kCIInputMaskImageKey: mask]).cropped(to: clean.extent)
    }

    public static func present(_ stabilized: CIImage, settings: PipelineSettings) -> CIImage {
        var image = Self.adjust(stabilized, settings: settings.image)
        let orientedSize = image.extent.size
        let crop = settings.viewport.crop(in: orientedSize)
        image = image.cropped(to: crop).transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
            .transformed(by: CGAffineTransform(scaleX: settings.viewport.zoom, y: settings.viewport.zoom))
            .cropped(to: CGRect(origin: .zero, size: orientedSize))
        return image
    }

    public static func adjust(_ input: CIImage, settings: ImageSettings) -> CIImage {
        var image = input.applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: settings.brightness, kCIInputContrastKey: settings.contrast, kCIInputSaturationKey: settings.grayscale ? 0 : settings.saturation])
        if settings.exposure != 0 { image = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: settings.exposure]) }
        if settings.temperature != 6500 {
            image = image.applyingFilter("CITemperatureAndTint", parameters: ["inputNeutral": CIVector(x: settings.temperature, y: 0), "inputTargetNeutral": CIVector(x: 6500, y: 0)])
        }
        if settings.sharpness > 0 { image = image.clampedToExtent().applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: settings.sharpness]).cropped(to: input.extent) }
        if settings.inverted { image = image.applyingFilter("CIColorInvert") }
        let turns = ((settings.rotation % 4) + 4) % 4
        if turns != 0 { image = image.transformed(by: CGAffineTransform(rotationAngle: Double(turns) * .pi / 2)) }
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        if settings.flipH { image = image.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: image.extent.width, ty: 0)) }
        if settings.flipV { image = image.transformed(by: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: image.extent.height)) }
        return image
    }

    static func correlation(reference: [Float], current: [Float], width: Int, height: Int, dx: Int, dy: Int) -> Double {
        guard reference.count == current.count, current.count == width * height else { return 0 }
        var a: Double = 0, b: Double = 0, aa: Double = 0, bb: Double = 0, ab: Double = 0, n: Double = 0
        // Core Image bitmap rows run top-to-bottom, so bitmap Y has the opposite sign from Vision image Y.
        for y in stride(from: 16, to: height - 16, by: 3) { for x in stride(from: 16, to: width - 16, by: 3) {
            let rx = x + dx, ry = y + dy
            guard rx >= 0, rx < width, ry >= 0, ry < height else { continue }
            let u = Double(current[y * width + x]), v = Double(reference[ry * width + rx])
            a += u; b += v; aa += u * u; bb += v * v; ab += u * v; n += 1
        } }
        guard n > 20 else { return 0 }
        return (ab - a * b / n) / max(1e-10, sqrt(max(0, (aa - a * a / n) * (bb - b * b / n))))
    }
}

public struct ProcessedFrame {
    public let image: CIImage
    public let preview: CIImage
    public let stabilized: CIImage
    public let source: CIImage
    public let focus: Double
    public let tracking: String
    public let margin: Double
}
