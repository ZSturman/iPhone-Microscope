import AVFoundation
import CoreImage
import UIKit

/// Session mutation and capability checks are confined to sessionQueue.
/// Frame conversion is serial and skips work while the viewer is still consuming a frame.
final class PhoneCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "microscope.phone.capture", qos: .userInitiated)
    private let frameQueue = DispatchQueue(label: "microscope.phone.frames", qos: .userInitiated)
    private let output = AVCaptureVideoDataOutput()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let link: CompanionSession
    private let deviceID: String
    private var devices: [AVCaptureDevice] = []
    private var current: AVCaptureDevice?
    private var state: PhoneCameraState?
    private var pendingCommand: UUID?
    // Only frameQueue accesses these; configure drains the queue before changing them.
    private var frameState: PhoneCameraState?
    private var enabled = false
    private let requestLock = NSLock()
    private var startRequest: UUID?
    private var observers: [NSObjectProtocol] = []
    var onState: ((PhoneCameraState) -> Void)?
    var onError: ((String) -> Void)?
    var onCommandResult: ((UUID, String?) -> Void)?

    init(link: CompanionSession, deviceID: String) {
        self.link = link; self.deviceID = deviceID
        super.init()
        for name in [AVCaptureSession.wasInterruptedNotification, AVCaptureSession.runtimeErrorNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: session, queue: nil) { [weak self] _ in
                self?.stop(); self?.onError?("Camera interrupted. Stop and restart sharing after closing other camera apps.")
            })
        }
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func start(completion: @escaping (Bool) -> Void) {
        let request = UUID()
        requestLock.lock(); startRequest = request; requestLock.unlock()
        let configure = { [weak self] in
            guard let self else { return }
            self.sessionQueue.async {
                self.requestLock.lock(); let active = self.startRequest == request; self.requestLock.unlock()
                guard active else { completion(false); return }
                do {
                    self.devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTelephotoCamera], mediaType: .video, position: .back).devices
                    guard let main = self.devices.first(where: { $0.deviceType == .builtInWideAngleCamera }) ?? self.devices.first else { throw CameraError.unavailable }
                    self.enabled = true
                    try self.configure(main, quality: .hd)
                    completion(true)
                } catch { self.enabled = false; self.onError?(error.localizedDescription); completion(false) }
            }
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: configure()
        case .notDetermined: AVCaptureDevice.requestAccess(for: .video) { granted in
            if granted { configure() } else { self.onError?("Allow Camera in Settings → Privacy & Security → Camera."); completion(false) }
        }
        default: onError?("Allow Camera in Settings → Privacy & Security → Camera."); completion(false)
        }
    }
    func stop() {
        requestLock.lock(); startRequest = nil; requestLock.unlock()
        sessionQueue.async {
            self.enabled = false
            self.pendingCommand = nil
            self.frameQueue.sync { self.frameState = nil }
            if let current = self.current, current.hasTorch, current.isTorchAvailable,
               (try? current.lockForConfiguration()) != nil { current.torchMode = .off; current.unlockForConfiguration() }
            self.session.stopRunning()
        }
    }
    private func qualities(for device: AVCaptureDevice) -> [StreamQuality] {
        StreamQuality.allCases.filter { format(for: device, quality: $0) != nil }
    }
    private func format(for device: AVCaptureDevice, quality: StreamQuality) -> AVCaptureDevice.Format? {
        device.formats.first {
            let dimensions = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            return dimensions.width == quality.width && dimensions.height == quality.height &&
                CMFormatDescriptionGetMediaSubType($0.formatDescription) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange &&
                $0.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= Double(quality.fps) && $0.maxFrameRate >= Double(quality.fps) }
        }
    }
    private func frameRates(for format: AVCaptureDevice.Format) -> [Int] {
        [5, 10, 15, 24, 30].filter { rate in
            format.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= Double(rate) && $0.maxFrameRate >= Double(rate) }
        }
    }
    private func configure(_ device: AVCaptureDevice, quality requested: StreamQuality) throws {
        session.stopRunning()
        frameQueue.sync { frameState = nil }
        let supported = qualities(for: device)
        guard let quality = supported.contains(requested) ? requested : supported.first,
              let format = format(for: device, quality: quality) else { throw CameraError.unsupported }
        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        var open = true
        defer { if open { session.commitConfiguration() } }
        let oldInputs = session.inputs
        oldInputs.forEach { session.removeInput($0) }
        guard session.canAddInput(input) else {
            oldInputs.filter { session.canAddInput($0) }.forEach { session.addInput($0) }
            throw CameraError.unavailable
        }
        session.addInput(input)
        session.sessionPreset = .inputPriority
        if session.outputs.isEmpty {
            output.alwaysDiscardsLateVideoFrames = true
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
            output.setSampleBufferDelegate(self, queue: frameQueue)
            guard session.canAddOutput(output) else { throw CameraError.unavailable }
            session.addOutput(output)
        }
        try device.lockForConfiguration()
        device.activeFormat = format
        if device.isVideoHDREnabled { device.automaticallyAdjustsVideoHDREnabled = false; device.isVideoHDREnabled = false }
        device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(quality.fps))
        device.activeVideoMaxFrameDuration = device.activeVideoMinFrameDuration
        device.videoZoomFactor = device.minAvailableVideoZoomFactor
        if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
        if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
        if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { device.whiteBalanceMode = .continuousAutoWhiteBalance }
        device.setExposureTargetBias(0)
        if device.hasTorch, device.isTorchAvailable { device.torchMode = .off }
        device.unlockForConfiguration()
        if let connection = output.connection(with: .video) {
            if connection.isVideoRotationAngleSupported(0) { connection.videoRotationAngle = 0 }
            if connection.isVideoStabilizationSupported { connection.preferredVideoStabilizationMode = .off }
        }
        session.commitConfiguration(); open = false
        current = device
        session.startRunning()
        publish(device: device, quality: quality)
    }
    private func publish(device: AVCaptureDevice, quality: StreamQuality) {
        let previousRevision = state?.revision ?? 0
        let state = PhoneCameraState(
            deviceID: deviceID, revision: previousRevision + 1,
            lenses: devices.map { PhoneLens(id: $0.uniqueID, name: Self.lensName($0)) }, lensID: device.uniqueID,
            quality: quality, supportedQualities: qualities(for: device),
            zoom: Double(device.videoZoomFactor), minZoom: Double(device.minAvailableVideoZoomFactor),
            maxZoom: min(20, Double(device.maxAvailableVideoZoomFactor)),
            losslessZoomLimit: Double(device.activeFormat.videoZoomFactorUpscaleThreshold),
            manualFocus: device.focusMode == .locked ? Double(device.lensPosition) : nil,
            supportsManualFocus: device.isLockingFocusWithCustomLensPositionSupported,
            supportsFocusLock: device.isFocusModeSupported(.locked) && device.isFocusModeSupported(.continuousAutoFocus),
            supportsExposureLock: device.isExposureModeSupported(.locked) && device.isExposureModeSupported(.continuousAutoExposure),
            supportsWhiteBalanceLock: device.isWhiteBalanceModeSupported(.locked) && device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance),
            focusLocked: device.focusMode == .locked, exposureLocked: device.exposureMode == .locked,
            whiteBalanceLocked: device.whiteBalanceMode == .locked,
            exposureBias: Double(device.exposureTargetBias), minExposureBias: Double(device.minExposureTargetBias), maxExposureBias: Double(device.maxExposureTargetBias),
            supportsTorch: device.hasTorch && device.isTorchAvailable, torch: device.torchMode == .on,
            minimumFocusDistanceMM: device.minimumFocusDistance > 0 ? device.minimumFocusDistance : nil,
            depthAvailable: !device.activeFormat.supportedDepthDataFormats.isEmpty,
            frameRate: Int((1 / device.activeVideoMinFrameDuration.seconds).rounded()),
            supportedFrameRates: frameRates(for: device.activeFormat))
        self.state = state
        // Network state goes out before frames carrying this revision.
        link.publish(state); onState?(state)
        frameQueue.sync { frameState = state }
    }
    static func lensName(_ device: AVCaptureDevice) -> String {
        switch device.deviceType {
        case .builtInUltraWideCamera: return "Ultra Wide · close focus"
        case .builtInTelephotoCamera: return "Telephoto"
        default: return "Main"
        }
    }
    func apply(_ command: PhoneCameraCommand, id: UUID) {
        sessionQueue.async { [self] in
            guard self.enabled, let device = self.current, let state = self.state else {
                self.reply(id: id, error: "Camera is stopped. Restart sharing on the iPhone."); return
            }
            guard self.pendingCommand == nil else { self.reply(id: id, error: "Camera is applying another setting."); return }
            self.pendingCommand = id
            var asynchronous = false
            defer { if !asynchronous { self.pendingCommand = nil } }
            do {
                switch command {
                case .lens(let lensID):
                    guard let lens = self.devices.first(where: { $0.uniqueID == lensID }) else { throw CameraError.unsupported }
                    try self.configure(lens, quality: state.quality)
                case .quality(let quality):
                    guard self.qualities(for: device).contains(quality) else { throw CameraError.unsupported }
                    try self.configure(device, quality: quality)
                default:
                    // Exclude already queued buffers during geometry changes.
                    self.frameQueue.sync { self.frameState = nil }
                    try device.lockForConfiguration()
                    do {
                        if case .focus(let value?) = command {
                            guard value.isFinite, (0...1).contains(value), device.isLockingFocusWithCustomLensPositionSupported else { throw CameraError.unsupported }
                            asynchronous = true
                            device.setFocusModeLocked(lensPosition: Float(value)) { [weak self] _ in self?.completeAdjustment(id: id, device: device, quality: state.quality) }
                        } else if case .exposure(let value) = command {
                            guard value.isFinite else { throw CameraError.unsupported }
                            asynchronous = true
                            device.setExposureTargetBias(min(device.maxExposureTargetBias, max(device.minExposureTargetBias, Float(value)))) { [weak self] _ in self?.completeAdjustment(id: id, device: device, quality: state.quality) }
                        } else { try self.applyLocked(command, to: device) }
                        device.unlockForConfiguration()
                    }
                    catch { device.unlockForConfiguration(); throw error }
                    if asynchronous { return }
                    self.publish(device: device, quality: state.quality)
                }
                self.reply(id: id, error: nil)
            } catch {
                // Restore a usable camera and publish what actually applied, including after partial failure.
                if !self.session.isRunning { try? self.configure(device, quality: state.quality) }
                else { self.publish(device: device, quality: state.quality) }
                self.reply(id: id, error: error.localizedDescription)
            }
        }
    }
    private func reply(id: UUID, error: String?) {
        link.reply(id: id, error: error); onCommandResult?(id, error)
    }
    private func completeAdjustment(id: UUID, device: AVCaptureDevice, quality: StreamQuality) {
        sessionQueue.async {
            guard self.enabled, self.pendingCommand == id, self.current?.uniqueID == device.uniqueID else { return }
            self.pendingCommand = nil
            self.publish(device: device, quality: quality)
            self.reply(id: id, error: nil)
        }
    }
    private func applyLocked(_ command: PhoneCameraCommand, to device: AVCaptureDevice) throws {
        switch command {
        case .frameRate(let rate):
            guard frameRates(for: device.activeFormat).contains(rate) else { throw CameraError.unsupported }
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(rate))
            device.activeVideoMaxFrameDuration = device.activeVideoMinFrameDuration
        case .zoom(let value):
            guard value.isFinite else { throw CameraError.unsupported }
            device.videoZoomFactor = min(device.maxAvailableVideoZoomFactor, max(device.minAvailableVideoZoomFactor, CGFloat(min(20, value))))
        case .focus(let value):
            if let value {
                guard value.isFinite, (0...1).contains(value), device.isLockingFocusWithCustomLensPositionSupported else { throw CameraError.unsupported }
                device.setFocusModeLocked(lensPosition: Float(value))
            } else {
                guard device.isFocusModeSupported(.continuousAutoFocus) else { throw CameraError.unsupported }
                device.focusMode = .continuousAutoFocus
            }
        case .exposure(let value):
            guard value.isFinite else { throw CameraError.unsupported }
            device.setExposureTargetBias(min(device.maxExposureTargetBias, max(device.minExposureTargetBias, Float(value))))
        case .torch(let on):
            guard device.hasTorch, device.isTorchAvailable, device.isTorchModeSupported(on ? .on : .off) else { throw CameraError.unsupported }
            if on { try device.setTorchModeOn(level: 0.3) } else { device.torchMode = .off }
        case .locks(let focus, let exposure, let whiteBalance):
            // Unsupported controls leave their existing mode alone.
            let f: AVCaptureDevice.FocusMode = focus ? .locked : .continuousAutoFocus
            let e: AVCaptureDevice.ExposureMode = exposure ? .locked : .continuousAutoExposure
            let w: AVCaptureDevice.WhiteBalanceMode = whiteBalance ? .locked : .continuousAutoWhiteBalance
            if device.isFocusModeSupported(f) { device.focusMode = f }
            if device.isExposureModeSupported(e) { device.exposureMode = e }
            if device.isWhiteBalanceModeSupported(w) { device.whiteBalanceMode = w }
        default: throw CameraError.unsupported
        }
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let state = frameState, link.canSendFrame, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              CVPixelBufferGetWidth(buffer) == state.quality.width, CVPixelBufferGetHeight(buffer) == state.quality.height else { return }
        autoreleasepool {
            let image = CIImage(cvPixelBuffer: buffer)
            guard let data = context.jpegRepresentation(of: image, colorSpace: CGColorSpaceCreateDeviceRGB(), options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.88]), data.count <= CompanionPacket.maxJPEG else { return }
            link.sendFrame(jpeg: data, revision: state.revision, seconds: CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds, width: state.quality.width, height: state.quality.height)
        }
    }
    enum CameraError: LocalizedError {
        case unavailable, unsupported
        var errorDescription: String? {
            switch self {
            case .unavailable: return "Camera unavailable. Close Camera, FaceTime or Continuity Camera, then restart sharing."
            case .unsupported: return "This lens does not support that camera setting."
            }
        }
    }
}
