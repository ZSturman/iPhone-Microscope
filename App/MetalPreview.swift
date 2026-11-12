import SwiftUI
import MetalKit
import CoreImage

struct MetalPreview: NSViewRepresentable {
    var image: CIImage?
    var reference: CIImage?
    var comparing: Bool
    var measuring: Bool
    var selectingWorkArea: Bool
    var onWorkArea: (CGPoint, CGPoint) -> Void
    var onZoom: (Double, CGPoint) -> Void
    var onPan: (CGSize) -> Void
    var onMeasure: (CGPoint, CGPoint) -> Void
    func makeNSView(context: Context) -> PreviewView { PreviewView() }
    func updateNSView(_ view: PreviewView, context: Context) {
        view.selectingWorkArea = selectingWorkArea; view.onWorkArea = onWorkArea
        view.image = image; view.reference = comparing ? reference : nil; view.measuring = measuring
        view.onZoom = onZoom; view.onPan = onPan; view.onMeasure = onMeasure
        view.needsDisplay = true
    }
}

final class PreviewView: MTKView, MTKViewDelegate {
    var image: CIImage?
    var reference: CIImage?
    var selectingWorkArea = false
    var onWorkArea: ((CGPoint, CGPoint) -> Void)?
    var measuring = false
    var onZoom: ((Double, CGPoint) -> Void)?
    var onPan: ((CGSize) -> Void)?
    var onMeasure: ((CGPoint, CGPoint) -> Void)?
    private let selectionLayer = CAShapeLayer()
    private var start = CGPoint.zero
    private var last = CGPoint.zero
    private let ciContext: CIContext
    private let commands: MTLCommandQueue?
    override var acceptsFirstResponder: Bool { true }
    init() {
        let device = MTLCreateSystemDefaultDevice()
        ciContext = device.map { CIContext(mtlDevice: $0, options: [.cacheIntermediates: false]) } ?? CIContext()
        commands = device?.makeCommandQueue()
        super.init(frame: .zero, device: device)
        wantsLayer = true; selectionLayer.strokeColor = NSColor.systemTeal.cgColor; selectionLayer.fillColor = NSColor.systemTeal.withAlphaComponent(0.12).cgColor; selectionLayer.lineWidth = 2; layer?.addSublayer(selectionLayer)
        framebufferOnly = false; colorPixelFormat = .bgra8Unorm
        isPaused = true; enableSetNeedsDisplay = true; delegate = self
        setAccessibilityLabel("Microscope image. Scroll or pinch to zoom; drag to pan or measure.")
    }
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    private var imageRect: CGRect {
        guard let image, image.extent.width > 0 else { return bounds }
        let scale = min(bounds.width / image.extent.width, bounds.height / image.extent.height)
        let size = CGSize(width: image.extent.width * scale, height: image.extent.height * scale)
        return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }
    private func normalized(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil), rect = imageRect
        return CGPoint(x: min(1, max(0, (point.x - rect.minX) / max(1, rect.width))), y: min(1, max(0, (point.y - rect.minY) / max(1, rect.height))))
    }
    override func scrollWheel(with event: NSEvent) { onZoom?(exp(Double(event.scrollingDeltaY) * 0.018), normalized(event)) }
    override func magnify(with event: NSEvent) { onZoom?(max(0.1, 1 + event.magnification), normalized(event)) }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        guard imageRect.contains(p) else { return }
        start = normalized(event); last = start
        if measuring { onMeasure?(start, start) }
    }
    override func mouseDragged(with event: NSEvent) {
        let current = normalized(event)
        if selectingWorkArea {
            let rect = imageRect
            let area = CGRect(x: rect.minX + min(start.x, current.x) * rect.width, y: rect.minY + min(start.y, current.y) * rect.height, width: abs(start.x - current.x) * rect.width, height: abs(start.y - current.y) * rect.height)
            selectionLayer.path = CGPath(rect: area, transform: nil); return
        }
        if measuring { onMeasure?(start, current) }
        else { onPan?(CGSize(width: current.x - last.x, height: current.y - last.y)) }
        last = current
    }
    override func mouseUp(with event: NSEvent) { selectionLayer.path = nil; if selectingWorkArea { onWorkArea?(start, normalized(event)) } }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    func draw(in view: MTKView) {
        guard let drawable = currentDrawable, let command = commands?.makeCommandBuffer() else { return }
        let rect = CGRect(origin: .zero, size: drawableSize)
        var output = CIImage(color: .black).cropped(to: rect)
        if var image {
            if let reference {
                let s = image.extent.size
                let scaled = reference.transformed(by: CGAffineTransform(scaleX: s.width / reference.extent.width, y: s.height / reference.extent.height))
                image = scaled.cropped(to: CGRect(x: 0, y: 0, width: s.width / 2, height: s.height)).composited(over: image)
            }
            let scale = min(rect.width / image.extent.width, rect.height / image.extent.height)
            let display = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)).transformed(by: CGAffineTransform(translationX: (rect.width - image.extent.width * scale) / 2, y: (rect.height - image.extent.height * scale) / 2))
            output = display.composited(over: output)
        }
        ciContext.render(output, to: drawable.texture, commandBuffer: command, bounds: rect, colorSpace: CGColorSpaceCreateDeviceRGB())
        command.present(drawable); command.commit()
    }
}

