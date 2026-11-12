import SwiftUI

/// Shared by the keyboard router, menu commands, and both shortcut references.
enum MicroscopeAction: CaseIterable {
    case digitalZoomIn, digitalZoomOut
    case freeze, snapshot, record, zoomIn, zoomOut, reset, panLeft, panRight, panUp, panDown
    case measure, reference, compare, enhance, stabilization, grid, crosshair, inspector, fullscreen, shortcuts

    var title: String {
        switch self {
        case .freeze: return "Freeze / resume"
        case .snapshot: return "Save snapshot"
        case .record: return "Start / stop recording"
        case .digitalZoomIn: return "Digital zoom in"
        case .digitalZoomOut: return "Digital zoom out"
        case .zoomIn: return "Camera zoom in"
        case .zoomOut: return "Camera zoom out"
        case .reset: return "Reset zoom & center"
        case .panLeft: return "Pan left"
        case .panRight: return "Pan right"
        case .panUp: return "Pan up"
        case .panDown: return "Pan down"
        case .measure: return "Toggle measurement"
        case .reference: return "Set reference & compare"
        case .compare: return "Toggle comparison"
        case .enhance: return "Enhance image"
        case .stabilization: return "Cycle stabilization"
        case .grid: return "Toggle grid"
        case .crosshair: return "Toggle crosshair"
        case .inspector: return "Toggle inspector"
        case .fullscreen: return "Toggle fullscreen"
        case .shortcuts: return "Show / hide this guide"
        }
    }

    var key: String {
        switch self {
        case .freeze: return "Space"
        case .snapshot: return "S"
        case .record: return "R"
        case .digitalZoomIn: return "⌥ +"
        case .digitalZoomOut: return "⌥ −"
        case .zoomIn: return "+ / ="
        case .zoomOut: return "−"
        case .reset: return "0"
        case .panLeft: return "←"
        case .panRight: return "→"
        case .panUp: return "↑"
        case .panDown: return "↓"
        case .measure: return "M"
        case .reference: return "B"
        case .compare: return "C"
        case .enhance: return "E"
        case .stabilization: return "T"
        case .grid: return "G"
        case .crosshair: return "X"
        case .inspector: return "I"
        case .fullscreen: return "F"
        case .shortcuts: return "?"
        }
    }

    var allowsRepeat: Bool {
        [.zoomIn, .zoomOut, .digitalZoomIn, .digitalZoomOut, .panLeft, .panRight, .panUp, .panDown].contains(self)
    }

    static func from(_ event: NSEvent) -> Self? {
        guard event.modifierFlags.intersection([.command, .control]).isEmpty else { return nil }
        if event.modifierFlags.contains(.option) {
            if event.keyCode == 24 { return .digitalZoomIn }
            if event.keyCode == 27 { return .digitalZoomOut }
            return nil
        }
        switch event.keyCode {
        case 123: return .panLeft
        case 124: return .panRight
        case 125: return .panDown
        case 126: return .panUp
        default: break
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case " ": return .freeze
        case "s": return .snapshot
        case "r": return .record
        case "+", "=": return .zoomIn
        case "-": return .zoomOut
        case "0": return .reset
        case "m": return .measure
        case "b": return .reference
        case "c": return .compare
        case "e": return .enhance
        case "t": return .stabilization
        case "g": return .grid
        case "x": return .crosshair
        case "i": return .inspector
        case "f": return .fullscreen
        case "?": return .shortcuts
        default: return nil
        }
    }
}

extension AppModel {
    func isEnabled(_ action: MicroscopeAction) -> Bool {
        switch action {
        case .snapshot: return canCapture && !snapshotBusy
        case .record: return (canCapture || recording) && !finalizing && !recordStarting
        case .freeze, .reference, .measure: return canCapture
        case .compare: return reference != nil
        default: return true
        }
    }

