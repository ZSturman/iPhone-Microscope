import XCTest
@testable import MicroscopeCore

final class GeometryTests: XCTestCase {
    func testCursorAnchoredZoomAndBounds() {
        var v = Viewport()
        v.zoom(to: 2, anchor: CGPoint(x: 0.75, y: 0.25))
        XCTAssertEqual(v.x, 0.625, accuracy: 0.0001); XCTAssertEqual(v.y, 0.375, accuracy: 0.0001)
        // A feature under the pointer stays at the same normalized screen coordinate.
        XCTAssertEqual(v.x + (0.75 - 0.5) / v.zoom, 0.75, accuracy: 0.0001)
        v.x = -100; v.y = 100; v.constrain()
        XCTAssertEqual(v.x, 0.25); XCTAssertEqual(v.y, 0.75)
        v.zoom(to: 1); XCTAssertEqual(v.x, 0.5); XCTAssertEqual(v.y, 0.5)
        v.zoom(to: 100); XCTAssertEqual(v.zoom, 20)
    }
    func testCalibrationMatchingAndInvalidValues() {
        XCTAssertNil(Calibration(name: "Bad", cameraID: "a", size: CGSize(width: 1920, height: 1080), opticalConfiguration: "Lens", pixels: 0, micrometers: 100))
        XCTAssertNil(Calibration(name: "Bad", cameraID: "a", size: CGSize(width: 1920, height: 1080), opticalConfiguration: "Lens", pixels: 50, micrometers: .nan))
        let profile = Calibration(name: "Stage", cameraID: "a", size: CGSize(width: 1920, height: 1080), opticalConfiguration: "Lens", pixels: 500, micrometers: 1000)!
        XCTAssertEqual(profile.micrometersPerPixel, 2)
        XCTAssertTrue(profile.matches(cameraID: "a", size: CGSize(width: 1920, height: 1080), configuration: "Lens"))
        XCTAssertFalse(profile.matches(cameraID: "b", size: CGSize(width: 1920, height: 1080), configuration: "Lens"))
        XCTAssertFalse(profile.matches(cameraID: "a", size: CGSize(width: 1280, height: 720), configuration: "Lens"))
        XCTAssertFalse(profile.matches(cameraID: "a", size: CGSize(width: 1920, height: 1080), configuration: "Other"))
        let line = Measurement(a: .zero, b: CGPoint(x: 0.5, y: 0))
        XCTAssertEqual(line.pixels(in: CGSize(width: 1000, height: 1000)), 500)
    }
    func testSmoothingReducesJitterAndBoundsLock() {
        var smoother = MotionSmoother()
        var corrected: [Double] = []
        var previous = 0.0
        for i in 0..<120 {
            let position = i % 2 == 0 ? 5.0 : -5.0
            let c = smoother.update(translation: CGPoint(x: previous - position, y: 0), strength: .high, locked: false, limit: CGSize(width: 80, height: 80))
            corrected.append(position + c.x); previous = position
        }
        XCTAssertLessThan(corrected.map(abs).reduce(0, +) / Double(corrected.count), 1)
        for _ in 0..<1000 {
            let c = smoother.update(translation: CGPoint(x: 10, y: -10), strength: .high, locked: true, limit: CGSize(width: 80, height: 40))
            XCTAssertLessThanOrEqual(abs(c.x), 80); XCTAssertLessThanOrEqual(abs(c.y), 40)
        }
        let before = smoother.correction
        let released = smoother.update(translation: nil, strength: .high, locked: true, limit: CGSize(width: 80, height: 40))
        XCTAssertLessThan(abs(released.x), abs(before.x))
        XCTAssertEqual(smoother.update(translation: .zero, strength: .off, locked: false, limit: .zero), .zero)
    }
    func testSettingsPersistAndCorruptDataFallsBack() {
        let suite = "MicroscopeTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var p = Preferences(); p.pipeline.image.brightness = 0.2; p.pipeline.viewport.zoom(to: 3); p.grid = true; p.outputPath = "/tmp/test"
        SettingsStore.save(p, to: defaults)
        let loaded = SettingsStore.load(from: defaults)
        XCTAssertEqual(loaded.pipeline, p.pipeline); XCTAssertTrue(loaded.grid); XCTAssertEqual(loaded.outputPath, "/tmp/test")
        defaults.set(Data([0, 255]), forKey: "preferences.v1")
        XCTAssertEqual(SettingsStore.load(from: defaults).pipeline.viewport.zoom, 1)
    }
}
