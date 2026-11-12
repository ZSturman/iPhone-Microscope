import Foundation

public struct Preferences: Codable {
    public init() {}
    public var pipeline = PipelineSettings()
    public var crosshair = true
    public var crosshairSize = 24.0
    public var grid = false
    public var gridSpacing = 80.0
    public var scaleBar = true
    public var inspector = true
    public var opticalConfiguration = "Default optics"
    public var profiles: [Calibration] = []
    public var activeProfile: UUID?
    public var outputPath = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appendingPathComponent("iPhone Microscope").path
    public var videoFormat = "mp4"
    public var imageFormat = "png"
    public var originalRecording = false
    public var originalSnapshot = false
    public var lastCamera = ""
    public var formatIDs: [String: Int] = [:]
    public var snapshotPaths: [String] = []
}


public enum SettingsStore {
    public static func load(from defaults: UserDefaults = .standard) -> Preferences {
        defaults.data(forKey: "preferences.v1").flatMap { try? JSONDecoder().decode(Preferences.self, from: $0) } ?? Preferences()
    }
    public static func save(_ preferences: Preferences, to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(preferences) { defaults.set(data, forKey: "preferences.v1") }
    }
}
