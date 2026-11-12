import SwiftUI
import TipKit

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var inspectorBeforeFullscreen: Bool?
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ZStack {
                    Color.black
                    MetalPreview(image: model.image, reference: model.reference, comparing: model.comparing, measuring: model.measuring, selectingWorkArea: model.selectingWorkArea, onWorkArea: { model.selectWorkArea($0, $1) }, onZoom: { factor, point in
                        model.preferences.pipeline.viewport.zoom(to: model.preferences.pipeline.viewport.zoom * factor, anchor: point)
                    }, onPan: { delta in
                        model.preferences.pipeline.viewport.x -= delta.width / model.preferences.pipeline.viewport.zoom
                        model.preferences.pipeline.viewport.y -= delta.height / model.preferences.pipeline.viewport.zoom
                        model.preferences.pipeline.viewport.constrain()
                    }, onMeasure: { a, b in model.measurement = Measurement(a: a, b: b) })
                    if model.image != nil { MicroscopeOverlays(model: model) }
                    if model.awaitingCameraFrame && model.image != nil {
                        VStack { Spacer(); Label("Waiting for camera · showing last frame", systemImage: "pause.circle").padding(10).background(.black.opacity(0.8), in: Capsule()).foregroundStyle(.white) }.padding(20).allowsHitTesting(false)
                    }
                    if model.image == nil || model.showingSetup {
                        CameraSetupView(model: model).background(.background)
                    }
                    if model.image != nil && !model.showingSetup {
                    VStack {
                        HStack {
                            if model.cameraID == "demo" { badge("DEMO · GENERATED FOOTAGE", color: .teal) }
                            if model.isCompanion { badge("IPHONE COMPANION", color: .teal) }
                            if model.frozen { badge("FROZEN", color: .orange) }
                            if model.measuring { badge("MEASURE · DRAG A LINE", color: .yellow) }
                            if model.comparing { badge("REFERENCE  |  LIVE", color: .white) }
                            Spacer()
                        }
                        Spacer()
                        HStack { Spacer(); Text(String(format: "%.2f× digital", model.preferences.pipeline.viewport.zoom)).font(.system(.caption, design: .monospaced)).padding(8).background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6)).foregroundStyle(.white) }
                    }.padding(16).allowsHitTesting(false)
                    }
                    if model.showingShortcuts && model.image != nil && !model.showingSetup {
                        VStack { Spacer(); KeyboardGuide(model: model) }
                    }
                }
                if model.preferences.inspector && model.image != nil && !model.showingSetup { Divider(); InspectorView(model: model).frame(width: 300) }
            }
            Divider()
            statusBar
        }
        .frame(minWidth: 860, minHeight: 600)
        .background(ViewerKeyboardControls(model: model).frame(width: 0, height: 0))
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { model.showingSetup.toggle() } label: { Label("Connect Camera", systemImage: "laptopcomputer.and.iphone") }.disabled(model.busy)
            }
            ToolbarItemGroup {
                Button { model.perform(.zoomOut) } label: { Label("Zoom Out", systemImage: "minus.magnifyingglass") }.help("Zoom out (−); hold to repeat")
                Button { model.perform(.zoomIn) } label: { Label("Zoom In", systemImage: "plus.magnifyingglass") }.help("Zoom in (+); hold to repeat").popoverTip(ZoomTip())
                Button { model.perform(.freeze) } label: {
                    Label(model.frozen ? "Resume" : "Freeze", systemImage: model.frozen ? "play.fill" : "pause.fill")
                }.help("Freeze / resume (Space)").disabled(!model.isEnabled(.freeze))
                Button { model.perform(.snapshot) } label: {
                    Label("Snapshot", systemImage: "camera")
                }.help("Save snapshot (S or ⌘S)").disabled(!model.isEnabled(.snapshot))
                Button { model.perform(.record) } label: {
                    Label(model.recording ? "Stop" : "Record", systemImage: model.recording ? "stop.circle.fill" : "record.circle")
                        .foregroundStyle(model.recording ? .red : .primary)
                }.popoverTip(RecordingTip()).help("Start / stop recording (R or ⌘R)").disabled(!model.isEnabled(.record))
            }
            ToolbarItemGroup {
                Button { model.peakingEnabled.toggle() } label: {
                    Label("Focus Peaking", systemImage: "viewfinder").foregroundStyle(model.peakingEnabled ? .red : .primary)
                }.help("Highlight detailed edges in red to help focus. Viewer only.").disabled(model.image == nil)
                Menu {
                    Button("Rotate Left") { model.preferences.pipeline.image.rotation = (model.preferences.pipeline.image.rotation + 3) % 4 }
                    Button("Rotate Right") { model.preferences.pipeline.image.rotation = (model.preferences.pipeline.image.rotation + 1) % 4 }
                    Button("Turn Upside Down") { model.preferences.pipeline.image.rotation = (model.preferences.pipeline.image.rotation + 2) % 4 }
                    Divider()
                    Toggle("Mirror Left / Right", isOn: $model.preferences.pipeline.image.flipH)
                    Toggle("Flip Top / Bottom", isOn: $model.preferences.pipeline.image.flipV)
                    Button("Reset Orientation") {
                        model.preferences.pipeline.image.rotation = 0; model.preferences.pipeline.image.flipH = false; model.preferences.pipeline.image.flipV = false
                    }
                } label: { Label("Orientation", systemImage: "rotate.right") }.disabled(model.busy || model.image == nil)
                Button { NSWorkspace.shared.open(URL(fileURLWithPath: model.preferences.outputPath)) } label: { Label("Saved Files", systemImage: "folder") }.help("Open snapshots and recordings")
                Button { model.perform(.shortcuts) } label: { Label("Keyboard Shortcuts", systemImage: "keyboard") }
                    .help("Show / hide keyboard guide (?)")
                Button { model.perform(.inspector) } label: { Label("Controls", systemImage: "sidebar.right") }
                    .help("Toggle inspector (I or ⌥⌘I)")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
            inspectorBeforeFullscreen = model.preferences.inspector; model.preferences.inspector = false
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            if let inspectorBeforeFullscreen { model.preferences.inspector = inspectorBeforeFullscreen }; inspectorBeforeFullscreen = nil
        }
        .onChange(of: model.image != nil && !model.showingSetup, initial: true) { _, ready in
            ZoomTip.connected = ready; RecordingTip.connected = ready
        }
        .onChange(of: model.comparing) { _, value in if value { model.measuring = false; model.measurement = nil } }
        .onChange(of: model.measuring) { _, value in if value { model.comparing = false } }
        .alert("Microscope", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) { Button("OK") { model.errorMessage = nil } } message: { Text(model.errorMessage ?? "") }
    }
    private func badge(_ text: String, color: Color) -> some View { Text(text).font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(color).padding(7).background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 5)) }
    private var statusBar: some View {
        HStack(spacing: 14) {
            Circle().fill(model.image == nil ? Color.gray : model.frozen ? .orange : .green).frame(width: 6, height: 6)
            Text(model.status).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            if model.sourceSize.width > 0 { Text("\(Int(model.sourceSize.width)) × \(Int(model.sourceSize.height))"); Text(String(format: "%.0f fps", model.fps)) }
            if let start = model.recordingStart {
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    let seconds = max(0, Int(timeline.date.timeIntervalSince(start)))
                    Text(String(format: "● %02d:%02d", seconds / 60, seconds % 60)).foregroundStyle(.red).monospacedDigit()
                }
            }
            if model.finalizing || model.recordStarting { ProgressView().controlSize(.mini) }
        }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 14).frame(height: 30).background(.bar)
    }
}