    func perform(_ action: MicroscopeAction) {
        guard isEnabled(action) else { return }
        switch action {
        case .freeze: toggleFreeze()
        case .snapshot: snapshot()
        case .record: toggleRecording()
        case .zoomIn: primaryZoom(by: 1.12)
        case .zoomOut: primaryZoom(by: 1 / 1.12)
        case .digitalZoomIn: preferences.pipeline.viewport.zoom(to: preferences.pipeline.viewport.zoom * 1.2)
        case .digitalZoomOut: preferences.pipeline.viewport.zoom(to: preferences.pipeline.viewport.zoom / 1.2)
        case .reset: resetView()
        case .panLeft: pan(dx: -1, dy: 0)
        case .panRight: pan(dx: 1, dy: 0)
        case .panUp: pan(dx: 0, dy: 1)
        case .panDown: pan(dx: 0, dy: -1)
        case .measure:
            measuring.toggle()
            if measuring { comparing = false }
        case .reference:
            measuring = false; measurement = nil; setReference()
        case .compare:
            comparing.toggle()
            if comparing { measuring = false; measurement = nil }
        case .enhance: enhance()
        case .stabilization:
            let strengths = StabilizationStrength.allCases
            let index = strengths.firstIndex(of: preferences.pipeline.stabilization) ?? 0
            preferences.pipeline.stabilization = strengths[(index + 1) % strengths.count]
        case .grid: preferences.grid.toggle()
        case .crosshair: preferences.crosshair.toggle()
        case .inspector: preferences.inspector.toggle()
        case .fullscreen: NSApp.keyWindow?.toggleFullScreen(nil)
        case .shortcuts: showingShortcuts.toggle()
        }
    }

    private func pan(dx: Double, dy: Double) {
        let step = 0.08 / preferences.pipeline.viewport.zoom
        preferences.pipeline.viewport.x += dx * step
        preferences.pipeline.viewport.y += dy * step
        preferences.pipeline.viewport.constrain()
    }
}

/// Window-scoped single keys; native fields and controls retain their own keyboard behavior.
struct ViewerKeyboardControls: NSViewRepresentable {
    var model: AppModel

    func makeNSView(context: Context) -> KeyboardEventView { KeyboardEventView(model: model) }
    func updateNSView(_ view: KeyboardEventView, context: Context) { view.model = model }
    static func dismantleNSView(_ view: KeyboardEventView, coordinator: ()) { view.stopMonitoring() }
}

final class KeyboardEventView: NSView {
    var model: AppModel
    private var monitor: Any?

    init(model: AppModel) {
        self.model = model
        super.init(frame: .zero)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.window, window.isKeyWindow,
                  event.window === window, window.attachedSheet == nil, NSApp.modalWindow == nil else { return event }
            // Field editors implement NSTextInputClient; controls need Space and arrows themselves.
            guard Self.acceptsViewerKeys(firstResponder: window.firstResponder) else { return event }
            if event.keyCode == 53, self.model.showingShortcuts {
                self.model.showingShortcuts = false
                return nil
            }
            guard !self.model.showingSetup, self.model.image != nil, let action = MicroscopeAction.from(event), self.model.isEnabled(action) else { return event }
            if !event.isARepeat || action.allowsRepeat { self.model.perform(action) }
            return nil
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    static func acceptsViewerKeys(firstResponder: NSResponder?) -> Bool {
        guard let firstResponder else { return true }
        return !(firstResponder is NSTextInputClient || firstResponder is NSControl)
    }
    func stopMonitoring() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
    deinit { stopMonitoring() }
}

struct KeyboardShortcutReference: View {
    var compact = false
    private var actions: [MicroscopeAction] {
        MicroscopeAction.allCases.filter { ![.panRight, .panUp, .panDown].contains($0) }
    }

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: compact ? 1 : 2), alignment: .leading, spacing: 9) {
            ForEach(actions, id: \.self) { action in
                HStack(spacing: 8) {
                    Text(action == .panLeft ? "Pan specimen" : action.title)
                    Spacer(minLength: 4)
                    Text(action == .panLeft ? "↑ ↓ ← →" : action.key)
                        .font(.system(.caption, design: .monospaced).weight(.medium))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                }.font(.caption)
            }
        }
    }
}

struct KeyboardGuide: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Keyboard controls", systemImage: "keyboard").font(.headline)
                Spacer()
                Button { model.showingShortcuts = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel("Dismiss keyboard guide")
                    .help("Dismiss guide (Esc)")
            }
            KeyboardShortcutReference()
            Divider()
            Text("No ⌘ needed. Keys pause while editing fields or using focused controls. Click the image to resume.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Esc dismisses · ? reopens · Also in Inspector → Keyboard shortcuts")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(20).frame(width: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.2), radius: 16, y: 6)
        .padding(20)
    }
}
