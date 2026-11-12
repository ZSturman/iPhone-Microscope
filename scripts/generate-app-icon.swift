import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Reproducible, opaque app artwork: a lens, crosshair and specimen stage.
let size = 1024
let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
    bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
context.setFillColor(CGColor(red: 0.035, green: 0.09, blue: 0.14, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: size, height: size))
let cyan = CGColor(red: 0.21, green: 0.79, blue: 0.83, alpha: 1)
context.setStrokeColor(cyan)
context.setLineWidth(42)
context.strokeEllipse(in: CGRect(x: 220, y: 275, width: 584, height: 584))
context.setStrokeColor(CGColor(gray: 1, alpha: 1))
context.setLineWidth(18)
context.setLineCap(.round)
for (x1,y1,x2,y2) in [(512.0,366.0,512.0,460.0),(512,674,512,768),(311,567,405,567),(619,567,713,567)] {
    context.move(to: CGPoint(x: x1, y: y1))
    context.addLine(to: CGPoint(x: x2, y: y2))
}
context.strokePath()
context.setFillColor(cyan)
context.fillEllipse(in: CGRect(x: 484, y: 539, width: 56, height: 56))
context.addPath(CGPath(roundedRect: CGRect(x: 292, y: 164, width: 440, height: 34),
    cornerWidth: 17, cornerHeight: 17, transform: nil))
context.fillPath()
let output = URL(fileURLWithPath: CommandLine.arguments[1])
let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, context.makeImage()!, nil)
precondition(CGImageDestinationFinalize(destination), "Could not write app icon")
