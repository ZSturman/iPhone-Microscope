import SwiftUI
import AVFoundation
import CoreImage
import UniformTypeIdentifiers
import Security
import Vision

/// A source switch invalidates queued presentation/remote work without sharing UI state across queues.
final class FrameSourceGate {
    private let lock = NSLock()
    private var token = UUID()
    private var remote = false
    func select(remote: Bool) { lock.lock(); self.remote = remote; token = UUID(); lock.unlock() }
    func current(remote: Bool) -> UUID? { lock.lock(); defer { lock.unlock() }; return self.remote == remote ? token : nil }
    func accepts(_ token: UUID) -> Bool { lock.lock(); defer { lock.unlock() }; return self.token == token }
}

final class SharedPipeline {
    private let lock = NSLock()
    private var settings = PipelineSettings()
    private var record = false
    private var original = false
    func update(_ settings: PipelineSettings, record: Bool, original: Bool) { lock.lock(); defer { lock.unlock() }; self.settings = settings; self.record = record; self.original = original }
    func read() -> (PipelineSettings, Bool, Bool) { lock.lock(); defer { lock.unlock() }; return (settings, record, original) }
}

final class AppModel: ObservableObject {
    @Published var preferences: Preferences {
        didSet {
            shared.update(preferences.pipeline, record: recording, original: recordingOriginal)
            saveWork?.cancel()
            let data = try? JSONEncoder().encode(preferences)
            let work = DispatchWorkItem { if let data { self.defaults.set(data, forKey: "preferences.v1") } }
            saveWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
            if frozen, let frozenBase {
                cleanImage = ImageProcessor.present(frozenBase, settings: preferences.pipeline)
                image = ImageProcessor.preview(frozenBase, settings: preferences.pipeline)
            }
            if oldValue.pipeline.stabilization != preferences.pipeline.stabilization { frozen = false; frozenBase = nil; frozenSource = nil }
            if oldValue.pipeline.viewport != preferences.pipeline.viewport || oldValue.pipeline.image.rotation != preferences.pipeline.image.rotation || oldValue.pipeline.image.flipH != preferences.pipeline.image.flipH || oldValue.pipeline.image.flipV != preferences.pipeline.image.flipV || oldValue.pipeline.stabilization != preferences.pipeline.stabilization { measurement = nil }
        }
    }
    @Published var showingSetup = false
    @Published var pairingInvitation: PairingInvitation?
    @Published var cameras: [CameraChoice] = []
    @Published var formats: [CameraFormat] = []
    @Published var cameraID = ""
    @Published var formatID = -1
    @Published var capabilities = HardwareCapabilities()
    @Published var status = "Choose a camera, or explore the demo"
    @Published var image: CIImage?
    @Published var reference: CIImage?
    @Published var frozen = false
    @Published var comparing = false
    @Published var sourceSize = CGSize.zero
    @Published var focus = 0.0
    @Published var fps = 0.0
    @Published var tracking = "Off"
    @Published var dropped = 0
    @Published var recording = false
    @Published var finalizing = false
    @Published var recordStarting = false
    @Published var recordingStart: Date?
    @Published var recentSnapshots: [URL] = []
    @Published var snapshotBusy = false
    @Published var measuring = false
    @Published var measurement: Measurement?
    @Published var errorMessage: String?
    @Published var focusLocked = false
    @Published var exposureLocked = false
    @Published var whiteBalanceLocked = false
    @Published var companionReconnectPaused = false
    @Published var companionPeers: [CompanionSession.Peer] = []
    @Published var companionPeerID = ""
    @Published var companionCode = ""
    @Published var companionState: PhoneCameraState?
    @Published var companionStatus = "Start sharing in Microscope Camera on your iPhone."
    @Published var awaitingCameraFrame = false
    @Published var selectingWorkArea = false
    private var queuedZoom: Double?
    private var zoomWork: DispatchWorkItem?
    @Published var companionPending: UUID?
    @Published var showingShortcuts = true {
        didSet { defaults.set(!showingShortcuts, forKey: "keyboardGuideDismissed") }
    }
    private let defaults: UserDefaults
    private let capture = CaptureController()
    private lazy var companion = CompanionSession(role: .viewer, name: Host.current().localizedName ?? "Mac Microscope", rememberConnections: !ProcessInfo.processInfo.arguments.contains("--companion-smoke-test"))
    private var companionConfigured = false
    private let sourceGate = FrameSourceGate()
    // Only capture.frameQueue accesses this value.
    private var companionRevision = -1
    private let processor = ImageProcessor()
    private let recorder = FrameRecorder()
    private let shared = SharedPipeline()
    private let ioQueue = DispatchQueue(label: "microscope.snapshots", qos: .utility)
    private var lastSource: CIImage?
    private var lastBase: CIImage?
    private var cleanImage: CIImage?
    private var frozenBase: CIImage?
    private var frozenSource: CIImage?
    private var saveWork: DispatchWorkItem?
    private var outputAccess: URL?
    private var recordURL: URL?
    private var recordingOriginal = false
    private var lastFrameDate = Date.distantPast
    private var watchdog: Timer?
    // Single-slot mailbox keeps main-thread delays from retaining an unbounded number of camera buffers.
    private let mailboxLock = NSLock()
    private var mailbox: (ProcessedFrame, Double, UUID)?
    private var deliveryScheduled = false
    private var frameCount = 0
    private var fpsEpoch = ProcessInfo.processInfo.systemUptime
    private var latestFPS = 0.0

