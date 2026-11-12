import Foundation
import AVFoundation
import CoreImage

public struct CameraChoice: Identifiable {
    public let id: String
    public let name: String
    public let continuity: Bool
}
public struct CameraFormat: Identifiable {
    public let id: Int
    public let width: Int
    public let height: Int
    public let fps: Double
    public var label: String { "\(width) × \(height) · \(Int(fps)) fps" }
}
public struct HardwareCapabilities {
    public var focusLock = false
    public var exposureLock = false
    public var whiteBalanceLock = false
    public var highResolutionPhoto = false
    public init() {}
}

public final class CaptureController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCapturePhotoCaptureDelegate {
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "microscope.capture", qos: .userInitiated)
    // Frames run synchronously here; AVFoundation discards late buffers.
    public let frameQueue = DispatchQueue(label: "microscope.frames", qos: .userInitiated)
    private let frameGate = NSLock()
    private var configuredSize = CGSize.zero
    private let output = AVCaptureVideoDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private var photoRequestID: Int64?
    private var photoCompletion: ((Result<CIImage, Error>) -> Void)?
    private let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera], mediaType: .video, position: .unspecified)
    private var current: AVCaptureDevice?
    private var desiredID: String?
    private var frameRateObservation: NSKeyValueObservation?
    private var frameRateRepairs = 0
    private var observers: [NSObjectProtocol] = []
    private var demoTimer: DispatchSourceTimer?
    private var demoTick = 0
    private var isDemo = false
    private let demo = DemoSource()
    public var onFrame: ((CIImage, CMTime) -> Void)?
    public var onDevices: (([CameraChoice]) -> Void)?
    public var onConfigured: ((String, [CameraFormat], Int, HardwareCapabilities) -> Void)?
    public var onStatus: ((String) -> Void)?
    public var onDrop: (() -> Void)?

    public override init() {
        super.init()
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in self?.refresh() })
        }
        for name in [AVCaptureSession.runtimeErrorNotification, AVCaptureSession.wasInterruptedNotification, AVCaptureSession.interruptionEndedNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: session, queue: nil) { [weak self] note in
                guard let self else { return }
                if name == AVCaptureSession.interruptionEndedNotification { self.refresh() }
                else {
                    self.onStatus?(name == AVCaptureSession.wasInterruptedNotification ? "Camera interrupted. Lock and mount your iPhone, then reconnect." : "Camera session failed. Choose the camera again to retry.")
                }
            })
        }
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver); demoTimer?.cancel() }
    public func refresh() {
        sessionQueue.async {
            let devices = self.discovery.devices
            self.onDevices?(devices.map { CameraChoice(id: $0.uniqueID, name: $0.localizedName, continuity: $0.isContinuityCamera) })
            if self.isDemo { return }
            if let desired = self.desiredID, let device = devices.first(where: { $0.uniqueID == desired }) {
                if self.current?.uniqueID != desired || !self.session.isRunning { self.configure(device, formatID: nil) }
            } else if self.desiredID != nil {
                self.session.stopRunning(); self.current = nil
                self.onStatus?("Camera disconnected · waiting for reconnection")
            }
        }
    }
    public func select(id: String, formatID: Int? = nil) {
        if id == "demo" { startDemo(); return }
        sessionQueue.async {
            self.isDemo = false
            self.frameQueue.async { self.demoTimer?.cancel(); self.demoTimer = nil }
            self.desiredID = id
            guard let device = self.discovery.devices.first(where: { $0.uniqueID == id }) else { self.refresh(); return }
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: self.configure(device, formatID: formatID)
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    self.sessionQueue.async { guard self.desiredID == id, !self.isDemo else { return }; if granted { self.configure(device, formatID: formatID) } else { self.onStatus?("Camera access denied. Enable it in System Settings → Privacy & Security → Camera.") } }
                }
            default: self.onStatus?("Camera access denied. Enable it in System Settings → Privacy & Security → Camera.")
            }
        }
    }
    private func formats(for device: AVCaptureDevice) -> [CameraFormat] {
        var seen = Set<String>()
        return device.formats.enumerated().compactMap { index, format in
            let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard let range = format.videoSupportedFrameRateRanges.filter({ $0.minFrameRate <= 60 && $0.maxFrameRate >= 24 }).max(by: { $0.maxFrameRate < $1.maxFrameRate }) else { return nil }
            let fps = min(60, range.maxFrameRate)
            guard d.width >= 640, fps >= 24 else { return nil }
            let key = "\(d.width)x\(d.height)@\(Int(fps))"
            guard seen.insert(key).inserted else { return nil }
            return CameraFormat(id: index, width: Int(d.width), height: Int(d.height), fps: fps)
        }.sorted { $0.width * $0.height == $1.width * $1.height ? $0.fps > $1.fps : $0.width * $0.height > $1.width * $1.height }
    }
    private func configure(_ device: AVCaptureDevice, formatID: Int?) {
        do {
            frameGate.lock(); configuredSize = .zero; frameGate.unlock()
            frameQueue.sync {} // Drain old processing before publishing the new configuration.
            frameRateObservation = nil
            session.stopRunning()
            session.beginConfiguration()
            var transactionOpen = true
            defer { if transactionOpen { session.commitConfiguration() } }
            // Reuse the input for a format change. Re-adding it or reapplying a
            // preset causes macOS to renegotiate away the explicitly chosen format.
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            if (session.inputs.first as? AVCaptureDeviceInput)?.device.uniqueID != device.uniqueID {
                let input = try AVCaptureDeviceInput(device: device)
                session.inputs.forEach { session.removeInput($0) }
                guard session.canAddInput(input) else { throw CaptureError.configuration }
                session.addInput(input)
            }
            if session.outputs.isEmpty {
                output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                output.alwaysDiscardsLateVideoFrames = true
                output.setSampleBufferDelegate(self, queue: frameQueue)
                guard session.canAddOutput(output) else { throw CaptureError.configuration }
                session.addOutput(output)
            }
            let choices = formats(for: device)
            // Default: highest resolution at >=30 fps up to 4K. Faster formats remain selectable.
            let best = choices.first(where: { $0.width <= 3840 && $0.fps >= 30 }) ?? choices.first
            let selected = choices.first(where: { $0.id == formatID }) ?? best
            if let selected {
                try applyFormat(selected, to: device)
                // macOS retains preset-derived output dimensions unless requested explicitly.
                output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                        kCVPixelBufferWidthKey as String: selected.width,
                                        kCVPixelBufferHeightKey as String: selected.height]
            }
            if !session.outputs.contains(photoOutput), session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
            let photoDimensions = device.activeFormat.supportedMaxPhotoDimensions.max { Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height) }
            if session.outputs.contains(photoOutput), let dimensions = photoDimensions { photoOutput.maxPhotoDimensions = dimensions }
            session.commitConfiguration(); transactionOpen = false
            current = device
            // Reassigning the same preferred camera appeared to trigger Continuity rate renegotiation.
            if AVCaptureDevice.userPreferredCamera?.uniqueID != device.uniqueID { AVCaptureDevice.userPreferredCamera = device }
            var caps = HardwareCapabilities()
            caps.highResolutionPhoto = session.outputs.contains(photoOutput) && photoDimensions != nil
            caps.focusLock = device.isFocusModeSupported(.locked) && device.isFocusModeSupported(.continuousAutoFocus)
            caps.exposureLock = device.isExposureModeSupported(.locked) && device.isExposureModeSupported(.continuousAutoExposure)
            caps.whiteBalanceLock = device.isWhiteBalanceModeSupported(.locked) && device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance)
            session.startRunning()
            // The macOS session can renegotiate activeFormat at commit/start. Apply
            // the requested format after startup, before admitting preview frames.
            if let selected {
                try applyFormat(selected, to: device)
                // Continuity can restore the previous format's frame duration about two
                // seconds after startup. Reapply the selected rate a bounded number of times.
                frameRateRepairs = 0
                frameRateObservation = device.observe(\.activeVideoMinFrameDuration) { [weak self] device, _ in
                    self?.sessionQueue.async { self?.restoreFrameRate(selected, on: device) }
                }
            }
            if session.outputs.contains(photoOutput), let dimensions = largestPhotoDimensions(for: device) {
                photoOutput.maxPhotoDimensions = dimensions
            }
            #if DEBUG
            let active = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
            NSLog("Capture configured: requested %dx%d, active %dx%d", selected?.width ?? 0, selected?.height ?? 0, active.width, active.height)
            #endif
            onConfigured?(device.uniqueID, choices, selected?.id ?? -1, caps)
            frameGate.lock()
            let activeSize = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
            configuredSize = CGSize(width: Int(activeSize.width), height: Int(activeSize.height))
            frameGate.unlock()
            onStatus?(session.isRunning ? "Live · \(device.localizedName)" : "Waiting for camera…")
        } catch {
            onStatus?("Camera setup failed: \(error.localizedDescription)")
        }
    }
    private func applyFormat(_ selected: CameraFormat, to device: AVCaptureDevice) throws {
        try device.lockForConfiguration(); defer { device.unlockForConfiguration() }
        let format = device.formats[selected.id]
        device.activeFormat = format
        if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
        if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
        if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { device.whiteBalanceMode = .continuousAutoWhiteBalance }
        if #available(macOS 15, *), device.activeFormat.isAutoVideoFrameRateSupported, device.isAutoVideoFrameRateEnabled { device.isAutoVideoFrameRateEnabled = false }
        if let duration = frameDuration(for: format) { device.activeVideoMinFrameDuration = duration; device.activeVideoMaxFrameDuration = duration }
    }
    private func frameDuration(for format: AVCaptureDevice.Format) -> CMTime? {
        // Keep exact rational values from the advertised range, including 1/60.
        format.videoSupportedFrameRateRanges.compactMap {
            CaptureTiming.duration(minimum: $0.minFrameDuration, maximum: $0.maxFrameDuration)
        }.min { $0 < $1 }
    }
    private func restoreFrameRate(_ selected: CameraFormat, on device: AVCaptureDevice) {
        guard current === device, session.isRunning, frameRateObservation != nil, frameRateRepairs < 3,
              device.activeFormat == device.formats[selected.id], let duration = frameDuration(for: device.activeFormat),
              device.activeVideoMinFrameDuration != duration || device.activeVideoMaxFrameDuration != duration else { return }
        frameRateRepairs += 1
        do {
            try device.lockForConfiguration(); defer { device.unlockForConfiguration() }
            device.activeVideoMinFrameDuration = duration; device.activeVideoMaxFrameDuration = duration
        } catch { onStatus?("Frame rate change failed: \(error.localizedDescription)") }
    }
    private func largestPhotoDimensions(for device: AVCaptureDevice) -> CMVideoDimensions? {
        device.activeFormat.supportedMaxPhotoDimensions.max { Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height) }
    }
    public func takePhoto(completion: @escaping (Result<CIImage, Error>) -> Void) {
        sessionQueue.async {
            guard let device = self.current, self.session.isRunning, self.session.outputs.contains(self.photoOutput), self.photoCompletion == nil else { completion(.failure(CaptureError.configuration)); return }
            // Device format changes can invalidate the output's previously configured
            // dimensions. Validate both the current format and output at capture time.
            guard let dimensions = self.largestPhotoDimensions(for: device) else { completion(.failure(CaptureError.configuration)); return }
            if self.photoOutput.maxPhotoDimensions.width != dimensions.width || self.photoOutput.maxPhotoDimensions.height != dimensions.height { self.photoOutput.maxPhotoDimensions = dimensions }
            guard device.activeFormat.supportedMaxPhotoDimensions.contains(where: { $0.width == dimensions.width && $0.height == dimensions.height }), dimensions.width <= self.photoOutput.maxPhotoDimensions.width, dimensions.height <= self.photoOutput.maxPhotoDimensions.height else { completion(.failure(CaptureError.configuration)); return }
            self.photoCompletion = completion
            let settings = AVCapturePhotoSettings()
            settings.maxPhotoDimensions = dimensions
            let requestID = settings.uniqueID
            self.photoRequestID = requestID
            self.sessionQueue.asyncAfter(deadline: .now() + 15) {
                guard self.photoRequestID == requestID else { return }
                self.photoCompletion?(.failure(CaptureError.photoTimeout)); self.photoCompletion = nil; self.photoRequestID = nil
            }
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }
    public func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        sessionQueue.async {
            guard self.photoRequestID == photo.resolvedSettings.uniqueID else { return }
            if let error { self.photoCompletion?(.failure(error)) }
            else if let data = photo.fileDataRepresentation(), let image = CIImage(data: data, options: [.applyOrientationProperty: true]) { self.photoCompletion?(.success(image)) }
            else { self.photoCompletion?(.failure(CaptureError.configuration)) }
            self.photoCompletion = nil; self.photoRequestID = nil
        }
    }
    public func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        guard let error else { return }
        sessionQueue.async {
            guard self.photoRequestID == resolvedSettings.uniqueID else { return }
            self.photoCompletion?(.failure(error)); self.photoCompletion = nil; self.photoRequestID = nil
        }
    }
    public func setLocks(focus: Bool, exposure: Bool, whiteBalance: Bool) {
        sessionQueue.async {
            guard let device = self.current else { return }
            do {
                try device.lockForConfiguration(); defer { device.unlockForConfiguration() }
                let f: AVCaptureDevice.FocusMode = focus ? .locked : .continuousAutoFocus
                let e: AVCaptureDevice.ExposureMode = exposure ? .locked : .continuousAutoExposure
                let w: AVCaptureDevice.WhiteBalanceMode = whiteBalance ? .locked : .continuousAutoWhiteBalance
                if device.isFocusModeSupported(f) { device.focusMode = f }
                if device.isExposureModeSupported(e) { device.exposureMode = e }
                if device.isWhiteBalanceModeSupported(w) { device.whiteBalanceMode = w }
            } catch { self.onStatus?("Hardware control failed: \(error.localizedDescription)") }
        }
    }
    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        frameGate.lock(); let size = configuredSize; frameGate.unlock()
        guard size.width > 0, CVPixelBufferGetWidth(buffer) == Int(size.width), CVPixelBufferGetHeight(buffer) == Int(size.height) else { return }
        onFrame?(CIImage(cvPixelBuffer: buffer), CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }
    public func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) { onDrop?() }
    private func startDemo() {
        sessionQueue.async {
            self.isDemo = true; self.frameRateObservation = nil; self.session.stopRunning(); self.current = nil; self.desiredID = nil
            self.onConfigured?("demo", [CameraFormat(id: 0, width: 1920, height: 1080, fps: 30)], 0, HardwareCapabilities())
            self.onStatus?("Demo · generated test footage")
            self.frameQueue.async {
                self.demoTimer?.cancel(); self.demoTick = 0
                let epoch = ProcessInfo.processInfo.systemUptime
                let timer = DispatchSource.makeTimerSource(queue: self.frameQueue)
                timer.schedule(deadline: .now(), repeating: 1.0 / 30)
                timer.setEventHandler { [weak controller = self] in
                    guard let controller else { return }; controller.demoTick += 1
                    let elapsed = ProcessInfo.processInfo.systemUptime - epoch
                    controller.onFrame?(controller.demo.frame(at: elapsed), CMTime(seconds: elapsed, preferredTimescale: 1_000_000))
                }
                self.demoTimer = timer; timer.resume()
            }
        }
    }
    public func stop() {
        sessionQueue.async { self.isDemo = false; self.frameRateObservation = nil; self.session.stopRunning() }
        frameQueue.async { self.demoTimer?.cancel(); self.demoTimer = nil }
    }
    enum CaptureError: LocalizedError {
        case configuration, photoTimeout
        var errorDescription: String? {
            switch self {
            case .configuration: return "The camera could not configure this capture. Reconnect it or select another format."
            case .photoTimeout: return "The camera did not finish the photo within 15 seconds. Reconnect it or use a processed snapshot."
            }
        }
    }
}
