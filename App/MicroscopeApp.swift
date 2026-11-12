import SwiftUI
import TipKit

@main
struct MicroscopeApp: App {
    @StateObject private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    init() { try? Tips.configure([.datastoreLocation(.applicationDefault)]) }
    var body: some Scene {
        Window("iPhone Microscope", id: "microscope") {
            ContentView(model: model).onAppear { delegate.model = model
                #if DEBUG
                SmokeCheck.runIfRequested(model)
                #endif
            }
        }.defaultSize(width: 1300, height: 850)
        .commands {
            CommandGroup(after: .newItem) {
                action(.snapshot, key: "s")
                Button(model.recording ? "Stop Recording" : "Start Recording") { model.perform(.record) }.keyboardShortcut("r").disabled(!model.isEnabled(.record))
            }
            CommandMenu("Microscope") {
                // Plain keys are handled only in the viewer, so Space remains usable in fields.
                Button(model.frozen ? "Resume Live View (Space)" : "Freeze Frame (Space)") { model.perform(.freeze) }.disabled(!model.isEnabled(.freeze))
                action(.reset, key: "0")
                action(.zoomIn, key: "+")
                action(.zoomOut, key: "-")
                action(.reference, key: "b")
                Button("Toggle Comparison (C)") { model.perform(.compare) }.disabled(!model.isEnabled(.compare))
                action(.measure, key: "m", modifiers: [.command, .shift])
                action(.enhance, key: "e")
                Button("Cycle Stabilization (T)") { model.perform(.stabilization) }
                Button("Toggle Grid (G)") { model.perform(.grid) }
                Button("Toggle Crosshair (X)") { model.perform(.crosshair) }
                Divider()
                action(.inspector, key: "i", modifiers: [.command, .option])
                action(.fullscreen, key: "f", modifiers: [.command, .control])
                Button("Keyboard Shortcuts (?)") { model.perform(.shortcuts) }
                Button("Connect Camera / Setup…") { model.showingSetup = true }.disabled(model.busy)
                Button("Refresh Cameras") { model.refresh() }
            }
        }
    }
    private func action(_ action: MicroscopeAction, key: KeyEquivalent, modifiers: EventModifiers = .command) -> some View {
        Button(action.title) { model.perform(action) }
            .keyboardShortcut(key, modifiers: modifiers).disabled(!model.isEnabled(action))
    }
}
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    private var terminationTimer: Timer?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        guard model.busy || model.snapshotBusy else { model.shutdown(); return .terminateNow }
        model.stopRecording()
        terminationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
            if model.recording { model.stopRecording() }
            if !model.busy && !model.snapshotBusy { timer.invalidate(); self?.terminationTimer = nil; model.shutdown(); sender.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }
}
