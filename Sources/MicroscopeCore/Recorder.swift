import Foundation
import AVFoundation
import CoreImage

public final class FrameRecorder {
    private let queue = DispatchQueue(label: "microscope.writer", qos: .userInitiated)
    private let gate = NSLock()
    private var pending = 0
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var firstTime: CMTime?
    private var lastTime = CMTime.invalid
    private var size = CGSize.zero
    private var failure: Error?
    public var onError: ((String) -> Void)?
    public var onDrop: (() -> Void)?
    public init() {}
    public func start(url: URL, size: CGSize, completion: @escaping (Error?) -> Void) {
        queue.async {
            do {
                guard self.writer == nil else { throw RecorderError.alreadyRecording }
                let writer = try AVAssetWriter(outputURL: url, fileType: url.pathExtension == "mp4" ? .mp4 : .mov)
                let width = max(2, Int(size.width) / 2 * 2), height = max(2, Int(size.height) / 2 * 2)
                let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height, AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: min(80_000_000, width * height * 6), AVVideoExpectedSourceFrameRateKey: 30]])
                input.expectsMediaDataInRealTime = true
                let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height, kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
                guard writer.canAdd(input) else { throw RecorderError.cannotConfigure }
                writer.add(input)
                guard writer.startWriting() else { throw writer.error ?? RecorderError.cannotConfigure }
                self.writer = writer; self.input = input; self.adaptor = adaptor
                self.size = CGSize(width: width, height: height); self.firstTime = nil; self.lastTime = .invalid; self.failure = nil
                completion(nil)
            } catch { completion(error) }
        }
    }
    public func append(_ image: CIImage, at time: CMTime) {
        gate.lock()
        guard pending < 3 else { gate.unlock(); onDrop?(); return }
        pending += 1; gate.unlock()
        queue.async {
            defer { self.gate.lock(); self.pending -= 1; self.gate.unlock() }
            guard let writer = self.writer, let input = self.input, let adaptor = self.adaptor, self.failure == nil else { return }
            guard writer.status == .writing else { self.fail(writer.error ?? RecorderError.appendFailed); return }
            guard input.isReadyForMoreMediaData else { self.onDrop?(); return }
            guard time.isNumeric, !self.lastTime.isValid || time > self.lastTime else { self.onDrop?(); return }
            if self.firstTime == nil { writer.startSession(atSourceTime: time); self.firstTime = time }
            guard let pool = adaptor.pixelBufferPool else { self.fail(RecorderError.cannotConfigure); return }
            var buffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { self.onDrop?(); return }
            let bounds = CGRect(origin: .zero, size: self.size)
            let scale = min(self.size.width / image.extent.width, self.size.height / image.extent.height)
            let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let centered = scaled.transformed(by: CGAffineTransform(translationX: (self.size.width - scaled.extent.width) / 2 - scaled.extent.minX, y: (self.size.height - scaled.extent.height) / 2 - scaled.extent.minY))
            self.context.render(centered.composited(over: CIImage(color: .black).cropped(to: bounds)), to: buffer, bounds: bounds, colorSpace: CGColorSpaceCreateDeviceRGB())
            if !adaptor.append(buffer, withPresentationTime: time) { self.fail(writer.error ?? RecorderError.appendFailed) }
            else { self.lastTime = time }
        }
    }
    private func fail(_ error: Error) { if failure == nil { failure = error; onError?(error.localizedDescription) } }
    public func stop(completion: @escaping (Error?) -> Void) {
        queue.async {
            guard let writer = self.writer else { completion(RecorderError.noFrames); return }
            let failure = self.failure
            if self.firstTime == nil || failure != nil {
                writer.cancelWriting(); self.clear(); completion(failure ?? RecorderError.noFrames); return
            }
            self.input?.markAsFinished()
            writer.finishWriting {
                self.queue.async {
                    let error = writer.status == .completed ? nil : (writer.error ?? RecorderError.appendFailed)
                    self.clear(); completion(error)
                }
            }
        }
    }
    private func clear() { writer = nil; input = nil; adaptor = nil; firstTime = nil }
    public enum RecorderError: LocalizedError {
        case alreadyRecording, cannotConfigure, appendFailed, noFrames
        public var errorDescription: String? {
            switch self {
            case .alreadyRecording: return "A recording is already active."
            case .cannotConfigure: return "The video encoder could not be configured. Try a lower resolution."
            case .appendFailed: return "The video encoder failed. Check free disk space."
            case .noFrames: return "No video frames were recorded."
            }
        }
    }
}
