import CoreImage
import CoreGraphics

/// Clearly labeled, deterministic generated footage. This is not a real specimen or a camera test.
public final class DemoSource {
    private let base: CIImage
    public init() {
        let width = 1920, height = 1080
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.09, green: 0.17, blue: 0.2, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        var seed: UInt64 = 42
        func random() -> Double { seed = seed &* 6364136223846793005 &+ 1; return Double(seed >> 32) / Double(UInt32.max) }
        for row in -1..<14 { for col in -1..<23 {
            let x = Double(col) * 96 + Double(row % 2) * 48 + random() * 12
            let y = Double(row) * 94 + random() * 16
            let rect = CGRect(x: x, y: y, width: 70 + random() * 20, height: 66 + random() * 20)
            context.setFillColor(CGColor(red: 0.18 + random() * 0.12, green: 0.42 + random() * 0.2, blue: 0.38 + random() * 0.2, alpha: 1)); context.fillEllipse(in: rect)
            context.setStrokeColor(CGColor(red: 0.63, green: 0.82, blue: 0.68, alpha: 0.6)); context.setLineWidth(3); context.strokeEllipse(in: rect)
            context.setFillColor(CGColor(red: 0.1, green: 0.25, blue: 0.26, alpha: 1)); context.fillEllipse(in: rect.insetBy(dx: 27, dy: 25))
            for _ in 0..<8 { context.setFillColor(CGColor(gray: 0.8, alpha: 0.25)); context.fillEllipse(in: CGRect(x: x + random() * 65, y: y + random() * 60, width: 3, height: 3)) }
        } }
        base = CIImage(cgImage: context.makeImage()!)
    }
    public func frame(at time: Double) -> CIImage {
        let x = sin(time * 13) * 4 + sin(time * 2) * 12
        let y = cos(time * 11) * 3 + sin(time * 1.7) * 8
        return base.clampedToExtent().transformed(by: CGAffineTransform(translationX: x, y: y)).cropped(to: base.extent)
    }
}