struct InspectorView: View {
    @ObservedObject var model: AppModel
    @AppStorage("inspector.advanced") private var advanced = false
    @State private var calibrationName = ""
    @State private var knownLength = "1000"
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack { Text("Controls").font(.title3.weight(.semibold)); Spacer(); Button { model.preferences.inspector = false } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary) }
                if model.isCompanion {
                    InspectorSection("iPhone camera", expanded: true) { CompanionControls(model: model) }
                }
                InspectorSection("View", expanded: true) {
                    VStack(alignment: .leading, spacing: 10) {
                        slider("Digital zoom · ⌥ + / −", value: Binding(get: { model.preferences.pipeline.viewport.zoom }, set: { model.preferences.pipeline.viewport.zoom(to: $0) }), range: 1...20, format: "%.2f×")
                        Button("Suggest Work Area") { model.suggestWorkArea() }
                        Button(model.selectingWorkArea ? "Drag around your work…" : "Select Work Area") { model.selectingWorkArea.toggle(); model.measuring = false }
                        if model.preferences.pipeline.workArea != nil {
                            Button("Clear Work Area") { model.preferences.pipeline.workArea = nil }
                            Text("Background dimming and peaking are limited to your selection. Redraw to adjust. Reselect after rotating or panning. Viewer only.").font(.caption).foregroundStyle(.secondary)
                        }
                        Toggle("Red focus peaking", isOn: $model.peakingEnabled)
                        if model.peakingEnabled {
                            slider("Peaking sensitivity", value: $model.peakingSensitivity, range: 0...1)
                            Text("Red highlights strong edges to help you focus. Noise and texture can also peak. Saved photos and videos stay clean.").font(.caption).foregroundStyle(.secondary)
                        }
                        Picker("Orientation", selection: $model.preferences.pipeline.image.rotation) {
                            Text("0°").tag(0); Text("90°").tag(1); Text("180°").tag(2); Text("270°").tag(3)
                        }.disabled(model.busy)
                        HStack {
                            Toggle("Mirror", isOn: $model.preferences.pipeline.image.flipH)
                            Toggle("Flip vertical", isOn: $model.preferences.pipeline.image.flipV)
                        }.disabled(model.busy)
                        Button("Reset Zoom & Center") { model.resetView() }
                    }.padding(.vertical, 6)
                }
                DisclosureGroup("Advanced options", isExpanded: $advanced) {
                    VStack(alignment: .leading, spacing: 14) {
                InspectorSection("Stabilization & reference") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Stabilization", selection: $model.preferences.pipeline.stabilization) {
                            ForEach(StabilizationStrength.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }.help("Cycle stabilization (T)")
                        HStack { Button("Reset & Center") { model.resetView() }; Spacer(); Toggle("Measure", isOn: $model.measuring).toggleStyle(.button).disabled(model.image == nil) }
                        Toggle("Subject lock", isOn: $model.preferences.pipeline.lock).disabled(model.preferences.pipeline.stabilization == .off)
                        Text("Stabilization uses an 8% margin per edge. Subject lock is limited to that margin.").font(.caption).foregroundStyle(.secondary)
                        HStack { Button("Set Reference") { model.setReference() }.disabled(model.image == nil); if model.reference != nil { Button("Clear") { model.clearReference() } } }
                        if model.reference != nil { Toggle("Compare reference / live", isOn: $model.comparing) }
                        HStack { Text("Focus detail"); Spacer(); Text(String(format: "%.0f", model.focus)).monospacedDigit() }.font(.caption)
                        ProgressView(value: model.focus, total: 100).tint(.teal)
                        Text("Relative edge detail · Tracking: \(model.tracking)").font(.caption2).foregroundStyle(.secondary)
                    }.padding(.vertical, 6)
                }
                InspectorSection("Keyboard shortcuts") {
                    VStack(alignment: .leading, spacing: 12) {
                        KeyboardShortcutReference(compact: true)
                        Text("Single keys pause in text fields and focused controls. Click the image to resume. Existing ⌘ shortcuts also work from the Microscope menu.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button(model.showingShortcuts ? "Hide Keyboard Guide" : "Show Keyboard Guide") { model.perform(.shortcuts) }
                    }.padding(.vertical, 6)
                }
                if !model.isCompanion {
                    InspectorSection("Camera setup") {
                        VStack(alignment: .leading, spacing: 8) {
                            Picker("Resolution", selection: Binding(get: { model.formatID }, set: { model.selectFormat($0) })) {
                                if model.formats.isEmpty { Text("No camera").tag(-1) }
                                ForEach(model.formats) { format in Text(format.label).tag(format.id) }
                            }.disabled(model.busy || model.formats.isEmpty)
                            Button("Refresh Cameras") { model.refresh() }
                            Divider()
                            Toggle("Lock autofocus", isOn: $model.focusLocked).disabled(!model.capabilities.focusLock).onChange(of: model.focusLocked) { _, _ in model.locksChanged() }
                            Toggle("Lock auto exposure", isOn: $model.exposureLocked).disabled(!model.capabilities.exposureLock).onChange(of: model.exposureLocked) { _, _ in model.locksChanged() }
                            Toggle("Lock auto white balance", isOn: $model.whiteBalanceLocked).disabled(!model.capabilities.whiteBalanceLock).onChange(of: model.whiteBalanceLocked) { _, _ in model.locksChanged() }
                            Text("Available modes depend on the camera. Choose iPhone Companion for lens selection, manual focus and camera exposure controls.").font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 6)
                    }
                }
                InspectorSection("Software image adjustments") {
                    VStack(spacing: 10) {
                        slider("Brightness", value: $model.preferences.pipeline.image.brightness, range: -0.5...0.5)
                        slider("Contrast", value: $model.preferences.pipeline.image.contrast, range: 0.5...2)
                        slider("Exposure (EV)", value: $model.preferences.pipeline.image.exposure, range: -3...3)
                        slider("Saturation", value: $model.preferences.pipeline.image.saturation, range: 0...2)
                        slider("Sharpness", value: $model.preferences.pipeline.image.sharpness, range: 0...2)
                        slider("White balance (K)", value: $model.preferences.pipeline.image.temperature, range: 2500...10000, format: "%.0f")
                        HStack { Button("Enhance") { model.enhance() }; Button("Reset") { var settings = ImageSettings(); if model.busy { settings.rotation = model.preferences.pipeline.image.rotation; settings.flipH = model.preferences.pipeline.image.flipH; settings.flipV = model.preferences.pipeline.image.flipV }; model.preferences.pipeline.image = settings } }
                        HStack { Toggle("Grayscale", isOn: $model.preferences.pipeline.image.grayscale); Toggle("Invert", isOn: $model.preferences.pipeline.image.inverted) }
                    }.padding(.vertical, 6)
                }
                InspectorSection("Overlays") {
                    VStack(spacing: 10) {
                        Toggle("Center crosshair", isOn: $model.preferences.crosshair)
                        slider("Crosshair size", value: $model.preferences.crosshairSize, range: 8...100, format: "%.0f")
                        Toggle("Grid", isOn: $model.preferences.grid)
                        slider("Grid spacing (points)", value: $model.preferences.gridSpacing, range: 20...200, format: "%.0f")
                        Toggle("Calibrated scale bar", isOn: $model.preferences.scaleBar).disabled(model.activeCalibration == nil)
                    }.padding(.vertical, 6)
                }
                calibration
                InspectorSection("Capture & files") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Video", selection: $model.preferences.videoFormat) { Text("MP4 / H.264").tag("mp4"); Text("MOV / H.264").tag("mov") }.disabled(model.busy)
                        Toggle("Record original feed", isOn: $model.preferences.originalRecording).disabled(model.busy)
                        Picker("Image", selection: $model.preferences.imageFormat) { Text("PNG").tag("png"); Text("JPEG").tag("jpg") }
                        Toggle("Snapshot original feed", isOn: $model.preferences.originalSnapshot)
                        Text("Original stills use high-resolution photo capture when supported; otherwise full video resolution. Processed captures include stabilization, zoom and adjustments. Overlays and comparison are viewer-only. Video has no audio.").font(.caption).foregroundStyle(.secondary)
                        Text("Dropped frames this session: \(model.dropped)").font(.caption).foregroundStyle(.secondary)
                        Button("Choose Output Folder…") { model.chooseDirectory() }
                        Text(model.preferences.outputPath).font(.caption2).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                        Button("Show in Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: model.preferences.outputPath)) }
                    }.padding(.vertical, 6)
                }
                    }.padding(.top, 10)
                }
                if !model.recentSnapshots.isEmpty {
                    InspectorSection("Recent snapshots", expanded: true) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(model.recentSnapshots, id: \.self) { url in
                                Button { NSWorkspace.shared.open(url) } label: { Label(url.lastPathComponent, systemImage: "photo").font(.caption).lineLimit(1).truncationMode(.middle) }.buttonStyle(.link)
                            }
                        }.padding(.vertical, 6)
                    }
                }
            }.padding(16)
        }.background(.background)
    }
    private var calibration: some View {
        InspectorSection("Calibration & measurement") {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Optical configuration", text: $model.preferences.opticalConfiguration).textFieldStyle(.roundedBorder)
                Picker("Profile", selection: $model.preferences.activeProfile) {
                    Text("Uncalibrated").tag(nil as UUID?)
                    ForEach(model.preferences.profiles) { Text($0.name).tag(Optional($0.id)) }
                }
                if model.preferences.activeProfile != nil && model.activeCalibration == nil { Text("Profile does not match this camera, resolution or optical configuration.").font(.caption).foregroundStyle(.orange) }
                Text(model.measurementLabel).font(.caption).textSelection(.enabled)
                Text("Freeze the view, enable Measure, then drag across a known size. Enter that size to calibrate.").font(.caption).foregroundStyle(.secondary)
                TextField("Profile name", text: $calibrationName).textFieldStyle(.roundedBorder)
                HStack { TextField("Known size", text: $knownLength).textFieldStyle(.roundedBorder); Text("µm").foregroundStyle(.secondary) }
                Button("Save Calibration") { model.calibrate(name: calibrationName, micrometers: Double(knownLength) ?? 0) }.disabled(model.measurementPixels <= 0 || model.cameraID.isEmpty)
                if let id = model.preferences.activeProfile { Button("Delete Profile", role: .destructive) { model.preferences.profiles.removeAll { $0.id == id }; model.preferences.activeProfile = nil } }
                Text("Recalibrate after moving the lens, changing focus distance or changing optical accessories. Digital zoom is not optical magnification.").font(.caption).foregroundStyle(.secondary)
            }.padding(.vertical, 6)
        }
    }
    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, format: String = "%.2f") -> some View {
        VStack(spacing: 2) { HStack { Text(title); Spacer(); Text(String(format: format, value.wrappedValue)).foregroundStyle(.secondary).monospacedDigit() }.font(.caption); Slider(value: value, in: range).accessibilityLabel(title) }
    }
}

