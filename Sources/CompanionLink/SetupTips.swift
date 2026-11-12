import SwiftUI
import TipKit

public struct ZoomTip: Tip {
    @Parameter public static var connected: Bool = false
    public var rules: [Rule] { #Rule(Self.$connected) { $0 } }
    public init() {}
    public var title: Text { Text("Keep your hands on the keyboard") }
    public var message: Text? { Text("With the iPhone companion, + or − adjusts camera zoom. Option + / − adjusts digital zoom. Click the image after editing a field.") }
    public var image: Image? { Image(systemName: "plus.magnifyingglass") }
}
public struct RecordingTip: Tip {
    @Parameter public static var connected: Bool = false
    public var rules: [Rule] { #Rule(Self.$connected) { $0 } }
    public init() {}
    public var title: Text { Text("Record your work") }
    public var message: Text? { Text("Press R to start or stop recording. View zoom is included by default. Open Saved Files to find your video.") }
    public var image: Image? { Image(systemName: "record.circle") }
}
public struct SharingTip: Tip {
    public init() {}
    public var title: Text { Text("Your Mac remembers this iPhone") }
    public var message: Text? { Text("After pairing, reopen both apps on the same Wi-Fi. Keep this app open and the phone unlocked while sharing. Stop Sharing ends the feed.") }
    public var image: Image? { Image(systemName: "laptopcomputer.and.iphone") }
}