    init() {
        defaults = (ProcessInfo.processInfo.arguments.contains("--smoke-test") || ProcessInfo.processInfo.arguments.contains("--iphone-smoke-test") || ProcessInfo.processInfo.arguments.contains("--companion-smoke-test")) ? UserDefaults(suiteName: "com.local.iPhoneMicroscope.Smoke")! : .standard
        preferences = SettingsStore.load(from: defaults)
        showingShortcuts = defaults.object(forKey: "keyboardGuideDismissed") != nil && !defaults.bool(forKey: "keyboardGuideDismissed")
        if let bookmark = defaults.data(forKey: "outputFolder.bookmark") {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], bookmarkDataIsStale: &stale), url.startAccessingSecurityScopedResource() {
                outputAccess = url; preferences.outputPath = url.path
                if stale, let refreshed = try? url.bookmarkData(options: [.withSecurityScope]) { defaults.set(refreshed, forKey: "outputFolder.bookmark") }
            }
        }
        // A store upgrade can inherit an external development-build folder without a bookmark.
        // Start in private app storage until the user grants a folder in the picker.
        let sandboxed = SecTaskCreateFromSelf(nil).flatMap {
            SecTaskCopyValueForEntitlement($0, "com.apple.security.app-sandbox" as CFString, nil) as? Bool
        } ?? false
        if sandboxed, outputAccess == nil {
            preferences.outputPath = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("iPhone Microscope/Captures", isDirectory: true).path
        }
        recentSnapshots = preferences.snapshotPaths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        shared.update(preferences.pipeline, record: false, original: false)
        capture.onDevices = { [weak self] devices in DispatchQueue.main.async { self?.cameras = devices } }
        capture.onStatus = { [weak self] status in DispatchQueue.main.async {
            guard let self, !self.isCompanion else { return }; self.status = status
            if status.contains("disconnected") || status.contains("interrupted") || status.contains("failed") { self.image = nil; self.lastSource = nil; if self.recording { self.stopRecording() } }
        } }
        capture.onConfigured = { [weak self] id, formats, selected, capabilities in DispatchQueue.main.async {
            guard let self, !self.isCompanion else { return }
            self.cameraID = id; self.formats = formats; self.formatID = selected; self.capabilities = capabilities
            self.focusLocked = false; self.exposureLocked = false; self.whiteBalanceLocked = false
            self.image = nil; self.lastSource = nil; self.lastBase = nil
            self.measurement = nil; self.reference = nil; self.comparing = false; self.frozen = false; self.sourceSize = .zero
        } }
        capture.onDrop = { [weak self] in DispatchQueue.main.async { self?.dropped += 1 } }
        recorder.onDrop = { [weak self] in DispatchQueue.main.async { self?.dropped += 1 } }
        recorder.onError = { [weak self] error in DispatchQueue.main.async { self?.errorMessage = error; self?.stopRecording() } }
        capture.onFrame = { [weak self] input, time in
            guard let self, let token = self.sourceGate.current(remote: false) else { return }
            self.processFrame(input, at: time, token: token)
        }
        showingSetup = preferences.lastCamera.isEmpty
        capture.refresh()
        watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, !self.cameraID.isEmpty else { return }
            if Date().timeIntervalSince(self.lastFrameDate) > 3 && self.lastFrameDate != .distantPast {
                self.fps = 0; self.status = self.isCompanion ? "No frames · keep Microscope Camera open and unlocked; reconnect under iPhone companion" : "No frames · unlock, then lock and mount iPhone; reselect camera to retry"
                if self.isCompanion { self.companionStatus = self.status }
                self.lastSource = nil
                if !self.frozen && !self.isCompanion { self.image = nil }
                if self.isCompanion { self.awaitingCameraFrame = true }
                if self.recording { self.stopRecording() }
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--companion") { selectCamera("companion") }
        else if ProcessInfo.processInfo.arguments.contains("--demo") || ProcessInfo.processInfo.arguments.contains("--smoke-test") { selectCamera("demo") }
        else if !ProcessInfo.processInfo.arguments.contains("--iphone-smoke-test"), !ProcessInfo.processInfo.arguments.contains("--companion-smoke-test"), !preferences.lastCamera.isEmpty { selectCamera(preferences.lastCamera) }
    }
    private func processFrame(_ input: CIImage, at time: CMTime, token: UUID) {
        guard sourceGate.accepts(token) else { return }
        let (settings, record, original) = shared.read()
        let frame = processor.process(input, settings: settings)
        if record { recorder.append(original ? input : frame.image, at: time) }
        frameCount += 1
        let now = ProcessInfo.processInfo.systemUptime
        if now - fpsEpoch >= 0.5 { latestFPS = Double(frameCount) / (now - fpsEpoch); frameCount = 0; fpsEpoch = now }
        mailboxLock.lock(); mailbox = (frame, latestFPS, token)
        let schedule = !deliveryScheduled; deliveryScheduled = true; mailboxLock.unlock()
        if schedule { DispatchQueue.main.async { [weak self] in self?.deliverFrame() } }
    }
    private func deliverFrame() {
        mailboxLock.lock(); let value = mailbox; mailbox = nil; deliveryScheduled = false; mailboxLock.unlock()
        guard let (frame, fps, token) = value, sourceGate.accepts(token) else { return }
        if self.fps == 0 && status.hasPrefix("No frames") { status = "Live · frames resumed" }
        if isCompanion, companionStatus == "Paired · waiting for camera frames" || companionStatus.hasPrefix("No frames") {
            companionStatus = "Streaming · camera frames received"
        }
        if cameraID != "demo", preferences.lastCamera != cameraID { defaults.set(true, forKey: "setup.connected"); preferences.lastCamera = cameraID }
        if image == nil { showingSetup = false }
        lastFrameDate = Date(); self.fps = fps; sourceSize = frame.source.extent.size
        lastSource = frame.source; lastBase = frame.stabilized; focus = frame.focus; tracking = frame.tracking
        awaitingCameraFrame = false
        if !frozen { cleanImage = frame.image; image = frame.preview }
    }
    var peakingEnabled: Bool {
        get { preferences.pipeline.peaking?.enabled ?? false }
        set { var value = preferences.pipeline.peaking ?? FocusPeakingSettings(); value.enabled = newValue; preferences.pipeline.peaking = value }
    }
    var peakingSensitivity: Double {
        get { preferences.pipeline.peaking?.sensitivity ?? 0.5 }
        set { var value = preferences.pipeline.peaking ?? FocusPeakingSettings(); value.sensitivity = newValue; preferences.pipeline.peaking = value }
    }
    var busy: Bool { recording || finalizing || recordStarting }
    var isCompanion: Bool { cameraID == "companion" }
    var canConnectCompanion: Bool { isCompanion && !busy && PairingInvitation.validCode(companionCode) && !companionPeerID.isEmpty }
    var canCapture: Bool { image != nil && lastSource != nil && (!isCompanion || (companionState != nil && companionPending == nil)) }
    func selectCamera(_ id: String) {
        guard !busy else { return }
        queuedZoom = nil; zoomWork?.cancel(); zoomWork = nil; awaitingCameraFrame = false
        sourceGate.select(remote: id == "companion")
        companionState = nil; companionPending = nil
        if companionConfigured { companion.disconnect() }
        image = nil; lastSource = nil; fps = 0; cameraID = id; status = "Connecting…"; lastFrameDate = .distantPast
        // Remember only a camera that actually delivers a frame.
        capture.frameQueue.async { self.processor.reset(); self.frameCount = 0; self.fpsEpoch = ProcessInfo.processInfo.systemUptime; self.latestFPS = 0 }
        if id == "companion" {
            companionReconnectPaused = false
            if !companionConfigured { configureCompanion(); companionConfigured = true }
            capture.stop(); formats = []; formatID = -1; capabilities = HardwareCapabilities()
            clearCompanionImage(); preferences.activeProfile = nil; preferences.inspector = true
            companion.browse(); status = "Open Microscope Camera on iPhone to connect"
            return
        }
        capture.select(id: id, formatID: preferences.formatIDs[id])
    }
    func selectFormat(_ id: Int) { guard !busy, !isCompanion else { return }; preferences.formatIDs[cameraID] = id; fps = 0; image = nil; lastSource = nil; capture.frameQueue.async { self.processor.reset(); self.frameCount = 0; self.fpsEpoch = ProcessInfo.processInfo.systemUptime; self.latestFPS = 0 }; capture.select(id: cameraID, formatID: id) }
    func refreshLocalCameras() { capture.refresh() }
    func prepareCompanionSetup() {
        guard !busy else { return }
        if !isCompanion { selectCamera("companion") }
        else if !companionReconnectPaused { companion.browse() }
        guard !companionReconnectPaused else { return }
        if pairingInvitation == nil || pairingInvitation!.expires <= Date() { renewPairingInvitation() }
    }
    func renewPairingInvitation() {
        companionReconnectPaused = false; companion.browse()
        let invitation = PairingInvitation(viewerID: companion.installationID, code: String(format: "%06d", Int.random(in: 0...999_999)))
        pairingInvitation = invitation; companion.offerPairing(invitation)
    }
    func forgetCompanion() {
        guard !busy else { return }; companion.forgetCompanion(); companionCode = ""; companionReconnectPaused = false
        companion.browse(); renewPairingInvitation()
        preferences.lastCamera = ""; defaults.removeObject(forKey: "setup.connected")
    }
    func refresh() {
        if isCompanion { guard !busy else { return }; companionReconnectPaused = false; companion.stop(); companion.browse() }
        else { capture.refresh() }
    }
    func locksChanged() {
        if isCompanion { sendCompanion(.locks(focus: focusLocked, exposure: exposureLocked, whiteBalance: whiteBalanceLocked)) }
        else { capture.setLocks(focus: focusLocked, exposure: exposureLocked, whiteBalance: whiteBalanceLocked) }
    }
    func resetView() { preferences.pipeline.viewport = Viewport(); measurement = nil }
    func enhance() { preferences.pipeline.image.contrast = 1.2; preferences.pipeline.image.sharpness = 0.45; preferences.pipeline.image.brightness = 0.025 }
    func toggleFreeze() {
        guard image != nil else { return }
        frozen.toggle()
        frozenBase = frozen ? lastBase : nil; frozenSource = frozen ? lastSource : nil
    }
    func setReference() { reference = cleanImage; comparing = reference != nil }
    func clearReference() { reference = nil; comparing = false }
    var activeCalibration: Calibration? {
        if isCompanion && (companionState == nil || companionPending != nil) { return nil }
        guard let profile = preferences.profiles.first(where: { $0.id == preferences.activeProfile }), profile.matches(cameraID: calibrationCameraID, size: sourceSize, configuration: preferences.opticalConfiguration) else { return nil }
        return profile
    }
    private var calibrationCameraID: String {
        guard isCompanion, let state = companionState, let token = sourceGate.current(remote: true) else { return cameraID }
        // Companion profiles deliberately require recalibration after every camera command/reconnection.
        return "companion:\(state.deviceID):\(state.lensID):\(token):\(state.revision)"
    }
    var displayedSourceSize: CGSize {
        preferences.pipeline.image.rotation % 2 == 0 ? sourceSize : CGSize(width: sourceSize.height, height: sourceSize.width)
    }
    var sourcePixelScale: Double { (1 - 2 * preferences.pipeline.stabilization.margin) / preferences.pipeline.viewport.zoom }
    var measurementPixels: Double { (measurement?.pixels(in: displayedSourceSize) ?? 0) * sourcePixelScale }
    var measurementLabel: String {
        guard measurement != nil else { return "Drag a line on the image" }
        if let profile = activeCalibration { return String(format: "%.2f µm", measurementPixels * profile.micrometersPerPixel) }
        return String(format: "%.1f source px · uncalibrated", measurementPixels)
    }
    func calibrate(name: String, micrometers: Double) {
        guard let profile = Calibration(name: name.isEmpty ? "Calibration" : name, cameraID: calibrationCameraID, size: sourceSize, opticalConfiguration: preferences.opticalConfiguration, pixels: measurementPixels, micrometers: micrometers) else { errorMessage = "Draw a nonzero line over a known length and enter a positive size."; return }
        preferences.profiles.append(profile); preferences.activeProfile = profile.id
    }
    func chooseDirectory() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            outputAccess?.stopAccessingSecurityScopedResource(); outputAccess = nil
            if url.startAccessingSecurityScopedResource() { outputAccess = url }
            preferences.outputPath = url.path
            if let bookmark = try? url.bookmarkData(options: [.withSecurityScope]) { defaults.set(bookmark, forKey: "outputFolder.bookmark") }
        }
    }
    private func outputURL(extension ext: String) throws -> URL {
        let directory = URL(fileURLWithPath: preferences.outputPath, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
        return directory.appendingPathComponent("Microscope_\(formatter.string(from: Date()))_\(UUID().uuidString.prefix(4)).\(ext)")
    }
    func toggleRecording() { if recording { stopRecording() } else { startRecording() } }
    private func startRecording() {
        guard !busy, let image, let lastSource else { return }
        do {
            let url = try outputURL(extension: preferences.videoFormat)
            recordingOriginal = preferences.originalRecording; recordStarting = true
            recorder.start(url: url, size: (recordingOriginal ? lastSource : image).extent.size) { [weak self] error in DispatchQueue.main.async {
                guard let self else { return }; self.recordStarting = false
                if let error { self.errorMessage = error.localizedDescription; return }
                self.recordURL = url; self.recording = true; self.recordingStart = Date()
                self.shared.update(self.preferences.pipeline, record: true, original: self.recordingOriginal)
            } }
        } catch { errorMessage = error.localizedDescription }
    }
    func stopRecording() {
        guard recording else { return }
        recording = false; finalizing = true
        shared.update(preferences.pipeline, record: false, original: recordingOriginal)
        // Queue behind any in-flight processing so every accepted frame reaches the writer before stop.
        capture.frameQueue.async {
            self.recorder.stop { [weak model = self] error in DispatchQueue.main.async {
                guard let self = model else { return }; self.finalizing = false; self.recordingStart = nil
                if let error { self.errorMessage = error.localizedDescription }
                else if let url = self.recordURL { self.status = "Saved \(url.lastPathComponent)" }
            } }
        }
    }
    func snapshot() {
        guard !snapshotBusy, canCapture else { return }
        do {
            let url = try outputURL(extension: preferences.imageFormat)
            snapshotBusy = true
            if preferences.originalSnapshot && capabilities.highResolutionPhoto && !frozen {
                capture.takePhoto { [weak self] result in
                    switch result {
                    case .success(let image): self?.writeSnapshot(image, url: url)
                    case .failure(let error): DispatchQueue.main.async { self?.snapshotBusy = false; self?.errorMessage = error.localizedDescription }
                    }
                }
            } else if let selected = preferences.originalSnapshot ? (frozen ? frozenSource : lastSource) : cleanImage { writeSnapshot(selected, url: url) }
            else { snapshotBusy = false }
        } catch { errorMessage = error.localizedDescription }
    }
    private func writeSnapshot(_ image: CIImage, url: URL) {
        ioQueue.async { [weak self] in
            do {
                let context = CIContext(options: [.cacheIntermediates: false])
                if url.pathExtension == "png" { try context.writePNGRepresentation(of: image, to: url, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()) }
                else { try context.writeJPEGRepresentation(of: image, to: url, colorSpace: CGColorSpaceCreateDeviceRGB(), options: [:]) }
                DispatchQueue.main.async { guard let self else { return }; self.snapshotBusy = false; self.recentSnapshots.insert(url, at: 0); self.recentSnapshots = Array(self.recentSnapshots.prefix(12)); self.preferences.snapshotPaths = self.recentSnapshots.map(\.path); self.status = "Saved \(url.lastPathComponent)" }
            } catch { DispatchQueue.main.async { self?.snapshotBusy = false; self?.errorMessage = error.localizedDescription } }
        }
    }
    func shutdown() { outputAccess?.stopAccessingSecurityScopedResource(); watchdog?.invalidate(); if companionConfigured { companion.stop() }; capture.stop(); if let data = try? JSONEncoder().encode(preferences) { self.defaults.set(data, forKey: "preferences.v1") } }

    private func configureCompanion() {
        companion.onPeers = { [weak self] peers in DispatchQueue.main.async {
            guard let self else { return }
            self.companionPeers = peers
            guard self.isCompanion else { return }
            if !peers.contains(where: { $0.id == self.companionPeerID }) { self.companionPeerID = peers.first?.id ?? "" }
        } }
        companion.onStatus = { [weak self] message in DispatchQueue.main.async {
            guard let self else { return }; self.companionStatus = message
            #if DEBUG
            NSLog("Companion status: %@", message)
            #endif
            if self.isCompanion { self.status = message }
        } }
        companion.onDisconnected = { [weak self] in DispatchQueue.main.async {
            guard let self, self.isCompanion else { return }
            self.sourceGate.select(remote: true)
            self.queuedZoom = nil
            self.companionState = nil; self.companionPending = nil
            self.preferences.activeProfile = nil; self.clearCompanionImage(preservePreview: true)
            if self.recording { self.stopRecording() }
        } }
        companion.onState = { [weak self] state in
            guard let self, let token = self.sourceGate.current(remote: true) else { return }
            self.capture.frameQueue.async {
                guard self.sourceGate.accepts(token) else { return }
                self.companionRevision = state.revision; self.processor.reset()
                DispatchQueue.main.async {
                    guard self.sourceGate.accepts(token), self.isCompanion else { return }
                    let changed = self.companionState != state
                    self.companionState = state
                    if changed {
                        self.preferences.activeProfile = nil; self.clearCompanionImage(preservePreview: true)
                        if self.recording { self.stopRecording() }
                    }
                    self.status = "Live · iPhone companion · \(state.quality.label) · capture \(state.captureFPS) fps"
                }
            }
        }
        companion.onFrame = { [weak self] info, jpeg, acknowledge in
            guard let self, let token = self.sourceGate.current(remote: true) else { acknowledge(); return }
            self.capture.frameQueue.async {
                defer { acknowledge() }
                guard self.sourceGate.accepts(token), info.revision == self.companionRevision,
                      let input = CIImage(data: jpeg), input.extent.width == CGFloat(info.width), input.extent.height == CGFloat(info.height) else { return }
                self.processFrame(input, at: CMTime(seconds: info.seconds, preferredTimescale: 1_000_000), token: token)
            }
        }
        companion.onReply = { [weak self] id, error in DispatchQueue.main.async {
            guard let self, self.companionPending == id else { return }
            self.companionPending = nil
            if let error { self.queuedZoom = nil; self.errorMessage = error }
            else { self.flushCameraZoom() }
        } }
    }
    private func clearCompanionImage(preservePreview: Bool = false) {
        if !preservePreview { image = nil }; awaitingCameraFrame = preservePreview && image != nil; lastSource = nil; lastBase = nil; frozenBase = nil; frozenSource = nil
        sourceSize = .zero; fps = 0; lastFrameDate = .distantPast
        frozen = false; reference = nil; comparing = false; measurement = nil
    }
    func connectCompanion() {
        guard canConnectCompanion else { return }; companionReconnectPaused = false
        sourceGate.select(remote: true); companionState = nil; clearCompanionImage(); preferences.activeProfile = nil
        companion.connect(to: companionPeerID, code: companionCode)
    }
    func disconnectCompanion() { guard !busy else { return }; companionReconnectPaused = true; companion.disconnect(); showingSetup = true }
    func primaryZoom(by factor: Double) {
        if isCompanion, let state = companionState {
            requestCameraZoom(min(state.maxZoom, max(state.minZoom, (queuedZoom ?? state.zoom) * factor)))
        } else { preferences.pipeline.viewport.zoom(to: preferences.pipeline.viewport.zoom * factor) }
    }
    func requestCameraZoom(_ value: Double) {
        guard isCompanion, !busy, let state = companionState else { return }
        queuedZoom = min(state.maxZoom, max(state.minZoom, value))
        guard zoomWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.zoomWork = nil; self?.flushCameraZoom() }
        zoomWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }
    private func flushCameraZoom() {
        guard companionPending == nil, let value = queuedZoom else { return }
        queuedZoom = nil; sendCompanion(.zoom(value))
    }
    func suggestWorkArea() {
        guard let image, let token = sourceGate.current(remote: isCompanion) else { return }
        ioQueue.async {
            let context = CIContext(options: [.cacheIntermediates: false])
            guard let cgImage = context.createCGImage(image, from: image.extent) else { return }
            let request = VNGenerateAttentionBasedSaliencyImageRequest()
            do {
                try VNImageRequestHandler(cgImage: cgImage).perform([request])
                let region = request.results?.first?.salientObjects?.max(by: { $0.confidence < $1.confidence })?.boundingBox
                DispatchQueue.main.async {
                    guard self.sourceGate.accepts(token) else { return }
                    guard let region else { self.selectingWorkArea = true; return }
                    let rect = region.insetBy(dx: -0.03, dy: -0.03).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
                    self.selectWorkArea(rect.origin, CGPoint(x: rect.maxX, y: rect.maxY))
                }
            } catch { DispatchQueue.main.async { self.selectingWorkArea = true } }
        }
    }
    func selectWorkArea(_ a: CGPoint, _ b: CGPoint) {
        guard abs(a.x - b.x) > 0.02, abs(a.y - b.y) > 0.02 else { return }
        var area = WorkAreaSettings()
        area.x = min(a.x, b.x); area.y = min(a.y, b.y)
        area.width = abs(a.x - b.x); area.height = abs(a.y - b.y)
        preferences.pipeline.workArea = area; selectingWorkArea = false
    }
    func sendCompanion(_ command: PhoneCameraCommand) {
        guard isCompanion, !busy, companionState != nil, companionPending == nil else { return }
        let id = UUID(); companionPending = id; preferences.activeProfile = nil
        sourceGate.select(remote: true)
        capture.frameQueue.async { self.companionRevision = -1; self.processor.reset() }
        // Hide stale optical geometry as soon as the command is sent.
        clearCompanionImage(preservePreview: true)
        companion.command(command, id: id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self, self.companionPending == id else { return }
            self.companionPending = nil; self.queuedZoom = nil; self.companion.disconnect()
            self.errorMessage = "The iPhone did not acknowledge the camera change. Keep its app open, then reconnect."
        }
    }
}
