import XCTest
import AVFoundation
import CoreImage
@testable import MicroscopeCore

final class RecordingTests: XCTestCase {
    func testMP4AndMOVArePlayableAndContainFrames() async throws {
        for ext in ["mp4", "mov"] {
            let recorder = FrameRecorder()
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("MicroscopeTest-\(UUID()).\(ext)")
            defer { try? FileManager.default.removeItem(at: url) }
            let start = expectation(description: "Start")
            recorder.start(url: url, size: CGSize(width: 640, height: 360)) { error in XCTAssertNil(error); start.fulfill() }
            await fulfillment(of: [start], timeout: 10)
            let demo = DemoSource()
            for frame in 0..<20 {
                recorder.append(demo.frame(at: Double(frame) / 30), at: CMTime(value: Int64(frame), timescale: 30))
                try await Task.sleep(nanoseconds: 33_000_000)
            }
            let stop = expectation(description: "Finalize")
            recorder.stop { error in XCTAssertNil(error); stop.fulfill() }
            await fulfillment(of: [stop], timeout: 15)
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            XCTAssertGreaterThan(duration.seconds, 0.4)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            XCTAssertEqual(tracks.count, 1)
            let size = try await tracks[0].load(.naturalSize)
            XCTAssertEqual(size, CGSize(width: 640, height: 360))
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            reader.add(output); XCTAssertTrue(reader.startReading())
            var count = 0
            while output.copyNextSampleBuffer() != nil { count += 1 }
            XCTAssertGreaterThan(count, 12); XCTAssertEqual(reader.status, .completed)
        }
    }
    func testEmptyRecordingReportsFailureAndWriterCanRestart() async {
        let recorder = FrameRecorder()
        for _ in 0..<2 {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("MicroscopeEmpty-\(UUID()).mp4")
            defer { try? FileManager.default.removeItem(at: url) }
            let start = expectation(description: "Start")
            recorder.start(url: url, size: CGSize(width: 640, height: 480)) { XCTAssertNil($0); start.fulfill() }
            await fulfillment(of: [start], timeout: 10)
            let stop = expectation(description: "Stop empty")
            recorder.stop { XCTAssertNotNil($0); stop.fulfill() }
            await fulfillment(of: [stop], timeout: 10)
        }
    }
}
