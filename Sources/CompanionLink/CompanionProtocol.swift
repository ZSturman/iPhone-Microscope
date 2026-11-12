import Foundation

public enum StreamQuality: String, Codable, CaseIterable {
    case hd, ultraHD
    public var label: String { self == .hd ? "1080p" : "4K" }
    public var width: Int { self == .hd ? 1920 : 3840 }
    public var height: Int { self == .hd ? 1080 : 2160 }
    public var fps: Int { self == .hd ? 30 : 15 }
}

public struct PhoneLens: Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

public struct PhoneCameraState: Codable, Equatable {
    public var deviceID: String
    public var revision: Int
    public var lenses: [PhoneLens]
    public var lensID: String
    public var quality: StreamQuality
    public var supportedQualities: [StreamQuality]
    public var zoom: Double
    public var minZoom: Double
    public var maxZoom: Double
    public var losslessZoomLimit: Double
    public var manualFocus: Double?
    public var supportsManualFocus: Bool
    public var supportsFocusLock: Bool
    public var supportsExposureLock: Bool
    public var supportsWhiteBalanceLock: Bool
    public var focusLocked: Bool
    public var exposureLocked: Bool
    public var whiteBalanceLocked: Bool
    public var exposureBias: Double
    public var minExposureBias: Double
    public var maxExposureBias: Double
    public var supportsTorch: Bool
    public var torch: Bool
    // Nil when talking to a pre-frame-rate-control companion.
    public var minimumFocusDistanceMM: Int? = nil
    public var depthAvailable: Bool? = nil
    public var frameRate: Int? = nil
    public var supportedFrameRates: [Int]? = nil
    public var captureFPS: Int { frameRate ?? quality.fps }

    public var isValid: Bool {
        let numbers = [zoom, minZoom, maxZoom, losslessZoomLimit, exposureBias, minExposureBias, maxExposureBias]
        return numbers.allSatisfy(\.isFinite) && revision >= 0 && !deviceID.isEmpty && lenses.count <= 10 &&
            lenses.contains(where: { $0.id == lensID }) && supportedQualities.contains(quality) &&
            minZoom >= 1 && maxZoom >= minZoom && maxZoom <= 200 && zoom >= minZoom && zoom <= maxZoom && losslessZoomLimit >= 1 &&
            minExposureBias <= exposureBias && exposureBias <= maxExposureBias &&
            (manualFocus.map { $0.isFinite && (0...1).contains($0) } ?? true) &&
            (frameRate.map { rate in supportedFrameRates?.contains(rate) == true } ?? (supportedFrameRates == nil)) &&
            (supportedFrameRates.map { !$0.isEmpty && $0.count <= 6 && Set($0).count == $0.count && $0.allSatisfy { (1...60).contains($0) } } ?? true)
    }
}

public enum PhoneCameraCommand: Codable, Equatable {
    case lens(String)
    case quality(StreamQuality)
    case frameRate(Int)
    case zoom(Double)
    case focus(Double?)
    case exposure(Double)
    case torch(Bool)
    case locks(focus: Bool, exposure: Bool, whiteBalance: Bool)
}

public struct CompanionFrame: Codable, Equatable {
    public var sequence: UInt64
    public var revision: Int
    public var seconds: Double
    public var width: Int
    public var height: Int
    public var isValid: Bool {
        seconds.isFinite && seconds >= 0 && revision >= 0 && width > 0 && height > 0 && width <= 3840 && height <= 2160
    }
}

public enum CompanionMessage: Codable, Equatable {
    case hello(version: Int, code: String)
    case pair(version: Int, code: String, viewerID: String)
    case credential(cameraID: String, secret: Data)
    case challenge(String)
    case resume(viewerID: String, nonce: String, proof: Data)
    case resumed(proof: Data)
    case authenticated
    case state(PhoneCameraState)
    case command(id: UUID, PhoneCameraCommand)
    case reply(id: UUID, error: String?)
    case frame(CompanionFrame)
    case acknowledgement(UInt64)
}

/// One MCSession message = big-endian JSON length + JSON + optional JPEG.
/// Limits bound decoding and retained image memory; versioning is in the authenticated hello.
public enum CompanionPacket {
    public static let version = 2
    public static let maxHeader = 32_768
    public static let maxJPEG = 12 * 1_024 * 1_024
    public enum PacketError: Error { case malformed, oversized }

    public static func encode(_ message: CompanionMessage, jpeg: Data = Data()) throws -> Data {
        let header = try JSONEncoder().encode(message)
        guard header.count <= maxHeader, jpeg.count <= maxJPEG else { throw PacketError.oversized }
        if case .frame(let frame) = message {
            guard frame.isValid, !jpeg.isEmpty else { throw PacketError.malformed }
        } else if !jpeg.isEmpty { throw PacketError.malformed }
        let count = UInt32(header.count)
        var data = Data([UInt8(count >> 24), UInt8((count >> 16) & 255), UInt8((count >> 8) & 255), UInt8(count & 255)])
        data.append(header); data.append(jpeg)
        return data
    }

    public static func decode(_ data: Data) throws -> (CompanionMessage, Data) {
        guard data.count >= 4, data.count <= maxJPEG + maxHeader + 4 else { throw PacketError.oversized }
        let length = data.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        guard length > 0, length <= maxHeader, length <= data.count - 4 else { throw PacketError.malformed }
        let start = data.startIndex + 4
        let message = try JSONDecoder().decode(CompanionMessage.self, from: data[start..<(start + length)])
        let jpeg = Data(data[(start + length)...])
        if case .frame(let frame) = message {
            guard frame.isValid, !jpeg.isEmpty, jpeg.count <= maxJPEG else { throw PacketError.malformed }
        } else if !jpeg.isEmpty { throw PacketError.malformed }
        if case .state(let state) = message, !state.isValid { throw PacketError.malformed }
        return (message, jpeg)
    }
}