private struct CompanionControls: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.companionStatus).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if let state = model.companionState {
                Picker("Lens", selection: Binding(get: { state.lensID }, set: { model.sendCompanion(.lens($0)) })) {
                    ForEach(state.lenses) { Text($0.name).tag($0.id) }
                }
                if let minimum = state.minimumFocusDistanceMM {
                    Text("Working distance: this lens focuses from about \(minimum) mm. If closer and soft, move the phone farther away or choose Ultra Wide. Move closer for a larger subject while staying beyond that limit.").font(.caption).foregroundStyle(.secondary)
                }
                Text("Distance is not measured. Peaking shows edge detail at any distance; select your work area to suppress background highlights.").font(.caption2).foregroundStyle(.secondary)
                Picker("Resolution", selection: Binding(get: { state.quality }, set: { model.sendCompanion(.quality($0)) })) {
                    ForEach(state.supportedQualities, id: \.self) { Text($0.label).tag($0) }
                }
                if let rates = state.supportedFrameRates {
                    Picker("Capture FPS", selection: Binding(get: { state.captureFPS }, set: { model.sendCompanion(.frameRate($0)) })) {
                        ForEach(rates, id: \.self) { Text("\($0) fps").tag($0) }
                    }
                }
                Text("4K = more pixels. Lower FPS = less capture work and longer possible exposures. Received FPS appears below the viewer.").font(.caption).foregroundStyle(.secondary)
                Toggle("iPhone light", isOn: Binding(get: { state.torch }, set: { model.sendCompanion(.torch($0)) })).disabled(!state.supportsTorch)
                RemoteCameraSlider(title: "iPhone camera zoom · + / −", live: true, value: state.zoom, range: state.minZoom...max(state.minZoom + 0.001, state.maxZoom), format: "%.2f×") { model.requestCameraZoom($0) }
                    .disabled(state.maxZoom <= state.minZoom)
                Text("Selecting a lens changes the optics. Camera zoom crops at the sensor; beyond \(String(format: "%.2f", state.losslessZoomLimit))× it also upscales. The View slider adds separate digital enlargement.").font(.caption2).foregroundStyle(.secondary)
                DisclosureGroup("Focus & exposure") {
                    VStack(alignment: .leading, spacing: 12) {
                if state.supportsFocusLock {
                    Toggle("Autofocus", isOn: Binding(get: { !state.focusLocked }, set: { auto in
                        model.sendCompanion(.locks(focus: !auto, exposure: state.exposureLocked, whiteBalance: state.whiteBalanceLocked))
                    }))
                }
                if state.supportsManualFocus {
                    RemoteCameraSlider(title: "Manual focus · locks autofocus", value: state.manualFocus ?? 0.5, range: 0...1, format: "%.2f") { model.sendCompanion(.focus($0)) }
                    Text("0 = near, 1 = far. Try Ultra Wide for close specimens; telephoto needs more working distance.").font(.caption2).foregroundStyle(.secondary)
                }
                RemoteCameraSlider(title: "Camera exposure compensation", value: state.exposureBias, range: state.minExposureBias...max(state.minExposureBias + 0.001, state.maxExposureBias), format: "%.1f EV") { model.sendCompanion(.exposure($0)) }
                    .disabled(state.minExposureBias == state.maxExposureBias)
                Toggle("Lock auto exposure", isOn: Binding(get: { state.exposureLocked }, set: { model.sendCompanion(.locks(focus: state.focusLocked, exposure: $0, whiteBalance: state.whiteBalanceLocked)) })).disabled(!state.supportsExposureLock)
                Toggle("Lock auto white balance", isOn: Binding(get: { state.whiteBalanceLocked }, set: { model.sendCompanion(.locks(focus: state.focusLocked, exposure: state.exposureLocked, whiteBalance: $0)) })).disabled(!state.supportsWhiteBalanceLock)
                    }.padding(.top, 8)
                }
                Button("Disconnect") { model.disconnectCompanion() }
                Text("Camera controls pause while recording. Lens, zoom, focus or stream changes clear calibration and frozen/reference images.").font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("Open Microscope Camera on your iPhone and tap Start Sharing. Use the same Wi-Fi network and allow Local Network access on both devices.").font(.caption)
                Picker("iPhone", selection: $model.companionPeerID) {
                    if model.companionPeers.isEmpty { Text("Searching…").tag("") }
                    ForEach(model.companionPeers) { Text($0.name).tag($0.id) }
                }
                TextField("Six-digit code from iPhone", text: $model.companionCode).textFieldStyle(.roundedBorder)
                    .onSubmit { model.connectCompanion() }
                Button("Connect") { model.connectCompanion() }
                    .disabled(!model.canConnectCompanion)
            }
            if model.companionPending != nil { ProgressView("Applying camera setting…").controlSize(.small) }
        }.padding(.vertical, 6).disabled(model.busy)
    }
}

