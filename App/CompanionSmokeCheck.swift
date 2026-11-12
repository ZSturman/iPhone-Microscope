#if DEBUG
import AppKit
import AVFoundation
import CoreImage
import Combine

/// Explicit physical-device integration check. Uses isolated Mac preferences and temporary media.
@MainActor
enum CompanionSmokeCheck {
    private static var started = false
    static func runIfRequested(_ model: AppModel) {
        let arguments = ProcessInfo.processInfo.arguments
        guard !started, let index = arguments.firstIndex(of: "--companion-smoke-test"), arguments.count > index + 2 else { return }
        started = true
        let directory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        let code = arguments[index + 2]
        Task {
            var result: [String: Any] = ["source": "Physical iPhone companion"]
            func stage(_ value: String) {
                result["stage"] = value
                FileHandle.standardError.write(Data((value + "\n").utf8))
                if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: directory.appendingPathComponent("progress.json"), options: .atomic)
                }
            }
            let observer = model.$status.sink { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
            defer { observer.cancel() }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                model.preferences = Preferences(); model.preferences.outputPath = directory.path; model.recentSnapshots = []
                stage("Discovering physical iPhone companion")
                model.selectCamera("companion")
                try await wait { !model.companionPeers.isEmpty }
                model.companionCode = "abcdef"
                guard !model.canConnectCompanion else { throw Failure("Invalid pairing text enables Connect") }
                model.connectCompanion()
                guard model.companionState == nil, model.image == nil else { throw Failure("Invalid pairing text connected") }
                result["pairingInputValidation"] = true
                stage("Rejecting an incorrect pairing code")
                model.companionCode = code == "000000" ? "999999" : "000000"
                model.connectCompanion()
                try await wait { model.companionStatus.hasPrefix("Pairing with") }
                try await wait { model.companionStatus.contains("disconnected") }
                guard model.companionState == nil, model.image == nil else { throw Failure("Camera imagery escaped before code authentication") }
                result["incorrectCodeRejected"] = true
                model.companionCode = code
                stage("Pairing encrypted session")
                model.connectCompanion()
                try await wait { model.companionState != nil && model.image != nil && model.fps > 0 }
                guard model.companionStatus == "Streaming · camera frames received" else { throw Failure("Companion still reports waiting after receiving frames") }
                result["streamingStatus"] = true
                let initial = try required(model.companionState)
                var lenses: [[String: Any]] = []
                for lens in initial.lenses {
                    stage("Selecting \(lens.name)")
                    try await command(.lens(lens.id), model: model)
                    guard model.companionState?.lensID == lens.id else { throw Failure("Wrong physical lens selected") }
                    lenses.append(["name": lens.name, "width": model.sourceSize.width, "height": model.sourceSize.height, "fps": model.fps, "manualFocus": model.companionState?.supportsManualFocus ?? false, "depthAvailable": model.companionState?.depthAvailable ?? false, "minimumFocusDistanceMM": model.companionState?.minimumFocusDistanceMM ?? -1])
                }
                result["lenses"] = lenses
                // Exercise close focus on the actual Ultra Wide when available.
                if let macro = initial.lenses.first(where: { $0.name.contains("Ultra Wide") }) { try await command(.lens(macro.id), model: model) }
                model.toggleFreeze(); model.setReference()
                model.measurement = Measurement(a: CGPoint(x: 0.3, y: 0.5), b: CGPoint(x: 0.7, y: 0.5))
                model.calibrate(name: "Companion test", micrometers: 1000)
                guard model.activeCalibration != nil else { throw Failure("Companion calibration failed") }
                let previousProfile = model.preferences.activeProfile
                stage("Changing camera zoom and invalidating calibration")
                let zoom = min(2, try required(model.companionState).maxZoom)
                model.sendCompanion(.zoom(zoom))
                guard model.image != nil, model.awaitingCameraFrame, !model.canCapture, model.activeCalibration == nil, model.reference == nil, !model.frozen else { throw Failure("Stale geometry survived a camera command") }
                try await changed(model)
                guard abs((model.companionState?.zoom ?? 0) - zoom) < 0.01 else { throw Failure("Camera zoom was not applied") }
                model.preferences.activeProfile = previousProfile
                guard model.activeCalibration == nil else { throw Failure("An old optical profile matched a changed camera") }
                result["cameraZoomAndCalibration"] = true
                if try required(model.companionState).supportsManualFocus {
                    stage("Setting physical lens focus")
                    try await command(.focus(0.4), model: model)
                    guard abs((model.companionState?.manualFocus ?? -1) - 0.4) < 0.04 else { throw Failure("Manual focus did not reach its requested position") }
                    try await command(.focus(nil), model: model)
                    guard model.companionState?.focusLocked == false else { throw Failure("Autofocus did not resume") }
                    result["manualFocus"] = true
                }
                let state = try required(model.companionState)
                let bias = min(1, state.maxExposureBias)
                stage("Adjusting sensor exposure")
                try await command(.exposure(bias), model: model)
                guard abs((model.companionState?.exposureBias ?? -99) - bias) < 0.05 else { throw Failure("Camera exposure compensation did not apply") }
                try await command(.exposure(0), model: model)
                result["exposureBias"] = true
                if state.supportsTorch {
                    stage("Checking iPhone light")
                    try await command(.torch(true), model: model)
                    guard model.companionState?.torch == true else { throw Failure("Torch did not turn on") }
                    try await command(.torch(false), model: model)
                    result["torch"] = true
                }
                stage("Checking camera locks")
                try await command(.locks(focus: state.supportsFocusLock, exposure: state.supportsExposureLock, whiteBalance: state.supportsWhiteBalanceLock), model: model)
                let locked = try required(model.companionState)
                guard locked.focusLocked == state.supportsFocusLock, locked.exposureLocked == state.supportsExposureLock, locked.whiteBalanceLocked == state.supportsWhiteBalanceLock else { throw Failure("Camera locks did not apply") }
                try await command(.locks(focus: false, exposure: false, whiteBalance: false), model: model)
                result["locks"] = true
                var qualities: [[String: Any]] = []
                for quality in try required(model.companionState).supportedQualities {
                    stage("Receiving \(quality.label)")
                    try await command(.quality(quality), model: model)
                    guard model.sourceSize.width == Double(quality.width), model.sourceSize.height == Double(quality.height) else { throw Failure("Wrong incoming resolution") }
                    try await Task.sleep(nanoseconds: 1_500_000_000)
                    qualities.append(["mode": quality.label, "width": model.sourceSize.width, "height": model.sourceSize.height, "observedFPS": model.fps])
                    if model.companionState?.supportedFrameRates?.contains(5) == true {
                        stage("Setting \(quality.label) capture to 5 fps")
                        try await command(.frameRate(5), model: model)
                        guard model.companionState?.captureFPS == 5,
                              model.sourceSize.width == Double(quality.width), model.sourceSize.height == Double(quality.height) else { throw Failure("FPS change altered resolution or did not apply") }
                        try await Task.sleep(nanoseconds: 1_500_000_000)
                        result["captureFPS-\(quality.rawValue)"] = ["requested": 5, "observed": model.fps]
                        try await command(.frameRate(quality.fps), model: model)
                    }
                }
                result["streamModes"] = qualities
                stage("Saving full-resolution received still")
                model.preferences.originalSnapshot = true; model.preferences.imageFormat = "jpg"
                model.snapshot(); try await wait { !model.snapshotBusy }
                let still = try required(model.recentSnapshots.first)
                guard let image = CIImage(contentsOf: still), image.extent.size == model.sourceSize else { throw Failure("Received still did not decode at source resolution") }
                let maximumChannel = maximumChannel(in: image)
                result["receivedStill"] = ["width": image.extent.width, "height": image.extent.height, "maximumSampledChannel": maximumChannel]
                guard maximumChannel > 8 else { throw Failure("Received image is effectively black. Illuminate/uncover the specimen and close Device Hub screen viewing or other camera apps before retrying.") }
                if try required(model.companionState).supportedQualities.contains(.hd) { try await command(.quality(.hd), model: model) }
                let videoSize = model.sourceSize
                model.preferences.pipeline.image.grayscale = true
                for original in [true, false] {
                    stage(original ? "Recording received original feed" : "Recording processed feed")
                    model.preferences.originalRecording = original; model.preferences.videoFormat = original ? "mov" : "mp4"
                    model.toggleRecording(); try await wait { model.recording }
                    // A camera geometry command must be ignored while recording.
                    let revision = model.companionState?.revision
                    model.sendCompanion(.zoom(3))
                    model.sendCompanion(.frameRate(5))
                    guard model.companionPending == nil, model.companionState?.revision == revision else { throw Failure("Camera changed during recording") }
                    try await Task.sleep(nanoseconds: 4_000_000_000)
                    model.stopRecording(); try await wait { !model.finalizing }
                    if let error = model.errorMessage { throw Failure(error) }
                }
                for ext in ["mov", "mp4"] {
                    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                    let file = try required(files.first(where: { $0.pathExtension == ext }))
                    let asset = AVURLAsset(url: file)
                    let duration = try await asset.load(.duration)
                    let track = try required(try await asset.loadTracks(withMediaType: .video).first)
                    let size = try await track.load(.naturalSize)
                    let reader = try AVAssetReader(asset: asset)
                    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
                    reader.add(output); guard reader.startReading() else { throw Failure("Video decoder failed") }
                    var count = 0
                    while output.copyNextSampleBuffer() != nil { count += 1 }
                    guard size == videoSize, duration.seconds > 2, count > 5, reader.status == .completed else { throw Failure("Received video has invalid dimensions, duration or frames") }
                    result[ext] = ["frames": count, "seconds": duration.seconds, "width": size.width, "height": size.height]
                }
                stage("Disconnecting and rejecting stale frames")
                model.disconnectCompanion()
                try await wait { model.companionState == nil }
                try await Task.sleep(nanoseconds: 500_000_000)
                guard model.image != nil, model.awaitingCameraFrame, !model.canCapture, model.activeCalibration == nil else { throw Failure("Disconnected source did not hold its last frame safely") }
                stage("Reconnecting paired iPhone")
                model.connectCompanion()
                try await wait { model.companionState != nil && model.image != nil && model.fps > 0 }
                result["reconnect"] = true; result["recordingControlGuard"] = true
                result["passed"] = true
            } catch {
                result["passed"] = false; result["error"] = error.localizedDescription
                result["status"] = model.status; result["phoneStatus"] = model.companionStatus
            }
            if model.recording { model.stopRecording(); try? await wait { !model.finalizing } }
            model.shutdown()
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: directory.appendingPathComponent("result.json"), options: .atomic) }
            NSApp.terminate(nil)
        }
    }
    private static func command(_ command: PhoneCameraCommand, model: AppModel) async throws {
        model.sendCompanion(command)
        guard model.companionPending != nil else { throw Failure("Command was not sent") }
        try await changed(model)
    }
    private static func changed(_ model: AppModel) async throws {
        try await wait { model.companionPending == nil }
        if let error = model.errorMessage { throw Failure(error) }
        try await wait { model.image != nil && model.fps > 0 }
    }
    private static func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<450 { if predicate() { return }; try await Task.sleep(nanoseconds: 100_000_000) }
        throw Failure("Timed out waiting for the physical iPhone. Check permissions and keep the companion foregrounded.")
    }
    private static func required<T>(_ value: T?) throws -> T { guard let value else { throw Failure("Missing camera state or saved media") }; return value }
    private static func maximumChannel(in image: CIImage) -> UInt8 {
        let sample = image.transformed(by: CGAffineTransform(scaleX: 64 / image.extent.width, y: 36 / image.extent.height))
        var rgba = [UInt8](repeating: 0, count: 64 * 36 * 4)
        CIContext().render(sample, toBitmap: &rgba, rowBytes: 64 * 4, bounds: CGRect(x: 0, y: 0, width: 64, height: 36), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return stride(from: 0, to: rgba.count, by: 4).reduce(0) { max($0, max(rgba[$1], max(rgba[$1 + 1], rgba[$1 + 2]))) }
    }
    private struct Failure: LocalizedError {
        var message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
#endif
