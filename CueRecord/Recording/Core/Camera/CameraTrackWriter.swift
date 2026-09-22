import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation

nonisolated struct CameraTrackWriterSnapshot: Sendable {
    let framesWritten: Int64
    let droppedQueueOverflow: Int64
    let droppedWriterNotReady: Int64
    let droppedNonMonotonicPTS: Int64
    let maxPendingQueueDepth: Int
    let lastRelativePTSSeconds: Double?
}

/// Owns camera rendering and encoding on one serial queue so capture and UI
/// work never have to wait for AVAssetWriter backpressure.
nonisolated final class CameraTrackWriter: @unchecked Sendable {
    private let writerQueue = DispatchQueue(label: "cuerecord.camera-track-writer", qos: .userInitiated)
    private let ingress: CameraWriterIngress<CameraFrameSample>
    private let outputURL: URL
    private let timeline: RecordingTimeline
    private let onFrameWritten: (Double, Int64) -> Void

    private let ciContext = CIContext()
    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var pixelBufferAdapter: AVAssetWriterInputPixelBufferAdaptor?
    private var outputDimensions: (width: Int, height: Int)?
    private var framesWritten: Int64 = 0
    private var droppedWriterNotReady: Int64 = 0
    private var droppedNonMonotonicPTS: Int64 = 0
    private var lastRelativePTSSeconds: Double?

    init(
        outputURL: URL,
        timeline: RecordingTimeline,
        capacity: Int = 12,
        onFrameWritten: @escaping (Double, Int64) -> Void
    ) {
        self.outputURL = outputURL
        self.timeline = timeline
        self.ingress = CameraWriterIngress(capacity: capacity)
        self.onFrameWritten = onFrameWritten
    }

    func append(_ frame: CameraFrameSample) {
        if ingress.submit(frame) == .scheduled {
            writerQueue.async { [weak self] in
                self?.drainPendingFrames()
            }
        }
    }

    func finish() async -> CameraTrackWriterSnapshot {
        ingress.close()
        return await withCheckedContinuation { continuation in
            writerQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: CameraTrackWriterSnapshot(
                        framesWritten: 0,
                        droppedQueueOverflow: 0,
                        droppedWriterNotReady: 0,
                        droppedNonMonotonicPTS: 0,
                        maxPendingQueueDepth: 0,
                        lastRelativePTSSeconds: nil
                    ))
                    return
                }

                self.drainPendingFrames()
                guard let writer = self.writer else {
                    continuation.resume(returning: self.snapshot())
                    return
                }

                self.writerInput?.markAsFinished()
                writer.finishWriting { [weak self] in
                    guard let self else { return }
                    self.writerQueue.async {
                        continuation.resume(returning: self.snapshot())
                    }
                }
            }
        }
    }

    func cancel() {
        ingress.close()
        writerQueue.async { [weak self] in
            self?.writer?.cancelWriting()
        }
    }

    private func drainPendingFrames() {
        while let frame = ingress.takeNext() {
            appendOnWriterQueue(frame)
        }
    }

    private func appendOnWriterQueue(_ frame: CameraFrameSample) {
        guard frame.timestamp.isValid,
              let presentationTime = timeline.map(frame.timestamp, source: .camera) else {
            droppedNonMonotonicPTS += 1
            return
        }

        let processedFrame = CameraFrameProcessor.mirroredVisibleImage(from: frame.pixelBuffer)
        guard ensureWriter(for: processedFrame) else { return }
        guard let writer,
              let writerInput,
              let pixelBufferAdapter,
              let outputDimensions,
              writer.status == .writing else {
            return
        }

        guard writerInput.isReadyForMoreMediaData else {
            droppedWriterNotReady += 1
            return
        }
        guard let outputPixelBuffer = render(
            processedFrame.image,
            sourceExtent: processedFrame.extent,
            width: outputDimensions.width,
            height: outputDimensions.height,
            adapter: pixelBufferAdapter
        ) else {
            droppedWriterNotReady += 1
            return
        }

        guard pixelBufferAdapter.append(outputPixelBuffer, withPresentationTime: presentationTime) else {
            droppedWriterNotReady += 1
            return
        }

        framesWritten += 1
        lastRelativePTSSeconds = presentationTime.seconds.isFinite ? presentationTime.seconds : lastRelativePTSSeconds
        if framesWritten == 1 || framesWritten.isMultiple(of: 8), let lastRelativePTSSeconds {
            onFrameWritten(lastRelativePTSSeconds, framesWritten)
        }
    }

    private func ensureWriter(for frame: (image: CIImage, extent: CGRect)) -> Bool {
        guard writer == nil else { return true }
        let dimensions = CameraFrameProcessor.evenDimensions(for: frame.extent.size)

        do {
            let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
            let bitRate = max(4_000_000, dimensions.width * dimensions.height * 4)
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: dimensions.width,
                AVVideoHeightKey: dimensions.height,
                AVVideoColorPropertiesKey: [
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
                ],
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: bitRate,
                    AVVideoMaxKeyFrameIntervalKey: 30,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                    AVVideoAllowFrameReorderingKey: false,
                    AVVideoExpectedSourceFrameRateKey: 30,
                    AVVideoQualityKey: 0.9
                ]
            ]
            let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            writerInput.expectsMediaDataInRealTime = true
            guard writer.canAdd(writerInput) else { return false }
            writer.add(writerInput)

            let adapter = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: writerInput,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: dimensions.width,
                    kCVPixelBufferHeightKey as String: dimensions.height,
                    kCVPixelBufferCGImageCompatibilityKey as String: true,
                    kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
                ]
            )
            guard writer.startWriting() else { return false }
            writer.startSession(atSourceTime: .zero)

            self.writer = writer
            self.writerInput = writerInput
            self.pixelBufferAdapter = adapter
            self.outputDimensions = dimensions
            return true
        } catch {
            return false
        }
    }

    private func render(
        _ image: CIImage,
        sourceExtent: CGRect,
        width: Int,
        height: Int,
        adapter: AVAssetWriterInputPixelBufferAdaptor
    ) -> CVPixelBuffer? {
        guard let pool = adapter.pixelBufferPool else { return nil }
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer) == kCVReturnSuccess,
              let pixelBuffer else {
            return nil
        }

        let outputExtent = CGRect(x: 0, y: 0, width: width, height: height)
        let scale = max(
            outputExtent.width / max(sourceExtent.width, 1),
            outputExtent.height / max(sourceExtent.height, 1)
        )
        let scaled = image
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(
                translationX: outputExtent.midX - sourceExtent.width * scale / 2 - sourceExtent.minX * scale,
                y: outputExtent.midY - sourceExtent.height * scale / 2 - sourceExtent.minY * scale
            ))

        ciContext.render(
            scaled,
            to: pixelBuffer,
            bounds: outputExtent,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return pixelBuffer
    }

    private func snapshot() -> CameraTrackWriterSnapshot {
        let ingressSnapshot = ingress.snapshot
        return CameraTrackWriterSnapshot(
            framesWritten: framesWritten,
            droppedQueueOverflow: ingressSnapshot.droppedQueueOverflow,
            droppedWriterNotReady: droppedWriterNotReady,
            droppedNonMonotonicPTS: droppedNonMonotonicPTS,
            maxPendingQueueDepth: ingressSnapshot.maxPendingDepth,
            lastRelativePTSSeconds: lastRelativePTSSeconds
        )
    }
}
