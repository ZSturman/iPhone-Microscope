import SwiftUI
import AVFoundation
import TipKit

@main
struct MicroscopeCameraApp: App {
    @StateObject private var model = PhoneModel()
    @Environment(\.scenePhase) private var scenePhase
    init() { try? Tips.configure([.datastoreLocation(.applicationDefault)]) }
    var body: some Scene {
        WindowGroup {
            PhoneView(model: model)
                .onChange(of: scenePhase) { _, phase in
                    if phase != .active { model.restoreScreen() }
                    if phase == .background { model.suspend() }
                    else if phase == .active { model.resumeIfNeeded() }
                }
                .onOpenURL { model.acceptInvitation($0) }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    if let url = activity.webpageURL { model.acceptInvitation(url) }
                }
        }
    }
}

final class PhoneModel: ObservableObject {
    @Published var status = "Open iPhone Microscope on your Mac to get started."
    @Published var paired = false
    @Published var scanning = false
    @Published var invitation: PairingInvitation?
    @Published var setupError: String?
    @Published var showingHelp = false
    @Published var screenDark = false
    private var previousBrightness: CGFloat?
    @Published var localCommandPending = false
    private var localCommandID: UUID?
    private var resumeSharing = false
    @Published var code = ""
    @Published var running = false
    @Published var starting = false
    @Published var state: PhoneCameraState?
    let link: CompanionSession
    let capture: PhoneCapture
    private var generation = UUID()

    init() {
        let link = CompanionSession(role: .camera, name: UIDevice.current.name)
        self.link = link
        let key = "companion.deviceID"
        let id = UserDefaults.standard.string(forKey: key) ?? UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        capture = PhoneCapture(link: link, deviceID: id)
        link.onStatus = { [weak self] message in DispatchQueue.main.async {
            guard let self, self.running || self.starting else { return }; self.status = message
        } }
        link.onAuthorized = { [weak self] in DispatchQueue.main.async {
            guard let self else { return }; self.paired = true; self.invitation = nil
            UserDefaults.standard.set(true, forKey: "companion.hasConnected")
        } }
        link.onCommand = { [weak self] id, command in self?.capture.apply(command, id: id) }
        link.onDisconnected = { [weak self] in
            // A lost viewer must not leave the light on unattended.
            self?.capture.apply(.torch(false), id: UUID())
            DispatchQueue.main.async { self?.paired = false; self?.restoreScreen() }
        }
        capture.onCommandResult = { [weak self] id, error in DispatchQueue.main.async {
            guard let self, self.localCommandID == id else { return }
            self.localCommandID = nil; self.localCommandPending = false
            if let error { self.setupError = error }
        } }
        capture.onState = { [weak self] state in DispatchQueue.main.async { self?.state = state } }
        capture.onError = { [weak self] message in DispatchQueue.main.async {
            guard let self, self.running || self.starting else { return }; self.stop(); self.status = message
        } }
    }
    func darkenScreen() {
        guard running, paired, !screenDark else { return }
        previousBrightness = UIScreen.main.brightness
        UIScreen.main.brightness = 0
        screenDark = true
    }
    func restoreScreen() {
        if let previousBrightness { UIScreen.main.brightness = previousBrightness }
        previousBrightness = nil; screenDark = false
    }
    func setFrameRate(_ rate: Int) { applyLocal(.frameRate(rate)) }
    func setQuality(_ quality: StreamQuality) { applyLocal(.quality(quality)) }
    private func applyLocal(_ command: PhoneCameraCommand) {
        guard running, !paired, !localCommandPending else { return }
        let id = UUID(); localCommandID = id; localCommandPending = true
        capture.apply(command, id: id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, self.localCommandID == id else { return }
            self.localCommandID = nil; self.localCommandPending = false
            self.setupError = "Camera setting timed out. Stop sharing and try again."
        }
    }
    func start() {
        guard !running, !starting else { return }
        UserDefaults.standard.set(false, forKey: "companion.manuallyStopped")
        starting = true; generation = UUID()
        let generation = self.generation
        code = String(format: "%06d", Int.random(in: 0...999_999))
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--test-code"), arguments.count > index + 1 {
            let testCode = arguments[index + 1]
            if testCode.count == 6, testCode.allSatisfy(\.isNumber) { code = testCode }
        }
        #endif
        if let invitation, invitation.expires <= Date() { self.invitation = nil; setupError = "The QR code expired. Scan a fresh code on your Mac."; starting = false; return }
        if let invitation { code = invitation.code }
        status = "Starting camera…"
        capture.start { [weak self] success in DispatchQueue.main.async {
            guard let self, self.generation == generation else { return }
            self.starting = false; self.running = success
            if success {
                UIApplication.shared.isIdleTimerDisabled = true
                self.link.advertise(code: self.code, invitation: self.invitation)
            }
        } }
    }
    func acceptInvitation(_ url: URL) {
        guard !running, !starting, let invitation = PairingInvitation(url: url) else {
            setupError = "Stop sharing before scanning a new, unexpired Mac QR code."; return
        }
        self.invitation = invitation; scanning = false
        status = "Mac invitation ready. Tap Start Sharing to connect."
    }
    func suspend() {
        let wasSharing = running || starting
        stop(); resumeSharing = wasSharing
    }
    func resumeIfNeeded() {
        guard resumeSharing || (UserDefaults.standard.bool(forKey: "companion.hasConnected") && link.hasRememberedCompanion && !UserDefaults.standard.bool(forKey: "companion.manuallyStopped")) else { return }
        resumeSharing = false; start()
    }
    func stop() {
        restoreScreen()
        localCommandID = nil; localCommandPending = false
        resumeSharing = false; paired = false
        generation = UUID(); starting = false; running = false; code = ""
        UIApplication.shared.isIdleTimerDisabled = false
        link.stop(); capture.stop()
        status = "Sharing stopped. Start sharing to reconnect."
    }
}

