import SwiftUI
import CoreImage.CIFilterBuiltins

struct CameraSetupView: View {
    @ObservedObject var model: AppModel
    @State private var enlargedQR = false
    @State private var route = "companion"
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 14) {
                    Image(systemName: "camera.macro").font(.system(size: 42)).foregroundStyle(.teal)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("iPhone Microscope").font(.largeTitle.bold())
                        Text("Your camera. A closer look. Capture the details on your Mac.").foregroundStyle(.secondary)
                    }
                }
                Picker("Connection", selection: $route) {
                    Text("iPhone App").tag("companion")
                    Text("Continuity Camera").tag("continuity")
                    Text("USB Camera").tag("other")
                }.pickerStyle(.segmented)
                if route == "companion" { companionSetup }
                else if route == "continuity" {
                    Text("The quickest start · no iPhone app needed").font(.headline)
                    Text("1. Sign in to the same Apple Account on your Mac and iPhone. Turn on Wi-Fi and Bluetooth, or connect a trusted USB cable.\n2. Stop sharing in the iPhone companion if it is open. Lock and mount your iPhone with its rear camera facing your work.\n3. Choose your iPhone below. Allow Camera access when asked.")
                    cameraButtons(continuityOnly: true)
                    Link("Continuity setup and requirements", destination: URL(string: "https://support.apple.com/102546")!)
                } else {
                    Text("Connect a USB camera, then choose it below.")
                    cameraButtons(continuityOnly: false)
                }
                Divider()
                HStack {
                    Button("Try the Demo") { model.selectCamera("demo"); model.showingSetup = false }
                    Button("Refresh Cameras") { model.refresh(); model.refreshLocalCameras() }
                    Spacer()
                    if model.image != nil { Button("Back to Viewer") { model.showingSetup = false }.keyboardShortcut(.cancelAction) }
                }
                Text("After your first live connection, opening the Mac app reconnects to that camera. You can change cameras or reopen setup at any time.").font(.caption).foregroundStyle(.secondary)
            }.padding(28).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
        }
        .onAppear { if !model.cameraID.isEmpty && !model.isCompanion { route = "continuity" }; if route == "companion" { model.prepareCompanionSetup() } }
        .onChange(of: model.cameraID) { _, id in
            if id == "companion" { route = "companion"; model.prepareCompanionSetup() }
        }
        .onChange(of: route) { _, value in if value == "companion" { model.prepareCompanionSetup() } }
    }
    private var companionSetup: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Connect your iPhone").font(.title2.bold())
            Text("Choose lenses and focus from your Mac. Keep both devices on the same Wi-Fi.").foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 28) {
                if let invitation = model.pairingInvitation {
                    VStack(spacing: 10) {
                        PairingQRCode(url: invitation.url).frame(width: 180, height: 180)
                        Button("Enlarge QR Code") { enlargedQR = true }.font(.caption)
                        TimelineView(.periodic(from: .now, by: 1)) { timeline in
                            if invitation.expires <= timeline.date {
                                Button("Refresh Expired QR") { model.renewPairingInvitation() }
                            } else { Text("Valid for \(max(1, Int(ceil(invitation.expires.timeIntervalSince(timeline.date) / 60)))) min").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 18) {
                    Label("Scan with your iPhone Camera", systemImage: "1.circle.fill").font(.headline)
                    Text("The QR opens Microscope Camera, or the App Store if you need to install it. After installing, scan a fresh QR code.").foregroundStyle(.secondary)
                    Label("Tap Start Sharing on iPhone", systemImage: "2.circle.fill").font(.headline)
                    Text("Allow Camera and Local Network access. Your Mac connects automatically, then remembers this iPhone.").foregroundStyle(.secondary)
                    Text("Already inside the iPhone app? Use Scan Mac QR Code.").font(.callout).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            DisclosureGroup("Connect with a six-digit code") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("On iPhone, tap Start Sharing, then enter its code here.").font(.callout)
                    Picker("iPhone", selection: $model.companionPeerID) {
                        Text("Choose nearby iPhone").tag("")
                        ForEach(model.companionPeers) { peer in Text(peer.name + (peer.trusted ? " · remembered" : "")).tag(peer.id) }
                    }
                    HStack {
                        TextField("6-digit iPhone code", text: $model.companionCode).textFieldStyle(.roundedBorder).onSubmit { model.connectCompanion() }
                        Button("Connect") { model.connectCompanion() }.disabled(!model.canConnectCompanion)
                    }
                }.padding(.top, 10)
            }
            if model.companionReconnectPaused {
                Button("Reconnect Remembered iPhone") { model.renewPairingInvitation() }.buttonStyle(.borderedProminent)
            }
            DisclosureGroup("Installation & connection help") {
                VStack(alignment: .leading, spacing: 12) {
                    Link("Get Microscope Camera for iPhone", destination: URL(string: "https://apps.apple.com/app/id6829212410")!)
                    Text("During beta, use your TestFlight invitation if the App Store page is not available yet. Keep the iPhone app open; Darken iPhone Screen saves display power while sharing. Locking the phone stops the camera.").font(.callout)
                    Text("For smoother motion without lens controls, choose Continuity Camera above. It needs no iPhone app.").font(.callout)
                    Button("New Pairing QR") { model.renewPairingInvitation() }
                    Button("Forget Remembered iPhone") { model.forgetCompanion() }
                }.padding(.top, 10)
            }
        }
        .sheet(isPresented: $enlargedQR) {
            VStack(spacing: 20) {
                Text("Scan with your iPhone").font(.title2.bold())
                if let invitation = model.pairingInvitation { PairingQRCode(url: invitation.url).frame(width: 360, height: 360) }
                Text("Use the iPhone Camera or Scan Mac QR Code in Microscope Camera.").foregroundStyle(.secondary)
                HStack {
                    Button("Refresh QR") { model.renewPairingInvitation() }
                    Button("Done") { enlargedQR = false }.keyboardShortcut(.cancelAction)
                }
            }.padding(30)
        }
    }
    @ViewBuilder private func cameraButtons(continuityOnly: Bool) -> some View {
        let cameras = model.cameras.filter { !continuityOnly || $0.continuity }
        if cameras.isEmpty {
            Text(continuityOnly ? "Waiting for your iPhone. Check that Continuity Camera is enabled in iPhone Settings → General → AirPlay & Continuity." : "No cameras found yet. Connect your camera and refresh.").foregroundStyle(.secondary)
        }
        ForEach(cameras) { camera in
            Button { model.selectCamera(camera.id) } label: { Label("Connect \(camera.name)", systemImage: camera.continuity ? "iphone" : "video") }.buttonStyle(.borderedProminent)
        }
    }
}

private struct PairingQRCode: View {
    let url: URL
    var body: some View {
        let filter = CIFilter.qrCodeGenerator()
        let _ = filter.setValue(Data(url.absoluteString.utf8), forKey: "inputMessage")
        if let output = filter.outputImage, let image = CIContext().createCGImage(output, from: output.extent) {
            Image(decorative: image, scale: 1).interpolation(.none).resizable().scaledToFit().padding(12).background(.white).clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}
