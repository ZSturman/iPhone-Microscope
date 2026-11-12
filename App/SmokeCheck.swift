#if DEBUG
import Foundation
import AppKit
import AVFoundation
import CoreImage
import Combine

/// Exercises the assembled model using demo footage or an explicitly requested real iPhone.
@MainActor
final class SmokeCheck {
    private static var started = false
    static func runIfRequested(_ model: AppModel) {
        CompanionSmokeCheck.runIfRequested(model)
        let arguments = ProcessInfo.processInfo.arguments
        let hardware = arguments.contains("--iphone-smoke-test")
        guard let index = arguments.firstIndex(of: hardware ? "--iphone-smoke-test" : "--smoke-test"), arguments.count > index + 1, !started else { return }
        started = true
        let directory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        Task {
            var results: [String: Any] = [:]
            func stage(_ value: String) { results["stage"] = value; FileHandle.standardError.write(Data((value + "\n").utf8)) }
            let statusObserver = model.$status.sink { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
            defer { statusObserver.cancel() }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                model.preferences = Preferences(); model.preferences.outputPath = directory.path; model.recentSnapshots = []
                if hardware {
                    stage("Discovering Continuity Camera")
                    try await wait { model.cameras.contains { $0.continuity } }
                    let camera = try required(model.cameras.first { $0.continuity }, "No Continuity Camera connected")
                    stage("Starting iPhone live capture")
                    model.selectCamera(camera.id)
                }
                try await wait { model.image != nil && model.fps > 0 }
                try checkKeyboardControls(model)
                results["keyboardControls"] = true
                let initialFormat = model.formatID
                if hardware {
                    var checked: [[String: Any]] = []
                    for format in model.formats {
                        stage("Testing format: \(format.label)")
                        model.selectFormat(format.id)
                        try await wait { model.formatID == format.id && model.image != nil && model.sourceSize.width == Double(format.width) && model.sourceSize.height == Double(format.height) && model.fps > 0 }
                        // Continuity can revert the frame rate about two seconds after a switch.
                        try await Task.sleep(nanoseconds: 3_500_000_000)
                        checked.append(["format": format.label, "observedFPS": model.fps])
                        if abs(model.fps - format.fps) > format.fps * 0.3 { throw Failure.message("\(format.label) delivered \(Int(model.fps.rounded())) fps") }
                    }
                    results["formatChecks"] = checked
                    stage("Restoring initial format")
                    model.selectFormat(initialFormat)
                    try await wait { model.formatID == initialFormat && model.image != nil && model.sourceSize.width > 0 && model.fps > 0 }
                    results["hardwareCapabilities"] = ["focusLock": model.capabilities.focusLock, "exposureLock": model.capabilities.exposureLock, "whiteBalanceLock": model.capabilities.whiteBalanceLock, "highResolutionPhoto": model.capabilities.highResolutionPhoto]
                    model.focusLocked = model.capabilities.focusLock; model.exposureLocked = model.capabilities.exposureLock; model.whiteBalanceLocked = model.capabilities.whiteBalanceLock
                    model.locksChanged()
                    try await Task.sleep(nanoseconds: 300_000_000)
                    model.focusLocked = false; model.exposureLocked = false; model.whiteBalanceLocked = false; model.locksChanged()
                }
                let videoSize = model.sourceSize
                try await Task.sleep(nanoseconds: 1_000_000_000)
                results["source"] = hardware ? "Live iPhone Continuity Camera" : "Generated footage"
                results["videoSize"] = ["width": videoSize.width, "height": videoSize.height]
                results["fps"] = model.fps; results["tracking"] = model.tracking
                results["cameraCount"] = model.cameras.count
                results["cameraNames"] = model.cameras.map(\.name)
                model.preferences.pipeline.viewport.zoom(to: 2.5, anchor: CGPoint(x: 0.7, y: 0.4))
                model.preferences.pipeline.viewport.x += 0.1; model.preferences.pipeline.viewport.constrain()
                model.preferences.pipeline.image.grayscale = true; model.preferences.grid = true
                try await Task.sleep(nanoseconds: 200_000_000)
                model.toggleFreeze()
                let frozen = model.image
                try await Task.sleep(nanoseconds: 150_000_000)
                guard model.image === frozen else { throw Failure.message("Freeze changed the displayed image") }
                model.setReference()
                guard model.reference != nil && model.comparing else { throw Failure.message("Reference was not retained") }
                results["freezeAndReference"] = true
                model.measurement = Measurement(a: CGPoint(x: 0.3, y: 0.5), b: CGPoint(x: 0.7, y: 0.5))
                model.calibrate(name: "Smoke", micrometers: 1000)
                guard model.activeCalibration != nil, abs(model.measurementPixels * model.activeCalibration!.micrometersPerPixel - 1000) < 0.001 else { throw Failure.message("Calibration failed") }
                results["measurement"] = model.measurementLabel
                model.preferences.opticalConfiguration = "Changed"
                guard model.activeCalibration == nil, !model.measurementLabel.contains("µm") else { throw Failure.message("Calibration units leaked after optics changed") }
                results["calibrationInvalidation"] = true
                stage("Saving processed PNG")
                model.snapshot()
                try await wait { !model.snapshotBusy }
                guard model.recentSnapshots.count == 1, let png = CIImage(contentsOf: model.recentSnapshots[0]), png.extent.width == videoSize.width else { throw Failure.message("PNG snapshot failed") }
                model.toggleFreeze(); model.clearReference()
                model.preferences.imageFormat = "jpg"; model.preferences.originalSnapshot = true
                stage("Saving original JPEG")
                model.snapshot(); try await wait { !model.snapshotBusy }
                if let url = model.recentSnapshots.first, let photo = CIImage(contentsOf: url) { results["originalPhotoSize"] = ["width": photo.extent.width, "height": photo.extent.height] }
                guard model.errorMessage == nil else { throw Failure.message(model.errorMessage!) }
                guard model.recentSnapshots.count == 2 else { throw Failure.message("JPEG snapshot failed") }
                results["snapshots"] = model.recentSnapshots.map(\.lastPathComponent)
                for original in [false, true] {
                    model.preferences.originalRecording = original
                    model.preferences.videoFormat = original ? "mov" : "mp4"
                    stage(original ? "Recording original MOV" : "Recording processed MP4")
                    model.toggleRecording(); try await wait { model.recording }
                    try await Task.sleep(nanoseconds: (hardware ? 5_000_000_000 : 2_000_000_000))
                    model.stopRecording(); try await wait { !model.finalizing }
                    guard model.errorMessage == nil else { throw Failure.message(model.errorMessage!) }
                }
                let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                for ext in ["mp4", "mov"] {
                    let url = try required(files.first { $0.pathExtension == ext }, "Missing video")
                    let asset = AVURLAsset(url: url)
                    let duration = try await asset.load(.duration)
                    guard duration.seconds > 1.5 else { throw Failure.message("Video too short") }
                    let tracks = try await asset.loadTracks(withMediaType: .video)
                    let track = try required(tracks.first, "Missing video track")
                    let size = try await track.load(.naturalSize)
                    guard size.width == videoSize.width && size.height == videoSize.height else { throw Failure.message("Wrong video size") }
                    let reader = try AVAssetReader(asset: asset)
                    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
                    reader.add(output); guard reader.startReading() else { throw Failure.message("Cannot decode video") }
                    var frames = 0
                    var chroma = 0.0
                    while let sample = output.copyNextSampleBuffer() {
                        if frames == 0, let buffer = CMSampleBufferGetImageBuffer(sample) {
                            CVPixelBufferLockBaseAddress(buffer, .readOnly)
                            if let pointer = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) {
                                let row = CVPixelBufferGetBytesPerRow(buffer), h = CVPixelBufferGetHeight(buffer), w = CVPixelBufferGetWidth(buffer)
                                for y in stride(from: 10, to: h, by: 60) { for x in stride(from: 10, to: w, by: 60) { let i = y * row + x * 4; chroma += abs(Double(pointer[i]) - Double(pointer[i + 2])) } }
                            }
                            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
                        }
                        frames += 1
                    }
                    guard frames > (hardware ? 10 : 30), reader.status == .completed else { throw Failure.message("Too few decodable frames: \(frames)") }
                    if ext == "mp4", chroma > 100 { throw Failure.message("Processed video did not retain grayscale") }
                    if !hardware, ext == "mov", chroma < 200 { throw Failure.message("Original video unexpectedly grayscale") }
                    results[ext] = ["frames": frames, "duration": duration.seconds, "chroma": chroma]
                }
                model.shutdown()
                let saved = SettingsStore.load(from: UserDefaults(suiteName: "com.local.iPhoneMicroscope.Smoke")!)
                guard saved.grid && saved.pipeline.viewport.zoom == 2.5 && saved.snapshotPaths.count == 2 else { throw Failure.message("Settings did not persist") }
                results["persistence"] = true; results["dropped"] = model.dropped; results["passed"] = true
            } catch {
                results["passed"] = false; results["error"] = error.localizedDescription
                results["status"] = model.status; results["formatID"] = model.formatID
                results["observedSize"] = ["width": model.sourceSize.width, "height": model.sourceSize.height]
            }
            let data = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
            try? data?.write(to: directory.appendingPathComponent("result.json"), options: .atomic)
            NSApp.terminate(nil)
        }
    }
    /// Exercise the production action path and editing guard without injecting desktop input.
    private static func checkKeyboardControls(_ model: AppModel) throws {
        func key(_ characters: String, code: UInt16 = 0, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try required(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                         timestamp: 0, windowNumber: 0, context: nil, characters: characters,
                                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code), "Could not create test key")
        }
        guard MicroscopeAction.from(try key("s")) == .snapshot,
              MicroscopeAction.from(try key(" ")) == .freeze,
              MicroscopeAction.from(try key("+", modifiers: .shift)) == .zoomIn,
              MicroscopeAction.from(try key("=")) == .zoomIn,
              MicroscopeAction.from(try key("?", modifiers: .shift)) == .shortcuts,
              MicroscopeAction.from(try key("", code: 126)) == .panUp,
              MicroscopeAction.from(try key("s", modifiers: .command)) == nil,
              MicroscopeAction.from(try key("r", modifiers: .control)) == nil,
              !KeyboardEventView.acceptsViewerKeys(firstResponder: NSTextView()),
              !KeyboardEventView.acceptsViewerKeys(firstResponder: NSTextField()),
              !KeyboardEventView.acceptsViewerKeys(firstResponder: NSSlider()),
              KeyboardEventView.acceptsViewerKeys(firstResponder: PreviewView()) else {
            throw Failure.message("Keyboard routing or editing protection failed")
        }
        let preferences = model.preferences
        let guide = model.showingShortcuts
        defer {
            model.preferences = preferences; model.showingShortcuts = guide
            model.clearReference(); model.measuring = false
            if model.frozen { model.toggleFreeze() }
        }
        model.perform(.reset); model.perform(.zoomIn); model.perform(.panRight)
        guard model.preferences.pipeline.viewport.zoom > 1, model.preferences.pipeline.viewport.x > 0.5 else {
            throw Failure.message("Keyboard zoom/pan failed")
        }
        model.perform(.reset)
        guard model.preferences.pipeline.viewport == Viewport() else { throw Failure.message("Keyboard reset failed") }
        model.perform(.freeze)
        guard model.frozen else { throw Failure.message("Keyboard freeze failed") }
        model.perform(.reference); model.perform(.measure)
        guard model.measuring && !model.comparing else { throw Failure.message("Measurement did not exit comparison") }
        model.perform(.compare)
        guard model.comparing && !model.measuring else { throw Failure.message("Comparison did not exit measurement") }
        model.clearReference(); model.perform(.compare)
        guard !model.comparing else { throw Failure.message("Comparison activated without a reference") }
        model.perform(.grid); model.perform(.crosshair); model.perform(.inspector); model.perform(.shortcuts)
        guard model.preferences.grid != preferences.grid, model.preferences.crosshair != preferences.crosshair,
              model.preferences.inspector != preferences.inspector, model.showingShortcuts != guide else {
            throw Failure.message("Keyboard visibility toggles failed")
        }
        for _ in StabilizationStrength.allCases { model.perform(.stabilization) }
        guard model.preferences.pipeline.stabilization == preferences.pipeline.stabilization else {
            throw Failure.message("Keyboard stabilization cycle failed")
        }
    }
    private static func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<300 { if predicate() { return }; try await Task.sleep(nanoseconds: 100_000_000) }
        throw Failure.message("Timed out waiting for app state")
    }
    private static func required<T>(_ value: T?, _ message: String) throws -> T { guard let value else { throw Failure.message(message) }; return value }
    enum Failure: LocalizedError { case message(String); var errorDescription: String? { if case let .message(value) = self { return value }; return nil } }
}
#endif