private struct PhoneView: View {
    @ObservedObject var model: PhoneModel
    @Environment(\.openURL) private var openURL
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if model.running {
                CameraPreview(session: model.capture.session, visible: !model.screenDark).ignoresSafeArea()
            }
            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: 24) {
                        HStack {
                            Label("Microscope Camera", systemImage: "camera.macro").font(.headline)
                            Spacer()
                            Button { model.showingHelp = true } label: { Image(systemName: "questionmark.circle").font(.title2) }
                                .frame(minWidth: 44, minHeight: 44).accessibilityLabel("Setup and help")
                        }
                        if !model.running { welcome }
                        Spacer(minLength: 12)
                        if model.running { sharingCard } else { setupCard }
                    }
                    .padding(24)
                    .frame(maxWidth: 560, minHeight: geometry.size.height)
                    .frame(maxWidth: .infinity)
                }.foregroundStyle(.white)
            }
            if model.screenDark {
                Button { model.restoreScreen() } label: {
                    ZStack {
                        Color.black.ignoresSafeArea()
                        VStack(spacing: 12) {
                            Image(systemName: "moon.fill")
                            Text("Sharing with your Mac")
                            Text("Tap anywhere to return").font(.caption)
                        }.foregroundStyle(.gray).font(.callout)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("Screen dimmed. Camera sharing continues. Tap to restore screen.")
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(model.screenDark)
        .persistentSystemOverlays(model.screenDark ? .hidden : .automatic)
        .sheet(isPresented: $model.scanning) {
            NavigationStack {
                QRScanner(onScan: { model.acceptInvitation($0) }, onError: { model.scanning = false; model.setupError = $0 })
                    .navigationTitle("Scan Mac QR Code").navigationBarTitleDisplayMode(.inline)
                    .toolbar { Button("Cancel") { model.scanning = false } }
            }
        }
        .sheet(isPresented: $model.showingHelp) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("Start with either device").font(.title.bold())
                        Text("On your Mac, install and open iPhone Microscope. Its Connect Camera screen walks you through setup. This iPhone app supplies the camera; the Mac provides keyboard zoom, snapshots and video recording.")
                        Text("Mac installation").font(.headline)
                        Text("Install Bench Lens: Microscope from the Mac App Store on your Mac. During the beta, use your Mac TestFlight invitation if the store page is not available yet. A Mac running macOS 14 or later is required.")
                        Link("Get the Mac App", destination: URL(string: "https://apps.apple.com/app/id6833888213")!)
                        Text("Already have the Mac app?").font(.headline)
                        Text("Open it and choose iPhone · Companion. Scan the Mac QR code here, or start sharing and enter the iPhone code on the Mac. Your devices remember each other after the first successful pairing.")
                        TipView(SharingTip())
                        Text("For smoother motion, the Mac can also use Apple’s Continuity Camera without this companion. Stop sharing here, then lock your iPhone and select it on the Mac.")
                        Button("Open iPhone Settings") { openURL(URL(string: UIApplication.openSettingsURLString)!) }
                        Button("Forget Remembered Mac", role: .destructive) {
                            UserDefaults.standard.set(false, forKey: "companion.hasConnected")
                            UserDefaults.standard.set(true, forKey: "companion.manuallyStopped")
                            model.stop(); model.link.forgetCompanion()
                        }
                    }.padding()
                }.navigationTitle("Setup & Help").navigationBarTitleDisplayMode(.inline)
                    .toolbar { Button("Done") { model.showingHelp = false } }
            }
        }
        .alert("Camera Setup", isPresented: Binding(get: { model.setupError != nil }, set: { if !$0 { model.setupError = nil } })) { Button("OK") { model.setupError = nil } } message: { Text(model.setupError ?? "") }
        .onAppear {
            model.resumeIfNeeded()
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--start-sharing") { model.start() }
            #endif
        }
    }
    private var welcome: some View {
        VStack(spacing: 14) {
            Image(systemName: "camera.macro").font(.system(size: 64, weight: .light)).foregroundStyle(.teal).accessibilityHidden(true)
            Text("A closer look.").font(.largeTitle.bold())
            Text("Your iPhone is the camera.\nYour Mac is the workbench.")
                .font(.title3).multilineTextAlignment(.center).foregroundStyle(.secondary)
        }.padding(.vertical, 28)
    }
    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(model.invitation == nil ? "Connect to your Mac" : "Mac invitation ready").font(.title2.bold())
            Text(model.invitation == nil ? "On your Mac, open iPhone Microscope → Connect Camera → iPhone App. Then scan its QR code." : "Tap Start Sharing to connect to the Mac you scanned.")
                .foregroundStyle(.secondary)
            if model.invitation == nil {
                Button { model.scanning = true } label: {
                    Label("Scan Mac QR Code", systemImage: "qrcode.viewfinder").frame(maxWidth: .infinity, minHeight: 44)
                }.buttonStyle(.borderedProminent).tint(.teal).disabled(model.starting)
            }
            Button { model.start() } label: {
                HStack { if model.starting { ProgressView() }; Text(model.starting ? "Starting camera…" : "Start Sharing").frame(maxWidth: .infinity, minHeight: 44) }
            }.buttonStyle(.bordered).disabled(model.starting)
            DisclosureGroup("Connect with a code instead") {
                Text("Tap Start Sharing, then enter the six-digit code on your Mac. A remembered Mac reconnects automatically. Both devices need the same Wi-Fi and Camera / Local Network permissions.")
                    .font(.callout).foregroundStyle(.secondary).padding(.top, 8)
            }
            Text(model.status).font(.caption).foregroundStyle(.secondary)
        }.padding(22).background(.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 22))
    }
    private var sharingCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(model.paired ? "Connected to your Mac" : "Ready to connect", systemImage: model.paired ? "checkmark.circle.fill" : "antenna.radiowaves.left.and.right")
                .font(.title3.bold()).foregroundStyle(model.paired ? .green : .teal)
            if !model.paired {
                Text(model.code).font(.system(.largeTitle, design: .monospaced).bold()).textSelection(.enabled)
                    .accessibilityLabel("Pairing code \(model.code)")
                Text("Enter this code in Connect Camera on your Mac.").foregroundStyle(.secondary)
            } else {
                Text("Focus, zoom and save from your Mac.").foregroundStyle(.secondary)
                Button { model.darkenScreen() } label: {
                    Label("Darken iPhone Screen", systemImage: "moon.fill").frame(maxWidth: .infinity, minHeight: 44)
                }.buttonStyle(.borderedProminent).tint(.teal)
                Text("Dims the display and pauses this preview. Sharing stays on. Tap the screen to return; locking the phone stops the camera.").font(.caption).foregroundStyle(.secondary)
            }
            if let state = model.state {
                DisclosureGroup("Camera settings · \(state.quality.label) · \(state.captureFPS) fps") {
                    VStack(alignment: .leading, spacing: 14) {
                        Picker("Resolution", selection: Binding(get: { state.quality }, set: { model.setQuality($0) })) {
                            ForEach(state.supportedQualities, id: \.self) { Text($0.label).tag($0) }
                        }
                        if let rates = state.supportedFrameRates {
                            Picker("Capture FPS", selection: Binding(get: { state.captureFPS }, set: { model.setFrameRate($0) })) {
                                ForEach(rates, id: \.self) { Text("\($0) fps").tag($0) }
                            }
                        }
                        Text("4K captures more detail. Lower FPS reduces capture work and permits longer exposures; it does not add pixels. Received FPS depends on Wi-Fi and Mac processing.").font(.caption).foregroundStyle(.secondary)
                        if model.paired { Text("Change camera settings from your Mac while connected. Controls pause during recording.").font(.caption).foregroundStyle(.secondary) }
                    }.padding(.top, 12).disabled(model.localCommandPending || model.paired)
                }
            }
            Text(model.status).font(.caption).foregroundStyle(.secondary)
            Button("Stop Sharing", role: .destructive) {
                UserDefaults.standard.set(true, forKey: "companion.manuallyStopped"); model.stop()
            }.frame(minHeight: 44)
        }.padding(22).background(.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 22))
    }

}

private final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}
private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    var visible: Bool
    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView(); view.previewLayer.session = session; view.previewLayer.videoGravity = .resizeAspect
        if let connection = view.previewLayer.connection, connection.isVideoRotationAngleSupported(0) { connection.videoRotationAngle = 0 }
        return view
    }
    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        uiView.previewLayer.connection?.isEnabled = visible
    }
}
