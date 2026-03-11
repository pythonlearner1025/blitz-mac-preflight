import Foundation
import AVFoundation
import CoreVideo
import CoreMedia

/// Screen recording service using AVAssetWriter
/// Port of src-tauri/src/recording/encoder.rs
final class RecordingService: @unchecked Sendable {
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var isWriting = false
    private var sessionStartTime: CMTime?
    private var frameCount: Int64 = 0

    private(set) var outputURL: URL?
    private(set) var recordingWidth: Int = 0
    private(set) var recordingHeight: Int = 0

    /// Start a new recording
    func startRecording(width: Int, height: Int, format: String = "mov") throws {
        guard !isWriting else { return }

        let tempDir = FileManager.default.temporaryDirectory
        let ext = format == "mp4" ? "mp4" : "mov"
        let filename = "blitz-recording-\(Int(Date().timeIntervalSince1970)).\(ext)"
        let url = tempDir.appendingPathComponent(filename)

        let fileType: AVFileType = format == "mp4" ? .mp4 : .mov
        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)

        // H.264 video settings
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: width * height * 4, // ~4 bits per pixel
                AVVideoMaxKeyFrameIntervalKey: 30,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ]
        ]

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = true

        let sourceAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ]

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: sourceAttributes
        )

        writer.add(input)
        // 10-second fragments for crash resilience
        writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)

        guard writer.startWriting() else {
            throw RecordingError.failedToStart(writer.error?.localizedDescription ?? "Unknown error")
        }

        self.assetWriter = writer
        self.videoInput = input
        self.pixelBufferAdaptor = adaptor
        self.outputURL = url
        self.recordingWidth = width
        self.recordingHeight = height
        self.isWriting = true
        self.sessionStartTime = nil
        self.frameCount = 0
    }

    /// Append a video frame
    func appendFrame(_ pixelBuffer: CVPixelBuffer, timestamp: CMTime) {
        guard isWriting, let input = videoInput, let adaptor = pixelBufferAdaptor else { return }

        // Start session on first frame
        if sessionStartTime == nil {
            sessionStartTime = timestamp
            assetWriter?.startSession(atSourceTime: timestamp)
        }

        guard input.isReadyForMoreMediaData else { return }

        // Handle dimension mismatch (if simulator resized during recording)
        let bufWidth = CVPixelBufferGetWidth(pixelBuffer)
        let bufHeight = CVPixelBufferGetHeight(pixelBuffer)

        if bufWidth != recordingWidth || bufHeight != recordingHeight {
            // Skip mismatched frames (could implement rescaling here)
            return
        }

        adaptor.append(pixelBuffer, withPresentationTime: timestamp)
        frameCount += 1
    }

    /// Stop recording and finalize the file
    func stopRecording() async -> URL? {
        guard isWriting, let writer = assetWriter else { return nil }

        videoInput?.markAsFinished()
        isWriting = false

        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }

        let url = outputURL
        assetWriter = nil
        videoInput = nil
        pixelBufferAdaptor = nil
        outputURL = nil

        return url
    }

    enum RecordingError: Error, LocalizedError {
        case failedToStart(String)

        var errorDescription: String? {
            switch self {
            case .failedToStart(let msg): return "Failed to start recording: \(msg)"
            }
        }
    }
}