/// Send a single hardware command on release, instead of flooding the camera while dragging.
private struct RemoteCameraSlider: View {
    let title: String
    var live = false
    let value: Double
    let range: ClosedRange<Double>
    let format: String
    let commit: (Double) -> Void
    @State private var draft = 0.0
    @State private var editing = false
    var body: some View {
        VStack(spacing: 2) {
            HStack { Text(title); Spacer(); Text(String(format: format, draft)).monospacedDigit().foregroundStyle(.secondary) }.font(.caption)
            Slider(value: $draft, in: range, onEditingChanged: { editing in
                self.editing = editing
                if !editing { commit(draft) }
            }).accessibilityLabel(title)
        }
        .onChange(of: draft) { _, value in if live && editing { commit(value) } }
        .onAppear { draft = value }
        .onChange(of: value) { _, value in if !editing { draft = value } }
    }
}

/// Keep detailed settings discoverable without presenting every control at once.
private struct InspectorSection<Content: View>: View {
    let title: String
    @State private var expanded: Bool
    let content: Content

    init(_ title: String, expanded: Bool = false, @ViewBuilder content: () -> Content) {
        self.title = title
        _expanded = State(initialValue: expanded)
        self.content = content()
    }

    var body: some View {
        GroupBox {
            DisclosureGroup(isExpanded: $expanded) { content } label: {
                Text(title).font(.subheadline.weight(.semibold))
            }.padding(4)
        }
    }
}
