import SwiftUI
import AVFoundation

/// Uses the camera only while this sheet is open; it stops before sharing starts.
struct QRScanner: UIViewControllerRepresentable {
    let onScan: (URL) -> Void
    let onError: (String) -> Void
    func makeUIViewController(context: Context) -> ScannerController { ScannerController(onScan: onScan, onError: onError) }
    func updateUIViewController(_ controller: ScannerController, context: Context) {}
    static func dismantleUIViewController(_ controller: ScannerController, coordinator: ()) { controller.stop() }
}

final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "microscope.qr-scanner")
    private var active = true
    private var delivered = false
    private let onScan: (URL) -> Void
    private let onError: (String) -> Void
    private var preview: AVCaptureVideoPreviewLayer?
    // Camera configuration and zoom mutations belong to queue; UIKit stays on main.
    private var camera: AVCaptureDevice?
    private let zoomSlider = UISlider()
    private let zoomLabel = UILabel()
    private var pinchStart: Float = 1
    init(onScan: @escaping (URL) -> Void, onError: @escaping (String) -> Void) {
        self.onScan = onScan; self.onError = onError; super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .black
        let preview = AVCaptureVideoPreviewLayer(session: session); preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview); self.preview = preview
        let instructions = UILabel()
        instructions.text = "Point at the Mac QR code. Pinch or drag to zoom."
        instructions.numberOfLines = 0; instructions.textAlignment = .center; instructions.textColor = .white
        zoomLabel.text = "1.0×"; zoomLabel.textColor = .white; zoomLabel.textAlignment = .center
        zoomSlider.minimumValue = 1; zoomSlider.maximumValue = 1; zoomSlider.value = 1; zoomSlider.isEnabled = false
        zoomSlider.accessibilityLabel = "QR camera zoom"
        zoomSlider.addTarget(self, action: #selector(sliderChanged), for: .valueChanged)
        let stack = UIStackView(arrangedSubviews: [instructions, zoomLabel, zoomSlider])
        stack.axis = .vertical; stack.spacing = 12; stack.translatesAutoresizingMaskIntoConstraints = false
        stack.backgroundColor = UIColor.black.withAlphaComponent(0.8); stack.layer.cornerRadius = 16
        stack.isLayoutMarginsRelativeArrangement = true; stack.directionalLayoutMargins = .init(top: 18, leading: 18, bottom: 18, trailing: 18)
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20)
        ])
        view.addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(pinched)))
        AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
            guard let self else { return }
            self.queue.async {
                guard self.active else { return }
                guard allowed else {
                    DispatchQueue.main.async { self.onError("Allow Camera access in Settings to scan the Mac QR code, or use the six-digit code instead.") }; return
                }
                guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back), let input = try? AVCaptureDeviceInput(device: camera) else {
                    DispatchQueue.main.async { self.onError("Camera unavailable. Close other camera apps, or use the six-digit code to connect.") }; return
                }
                let output = AVCaptureMetadataOutput()
                self.session.beginConfiguration()
                guard self.session.canAddInput(input), self.session.canAddOutput(output) else {
                    self.session.commitConfiguration(); DispatchQueue.main.async { self.onError("Camera unavailable. Close other camera apps and try again.") }; return
                }
                self.session.addInput(input); self.session.addOutput(output)
                self.camera = camera
                output.setMetadataObjectsDelegate(self, queue: .main); output.metadataObjectTypes = [.qr]
                self.session.commitConfiguration(); self.session.startRunning()
                let maximum = Float(min(6, camera.maxAvailableVideoZoomFactor))
                DispatchQueue.main.async {
                    self.zoomSlider.maximumValue = max(1, maximum); self.zoomSlider.isEnabled = maximum > 1
                }
            }
        }
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews(); preview?.frame = view.bounds
        let angle: CGFloat
        switch view.window?.windowScene?.interfaceOrientation {
        case .landscapeLeft: angle = 180
        case .landscapeRight: angle = 0
        case .portraitUpsideDown: angle = 270
        default: angle = 90
        }
        if let connection = preview?.connection, connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
    }
    @objc private func sliderChanged() { zoom(to: zoomSlider.value) }
    @objc private func pinched(_ gesture: UIPinchGestureRecognizer) {
        if gesture.state == .began { pinchStart = zoomSlider.value }
        if gesture.state == .changed { zoom(to: pinchStart * Float(gesture.scale)) }
    }
    private func zoom(to requested: Float) {
        let value = min(zoomSlider.maximumValue, max(zoomSlider.minimumValue, requested))
        zoomSlider.value = value; zoomLabel.text = String(format: "%.1f×", value)
        zoomSlider.accessibilityValue = zoomLabel.text
        queue.async {
            guard self.active, let camera = self.camera else { return }
            do {
                try camera.lockForConfiguration()
                camera.videoZoomFactor = min(camera.maxAvailableVideoZoomFactor, max(camera.minAvailableVideoZoomFactor, CGFloat(value)))
                camera.unlockForConfiguration()
            } catch { DispatchQueue.main.async { self.onError("Camera zoom is unavailable. Try moving closer to the QR code.") } }
        }
    }
    func stop() { queue.async { self.active = false; if self.session.isRunning { self.session.stopRunning() } } }
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !delivered, let value = (metadataObjects.first as? AVMetadataMachineReadableCodeObject)?.stringValue, let url = URL(string: value) else { return }
        guard PairingInvitation(url: url) != nil else {
            delivered = true; stop(); onError("This QR code is expired or is not a Microscope invitation. Refresh the code on your Mac and scan again."); return
        }
        delivered = true
        queue.async {
            self.active = false; self.session.stopRunning()
            DispatchQueue.main.async { self.onScan(url) }
        }
    }
}
