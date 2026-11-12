import Foundation
import CoreGraphics

public struct Viewport: Codable, Equatable {
    public var zoom: Double = 1
    // Center in normalized, bottom-left image coordinates.
    public var x: Double = 0.5
    public var y: Double = 0.5
    public init() {}
    public mutating func constrain() {
        zoom = min(20, max(1, zoom))
        let half = 0.5 / zoom
        x = min(1 - half, max(half, x)); y = min(1 - half, max(half, y))
    }
    public mutating func zoom(to value: Double, anchor: CGPoint = CGPoint(x: 0.5, y: 0.5)) {
        let old = zoom
        zoom = min(20, max(1, value))
        x += (anchor.x - 0.5) * (1 / old - 1 / zoom)
        y += (anchor.y - 0.5) * (1 / old - 1 / zoom)
        constrain()
    }
    public func crop(in size: CGSize) -> CGRect {
        CGRect(x: (x - 0.5 / zoom) * size.width, y: (y - 0.5 / zoom) * size.height,
               width: size.width / zoom, height: size.height / zoom)
    }
}

public struct Measurement: Equatable {
    public var a: CGPoint
    public var b: CGPoint
    public init(a: CGPoint, b: CGPoint) { self.a = a; self.b = b }
    public func pixels(in size: CGSize) -> Double {
        hypot((a.x - b.x) * size.width, (a.y - b.y) * size.height)
    }
}

public struct Calibration: Codable, Identifiable, Equatable {
    public var id = UUID()
    public var name: String
    public var cameraID: String
    public var width: Int
    public var height: Int
    public var opticalConfiguration: String
    public var micrometersPerPixel: Double
    public init?(name: String, cameraID: String, size: CGSize, opticalConfiguration: String, pixels: Double, micrometers: Double) {
        guard pixels.isFinite, micrometers.isFinite, pixels > 0, micrometers > 0, size.width > 0, size.height > 0 else { return nil }
        self.name = name; self.cameraID = cameraID; width = Int(size.width); height = Int(size.height)
        self.opticalConfiguration = opticalConfiguration; micrometersPerPixel = micrometers / pixels
    }
    public func matches(cameraID: String, size: CGSize, configuration: String) -> Bool {
        self.cameraID == cameraID && width == Int(size.width) && height == Int(size.height) && opticalConfiguration == configuration && micrometersPerPixel.isFinite && micrometersPerPixel > 0
    }
}

public enum StabilizationStrength: String, CaseIterable, Codable {
    case off = "Off", low = "Low", medium = "Medium", high = "High"
    public var alpha: Double { switch self { case .off: return 1; case .low: return 0.3; case .medium: return 0.15; case .high: return 0.07 } }
    public var margin: Double { self == .off ? 0 : 0.08 }
}

public struct MotionSmoother {
    private var position = CGPoint.zero
    private var smoothed = CGPoint.zero
    public private(set) var correction = CGPoint.zero
    public init() {}
    public mutating func reset() { self = MotionSmoother() }
    public mutating func update(translation: CGPoint?, strength: StabilizationStrength, locked: Bool, limit: CGSize) -> CGPoint {
        guard strength != .off else { reset(); return .zero }
        guard let t = translation, t.x.isFinite, t.y.isFinite else {
            // Rebase after tracking loss; gradually release the last compensation.
            position = .zero; smoothed = .zero
            correction.x *= 0.65; correction.y *= 0.65
            return correction
        }
        position.x += t.x; position.y += t.y
        let alpha = locked ? 0 : strength.alpha
        smoothed.x += (position.x - smoothed.x) * alpha
        smoothed.y += (position.y - smoothed.y) * alpha
        let desired = CGPoint(x: position.x - smoothed.x, y: position.y - smoothed.y)
        correction = CGPoint(x: min(limit.width, max(-limit.width, desired.x)), y: min(limit.height, max(-limit.height, desired.y)))
        // Anti-windup: subject lock can only compensate within the available crop.
        position = CGPoint(x: smoothed.x + correction.x, y: smoothed.y + correction.y)
        return correction
    }
}

public struct ImageSettings: Codable, Equatable {
    public var brightness: Double = 0
    public var contrast: Double = 1
    public var saturation: Double = 1
    public var sharpness: Double = 0
    public var exposure: Double = 0
    public var temperature: Double = 6500
    public var rotation: Int = 0
    public var flipH = false
    public var flipV = false
    public var grayscale = false
    public var inverted = false
    public init() {}
}

public struct PipelineSettings: Codable, Equatable {
    public var image = ImageSettings()
    public var viewport = Viewport()
    public var stabilization: StabilizationStrength = .medium
    public var lock = false
    // Optional for backwards-compatible decoding of existing saved settings.
    public var peaking: FocusPeakingSettings?
    public var workArea: WorkAreaSettings?
    public init() {}
}

public struct FocusPeakingSettings: Codable, Equatable {
    public var enabled = false
    /// Higher sensitivity includes lower-contrast edges, and may also highlight noise.
    public var sensitivity = 0.5
    public init() {}
}

public struct WorkAreaSettings: Codable, Equatable {
    public var x = 0.25, y = 0.25, width = 0.5, height = 0.5
    public init() {}
}
