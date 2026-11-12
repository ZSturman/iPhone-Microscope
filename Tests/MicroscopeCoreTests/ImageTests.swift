import XCTest
import CoreImage
import Vision
@testable import MicroscopeCore

final class ImageTests: XCTestCase {
    let context = CIContext()
    func pixel(_ image: CIImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 4)
        context.render(image, toBitmap: &bytes, rowBytes: 4, bounds: CGRect(x: image.extent.midX, y: image.extent.midY, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!)
        return bytes
    }
    func testGrayscaleInversionAndRotation() {
        let source = CIImage(color: CIColor(red: 0.2, green: 0.6, blue: 0.8)).cropped(to: CGRect(x: 0, y: 0, width: 320, height: 180))
        var settings = ImageSettings(); settings.grayscale = true; settings.rotation = 1; settings.flipH = true
        let output = ImageProcessor.adjust(source, settings: settings)
        XCTAssertEqual(output.extent.width, 180, accuracy: 0.001); XCTAssertEqual(output.extent.height, 320, accuracy: 0.001)
        let gray = pixel(output); XCTAssertLessThan(abs(Int(gray[0]) - Int(gray[1])), 2); XCTAssertLessThan(abs(Int(gray[1]) - Int(gray[2])), 2)
        settings.inverted = true
        let inverse = pixel(ImageProcessor.adjust(source, settings: settings))
        XCTAssertEqual(Int(gray[0]) + Int(inverse[0]), 255, accuracy: 3)
    }
    func testFeaturelessFallbackAndZoomExtent() {
        let p = ImageProcessor(), source = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 480))
        var settings = PipelineSettings(); settings.viewport.zoom(to: 4)
        _ = p.process(source, settings: settings)
        let frame = p.process(source, settings: settings)
        XCTAssertTrue(frame.tracking.contains("Low texture")); XCTAssertEqual(frame.focus, 0, accuracy: 0.001)
        XCTAssertEqual(frame.image.extent.width, 640, accuracy: 0.001)
        XCTAssertEqual(pixel(frame.image)[3], 255)
    }
    func testVisionTranslationDirectionAndTracking() throws {
        let demo = DemoSource(), p = ImageProcessor()
        let source = demo.frame(at: 0)
        let next = source.clampedToExtent().transformed(by: CGAffineTransform(translationX: 15, y: -8)).cropped(to: source.extent)
        let reference = context.createCGImage(source, from: source.extent)!
        let current = context.createCGImage(next, from: next.extent)!
        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: reference)
        try VNImageRequestHandler(cgImage: current).perform([request])
        let alignment = try XCTUnwrap(request.results?.first as? VNImageTranslationAlignmentObservation)
        XCTAssertEqual(alignment.alignmentTransform.tx, 15, accuracy: 1)
        XCTAssertEqual(alignment.alignmentTransform.ty, -8, accuracy: 1)
        _ = p.process(source, settings: PipelineSettings())
        let frame = p.process(next, settings: PipelineSettings())
        XCTAssertEqual(frame.tracking, "Tracking")
        XCTAssertGreaterThan(frame.focus, 0)
    }
    func testStabilizationActuallyReducesImageDisplacement() throws {
        let demo = DemoSource(), p = ImageProcessor()
        var settings = PipelineSettings(); settings.stabilization = .high; settings.lock = true
        let source = demo.frame(at: 0)
        let first = p.process(source, settings: settings).image
        let shifted = source.clampedToExtent().transformed(by: CGAffineTransform(translationX: 24, y: 12)).cropped(to: source.extent)
        let output = p.process(shifted, settings: settings)
        XCTAssertEqual(output.tracking, "Subject lock")
        let reference = context.createCGImage(first, from: first.extent)!
        let current = context.createCGImage(output.image, from: output.image.extent)!
        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: reference)
        try VNImageRequestHandler(cgImage: current).perform([request])
        let alignment = try XCTUnwrap(request.results?.first as? VNImageTranslationAlignmentObservation)
        XCTAssertLessThan(abs(alignment.alignmentTransform.tx), 3)
        XCTAssertLessThan(abs(alignment.alignmentTransform.ty), 3)
    }
    func testFrozenBaseCanBeAdjustedWithoutMotionEstimation() {
        let processor = ImageProcessor(), source = DemoSource().frame(at: 0)
        let frozen = processor.process(source, settings: PipelineSettings()).stabilized
        var settings = PipelineSettings(); settings.image.grayscale = true; settings.viewport.zoom(to: 3)
        settings.image.rotation = 1
        let presented = ImageProcessor.present(frozen, settings: settings)
        XCTAssertEqual(presented.extent.width, 1080, accuracy: 0.001)
        XCTAssertEqual(presented.extent.height, 1920, accuracy: 0.001)
        let sample = pixel(presented)
        XCTAssertLessThan(abs(Int(sample[0]) - Int(sample[1])), 2)
        XCTAssertEqual(sample[3], 255)
    }
    func testUnrelatedTexturedFrameIsRejected() {
        let processor = ImageProcessor(), source = DemoSource().frame(at: 0)
        _ = processor.process(source, settings: PipelineSettings())
        let unrelated = source.transformed(by: CGAffineTransform(rotationAngle: .pi)).transformed(by: CGAffineTransform(translationX: 1920, y: 1080))
        let output = processor.process(unrelated, settings: PipelineSettings())
        XCTAssertNotEqual(output.tracking, "Tracking")
    }
    private func pixels(_ image: CIImage) -> [UInt8] {
        let width = Int(image.extent.width), height = Int(image.extent.height)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        context.render(image, toBitmap: &bytes, rowBytes: width * 4, bounds: image.extent, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return bytes
    }
    private func redPixels(_ image: CIImage) -> Int {
        let bytes = pixels(image)
        return stride(from: 0, to: bytes.count, by: 4).filter { bytes[$0] > 200 && bytes[$0 + 1] < 90 && bytes[$0 + 2] < 90 }.count
    }
    func testPeakingHighlightsSharpEdgesButKeepsCaptureClean() {
        let extent = CGRect(x: 0, y: 0, width: 160, height: 96)
        let flat = CIImage(color: .gray).cropped(to: extent)
        let stripe = CIImage(color: .white).cropped(to: CGRect(x: 64, y: 0, width: 32, height: 96)).composited(over: CIImage(color: .black).cropped(to: extent))
        var settings = PipelineSettings(); settings.stabilization = .off
        settings.peaking = FocusPeakingSettings(); settings.peaking?.enabled = true
        XCTAssertEqual(redPixels(ImageProcessor.preview(flat, settings: settings)), 0)
        let sharp = redPixels(ImageProcessor.preview(stripe, settings: settings))
        let blurred = stripe.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 12]).cropped(to: extent)
        XCTAssertGreaterThan(sharp, 0)
        XCTAssertLessThan(redPixels(ImageProcessor.preview(blurred, settings: settings)), sharp)
        let frame = ImageProcessor().process(stripe, settings: settings)
        XCTAssertGreaterThan(redPixels(frame.preview), 0)
        XCTAssertEqual(redPixels(frame.image), 0)
        settings.peaking?.enabled = false
        XCTAssertEqual(pixels(frame.image), pixels(ImageProcessor.present(stripe, settings: settings)))
        settings.peaking?.enabled = true; settings.image.rotation = 1; settings.image.flipH = true; settings.viewport.zoom(to: 2)
        let rotated = ImageProcessor.preview(stripe, settings: settings)
        XCTAssertEqual(rotated.extent.size, CGSize(width: 96, height: 160))
        XCTAssertGreaterThan(redPixels(rotated), 0)
    }
    func testPeakingRemainsVisibleOnGeneratedDetail() {
        var settings = PipelineSettings(); settings.stabilization = .off
        settings.peaking = FocusPeakingSettings(); settings.peaking?.enabled = true
        let image = DemoSource().frame(at: 0)
        XCTAssertGreaterThan(redPixels(ImageProcessor.preview(image, settings: settings)), 100)
    }
    func testWorkAreaDimsOutsideAndDoesNotAffectCaptures() {
        let image = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 100, height: 100))
        var settings = PipelineSettings(); settings.workArea = WorkAreaSettings()
        let preview = ImageProcessor.preview(image, settings: settings)
        XCTAssertEqual(pixel(preview)[0], 255)
        let bytes = pixels(preview)
        XCTAssertLessThan(bytes[0], 200)
        XCTAssertEqual(pixels(ImageProcessor.present(image, settings: settings))[0], 255)
    }
    func testNewPeakingSettingPreservesExistingPreferences() throws {
        var saved = Preferences(); saved.outputPath = "/tmp/retained-captures"; saved.pipeline.viewport.zoom(to: 3)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        var pipeline = try XCTUnwrap(json["pipeline"] as? [String: Any]); pipeline.removeValue(forKey: "peaking"); json["pipeline"] = pipeline
        let loaded = try JSONDecoder().decode(Preferences.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(loaded.outputPath, saved.outputPath)
        XCTAssertEqual(loaded.pipeline.viewport.zoom, 3)
        XCTAssertNil(loaded.pipeline.peaking)
    }
    func testSnapshotEncoding() throws {
        let image = DemoSource().frame(at: 0)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let png = directory.appendingPathComponent("test.png"), jpeg = directory.appendingPathComponent("test.jpg")
        try context.writePNGRepresentation(of: image, to: png, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        try context.writeJPEGRepresentation(of: image, to: jpeg, colorSpace: CGColorSpaceCreateDeviceRGB())
        for url in [png, jpeg] { let decoded = try XCTUnwrap(CIImage(contentsOf: url)); XCTAssertEqual(decoded.extent.size, CGSize(width: 1920, height: 1080)) }
    }
}
