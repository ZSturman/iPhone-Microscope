import XCTest
@testable import CompanionLink

final class CompanionProtocolTests: XCTestCase {
    private func state() -> PhoneCameraState {
        PhoneCameraState(deviceID: "test-phone", revision: 1, lenses: [PhoneLens(id: "main", name: "Main")], lensID: "main", quality: .ultraHD, supportedQualities: [.hd, .ultraHD], zoom: 2, minZoom: 1, maxZoom: 20, losslessZoomLimit: 2, manualFocus: nil, supportsManualFocus: true, supportsFocusLock: true, supportsExposureLock: true, supportsWhiteBalanceLock: true, focusLocked: false, exposureLocked: false, whiteBalanceLocked: false, exposureBias: 0, minExposureBias: -4, maxExposureBias: 4, supportsTorch: true, torch: false)
    }
    func testCameraControlsAndCapabilitiesSurviveTransport() throws {
        let id = UUID()
        let commands: [PhoneCameraCommand] = [.lens("ultra"), .quality(.ultraHD), .frameRate(5), .zoom(2.5), .focus(0.4), .focus(nil), .exposure(-1), .torch(true), .locks(focus: true, exposure: false, whiteBalance: true)]
        let messages = commands.map { CompanionMessage.command(id: id, $0) } + [.hello(version: 1, code: "001234"), .authenticated, .state(state()), .reply(id: id, error: nil), .reply(id: id, error: "Unavailable"), .acknowledgement(42)]
        for message in messages {
            let (decoded, jpeg) = try CompanionPacket.decode(CompanionPacket.encode(message))
            XCTAssertEqual(decoded, message); XCTAssertTrue(jpeg.isEmpty)
        }
    }
    func testFrameBytesTimestampAndRevisionArePreserved() throws {
        let frame = CompanionFrame(sequence: 9, revision: 7, seconds: 1234.567, width: 3840, height: 2160)
        let jpeg = Data([0xff, 0xd8, 1, 0, 4, 0xff, 0xd9])
        let (decoded, bytes) = try CompanionPacket.decode(CompanionPacket.encode(.frame(frame), jpeg: jpeg))
        XCTAssertEqual(decoded, .frame(frame)); XCTAssertEqual(bytes, jpeg)
    }
    func testFrameRateCapabilitiesAndLegacyState() throws {
        let legacy = state()
        XCTAssertEqual(legacy.captureFPS, 15)
        XCTAssertEqual(try CompanionPacket.decode(CompanionPacket.encode(.state(legacy))).0, .state(legacy))
        var current = legacy; current.frameRate = 5; current.supportedFrameRates = [5, 10, 15, 24, 30]
        XCTAssertEqual(try CompanionPacket.decode(CompanionPacket.encode(.state(current))).0, .state(current))
        current.frameRate = 120
        XCTAssertThrowsError(try CompanionPacket.decode(CompanionPacket.encode(.state(current))))
        current.frameRate = 5; current.supportedFrameRates = [5, 5]
        XCTAssertThrowsError(try CompanionPacket.decode(CompanionPacket.encode(.state(current))))
        current.supportedFrameRates = nil
        XCTAssertThrowsError(try CompanionPacket.decode(CompanionPacket.encode(.state(current))))
    }
    func testTruncatedAndOversizedHeadersAreRejectedWithoutSlicingPastEnd() throws {
        for data in [Data(), Data([0, 0, 0]), Data([255, 255, 255, 255]), Data([0, 0, 0, 20, 123])] {
            XCTAssertThrowsError(try CompanionPacket.decode(data))
        }
        let packet = try CompanionPacket.encode(.hello(version: 1, code: "123456"))
        XCTAssertThrowsError(try CompanionPacket.decode(Data(packet.dropLast())))
    }
    func testUnexpectedMediaAndExcessiveFrameSizesAreRejected() throws {
        XCTAssertThrowsError(try CompanionPacket.encode(.hello(version: 1, code: "123456"), jpeg: Data([1])))
        XCTAssertThrowsError(try CompanionPacket.encode(.frame(CompanionFrame(sequence: 1, revision: 1, seconds: 0, width: 7680, height: 4320)), jpeg: Data([1])))
        XCTAssertThrowsError(try CompanionPacket.encode(.frame(CompanionFrame(sequence: 1, revision: 1, seconds: -1, width: 1920, height: 1080)), jpeg: Data([1])))
        XCTAssertThrowsError(try CompanionPacket.encode(.frame(CompanionFrame(sequence: 1, revision: 1, seconds: 0, width: 1920, height: 1080))))
        var packet = try CompanionPacket.encode(.hello(version: 1, code: "123456"))
        packet.append(1)
        XCTAssertThrowsError(try CompanionPacket.decode(packet))
    }
    func testUntrustedCameraStateCannotCreateInvalidSliderRanges() throws {
        var invalid = state(); invalid.maxZoom = 0
        XCTAssertThrowsError(try CompanionPacket.decode(CompanionPacket.encode(.state(invalid))))
        invalid = state(); invalid.lensID = "missing"
        XCTAssertThrowsError(try CompanionPacket.decode(CompanionPacket.encode(.state(invalid))))
        invalid = state(); invalid.manualFocus = 2
        XCTAssertThrowsError(try CompanionPacket.decode(CompanionPacket.encode(.state(invalid))))
        invalid = state(); invalid.exposureBias = 10
        XCTAssertThrowsError(try CompanionPacket.decode(CompanionPacket.encode(.state(invalid))))
        invalid = state(); invalid.supportedQualities = [.hd]
        XCTAssertThrowsError(try CompanionPacket.decode(CompanionPacket.encode(.state(invalid))))
    }
}
