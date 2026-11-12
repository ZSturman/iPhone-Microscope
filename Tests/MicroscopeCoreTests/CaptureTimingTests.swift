import XCTest
import CoreMedia
@testable import MicroscopeCore

final class CaptureTimingTests: XCTestCase {
    func testContinuityCameraSixtyFPSBoundaryRetainsExactDuration() throws {
        let minimum = CMTime(value: 1_000_000, timescale: 60_000_000)
        let maximum = CMTime(value: 1_000_000, timescale: 1_000_000)
        let rounded = CMTime(seconds: 1.0 / 60, preferredTimescale: 1_000_000_000)
        XCTAssertLessThan(rounded, minimum) // Original crash: requests >60 FPS.
        let result = try XCTUnwrap(CaptureTiming.duration(minimum: minimum, maximum: maximum))
        XCTAssertEqual(result.value, minimum.value)
        XCTAssertEqual(result.timescale, minimum.timescale)
        XCTAssertGreaterThanOrEqual(result, minimum)
    }
    func testFixedAndFractionalRatesStayInAdvertisedRange() {
        for minimum in [CMTime(value: 1, timescale: 30), CMTime(value: 1, timescale: 60), CMTime(value: 1001, timescale: 30_000)] {
            XCTAssertEqual(CaptureTiming.duration(minimum: minimum, maximum: minimum), minimum)
        }
        XCTAssertEqual(CaptureTiming.duration(minimum: CMTime(value: 1, timescale: 120), maximum: CMTime(value: 1, timescale: 24)), CMTime(value: 1, timescale: 60))
        XCTAssertNil(CaptureTiming.duration(minimum: .invalid, maximum: .zero))
        XCTAssertNil(CaptureTiming.duration(minimum: CMTime(value: 1, timescale: 120), maximum: CMTime(value: 1, timescale: 120)))
    }
}