struct MicroscopeOverlays: View {
    @ObservedObject var model: AppModel
    var body: some View {
        GeometryReader { geometry in
            let size = model.image?.extent.size ?? CGSize(width: 16, height: 9)
            let scale = min(geometry.size.width / size.width, geometry.size.height / size.height)
            let width = size.width * scale, height = size.height * scale
            let origin = CGPoint(x: (geometry.size.width - width) / 2, y: (geometry.size.height - height) / 2)
            Canvas { context, _ in
                let color = Color.white.opacity(0.65)
                if model.preferences.grid {
                    let spacing = max(20, model.preferences.gridSpacing)
                    var path = Path()
                    for x in stride(from: origin.x, through: origin.x + width, by: spacing) { path.move(to: CGPoint(x: x, y: origin.y)); path.addLine(to: CGPoint(x: x, y: origin.y + height)) }
                    for y in stride(from: origin.y, through: origin.y + height, by: spacing) { path.move(to: CGPoint(x: origin.x, y: y)); path.addLine(to: CGPoint(x: origin.x + width, y: y)) }
                    context.stroke(path, with: .color(color.opacity(0.4)), lineWidth: 0.5)
                }
                if model.preferences.crosshair {
                    let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
                    let r = model.preferences.crosshairSize
                    var path = Path(); path.move(to: CGPoint(x: center.x - r, y: center.y)); path.addLine(to: CGPoint(x: center.x + r, y: center.y))
                    path.move(to: CGPoint(x: center.x, y: center.y - r)); path.addLine(to: CGPoint(x: center.x, y: center.y + r))
                    context.stroke(path, with: .color(color), lineWidth: 1)
                }
                if let m = model.measurement {
                    let a = CGPoint(x: origin.x + m.a.x * width, y: origin.y + (1 - m.a.y) * height)
                    let b = CGPoint(x: origin.x + m.b.x * width, y: origin.y + (1 - m.b.y) * height)
                    var path = Path(); path.move(to: a); path.addLine(to: b)
                    context.stroke(path, with: .color(.yellow), lineWidth: 2)
                    for p in [a, b] { context.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)), with: .color(.yellow)) }
                    context.draw(Text(model.measurementLabel).font(.system(size: 12, weight: .semibold)).foregroundColor(.yellow), at: CGPoint(x: (a.x + b.x) / 2, y: max(origin.y + 16, min(a.y, b.y) - 16)))
                }
                if model.preferences.scaleBar, let calibration = model.activeCalibration, width > 100 {
                    let unitsPerPoint = model.displayedSourceSize.width * model.sourcePixelScale * calibration.micrometersPerPixel / width
                    let target = unitsPerPoint * min(150, width / 4)
                    let power = pow(10, floor(log10(max(1e-9, target))))
                    let nice = ([1.0, 2, 5, 10].last(where: { $0 * power <= target }) ?? 1) * power
                    let length = nice / unitsPerPoint
                    let a = CGPoint(x: origin.x + 24, y: origin.y + height - 30)
                    var path = Path(); path.move(to: a); path.addLine(to: CGPoint(x: a.x + length, y: a.y))
                    context.stroke(path, with: .color(.white), lineWidth: 3)
                    context.draw(Text(String(format: "%.3g µm", nice)).font(.system(size: 12, weight: .semibold)).foregroundColor(.white), at: CGPoint(x: a.x + length / 2, y: a.y - 14))
                }
                if model.comparing, model.reference != nil {
                    var path = Path(); path.move(to: CGPoint(x: geometry.size.width / 2, y: origin.y)); path.addLine(to: CGPoint(x: geometry.size.width / 2, y: origin.y + height))
                    context.stroke(path, with: .color(.white), lineWidth: 1)
                }
            }
        }.allowsHitTesting(false)
    }
}
