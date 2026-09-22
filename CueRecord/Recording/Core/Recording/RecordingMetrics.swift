import AVFoundation
import CoreGraphics
import Foundation

nonisolated enum RecordingOutputHealth: String, Codable, Sendable {
    case healthy
    case degraded
    case damaged
}

nonisolated struct RecordingMetricsSnapshot: Codable, Sendable {
    let version: Int
    var health: RecordingOutputHealth
    var issues: [String]
    var startedAt: String
    var finishedAt: String?
    var mode: String
    var targetDisplayID: UInt32?
    var recordingRect: CodableMetricsRect?
    var outputWidth: Int
    var outputHeight: Int
    var pixelFormat: String
    var screenFramesAppended: Int64
    var screenFramesDroppedWriterNotReady: Int64
    var audioBuffersQueuedBeforeVideo: Int64
    var audioBuffersDroppedBeforeVideo: Int64
    var audioBuffersDroppedWriterNotReady: Int64
    var audioBuffersAppendFailed: Int64
    var partialAudioOverlapMilliseconds: Double
    var cameraFramesReceived: UInt64
    var cameraFramesWritten: Int64
    var cameraFramesDropped: Int
    var cameraFramesDroppedCaptureOutput: Int64
    var cameraFramesDroppedQueueOverflow: Int64
    var cameraFramesDroppedWriterNotReady: Int64
    var cameraFramesDroppedNonMonotonicPTS: Int64
    var cameraMaxPendingQueueDepth: Int
    var cameraLastRelativePTSSeconds: Double?
    var sessionDurationSeconds: Double?
    var screenDurationSeconds: Double?
    var cameraDurationSeconds: Double?
    var audioDurationSeconds: Double?
    var cameraAudioDriftMilliseconds: Double?
    var screenAudioDriftMilliseconds: Double?
    var outputFileBytes: Int64?
    var outputDurationSeconds: Double?
    var exportDurationSeconds: Double?
}

nonisolated struct CodableMetricsRect: Codable, Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(_ rect: CGRect) {
        x = rect.origin.x
        y = rect.origin.y
        width = rect.width
        height = rect.height
    }
}

@MainActor
final class RecordingMetricsRecorder {
    private var snapshot = RecordingMetricsSnapshot(
        version: 2,
        health: .healthy,
        issues: [],
        startedAt: ISO8601DateFormatter().string(from: Date()),
        finishedAt: nil,
        mode: "unknown",
        targetDisplayID: nil,
        recordingRect: nil,
        outputWidth: 0,
        outputHeight: 0,
        pixelFormat: "unknown",
        screenFramesAppended: 0,
        screenFramesDroppedWriterNotReady: 0,
        audioBuffersQueuedBeforeVideo: 0,
        audioBuffersDroppedBeforeVideo: 0,
        audioBuffersDroppedWriterNotReady: 0,
        audioBuffersAppendFailed: 0,
        partialAudioOverlapMilliseconds: 0,
        cameraFramesReceived: 0,
        cameraFramesWritten: 0,
        cameraFramesDropped: 0,
        cameraFramesDroppedCaptureOutput: 0,
        cameraFramesDroppedQueueOverflow: 0,
        cameraFramesDroppedWriterNotReady: 0,
        cameraFramesDroppedNonMonotonicPTS: 0,
        cameraMaxPendingQueueDepth: 0,
        cameraLastRelativePTSSeconds: nil,
        sessionDurationSeconds: nil,
        screenDurationSeconds: nil,
        cameraDurationSeconds: nil,
        audioDurationSeconds: nil,
        cameraAudioDriftMilliseconds: nil,
        screenAudioDriftMilliseconds: nil,
        outputFileBytes: nil,
        outputDurationSeconds: nil,
        exportDurationSeconds: nil
    )

    func configure(
        mode: String,
        displayID: CGDirectDisplayID?,
        recordingRect: CGRect?,
        outputWidth: Int,
        outputHeight: Int,
        pixelFormat: OSType
    ) {
        snapshot = RecordingMetricsSnapshot(
            version: 2,
            health: .healthy,
            issues: [],
            startedAt: ISO8601DateFormatter().string(from: Date()),
            finishedAt: nil,
            mode: mode,
            targetDisplayID: displayID,
            recordingRect: recordingRect.map(CodableMetricsRect.init),
            outputWidth: outputWidth,
            outputHeight: outputHeight,
            pixelFormat: Self.fourCharCode(pixelFormat),
            screenFramesAppended: 0,
            screenFramesDroppedWriterNotReady: 0,
            audioBuffersQueuedBeforeVideo: 0,
            audioBuffersDroppedBeforeVideo: 0,
            audioBuffersDroppedWriterNotReady: 0,
            audioBuffersAppendFailed: 0,
            partialAudioOverlapMilliseconds: 0,
            cameraFramesReceived: 0,
            cameraFramesWritten: 0,
            cameraFramesDropped: 0,
            cameraFramesDroppedCaptureOutput: 0,
            cameraFramesDroppedQueueOverflow: 0,
            cameraFramesDroppedWriterNotReady: 0,
            cameraFramesDroppedNonMonotonicPTS: 0,
            cameraMaxPendingQueueDepth: 0,
            cameraLastRelativePTSSeconds: nil,
            sessionDurationSeconds: nil,
            screenDurationSeconds: nil,
            cameraDurationSeconds: nil,
            audioDurationSeconds: nil,
            cameraAudioDriftMilliseconds: nil,
            screenAudioDriftMilliseconds: nil,
            outputFileBytes: nil,
            outputDurationSeconds: nil,
            exportDurationSeconds: nil
        )
    }

    func markFinished() {
        snapshot.finishedAt = ISO8601DateFormatter().string(from: Date())
    }

    func incrementScreenAppended() {
        snapshot.screenFramesAppended += 1
    }

    func incrementScreenWriterNotReady() {
        snapshot.screenFramesDroppedWriterNotReady += 1
    }

    func incrementQueuedAudioBeforeVideo() {
        snapshot.audioBuffersQueuedBeforeVideo += 1
    }

    func incrementDroppedAudioBeforeVideo() {
        snapshot.audioBuffersDroppedBeforeVideo += 1
    }

    func incrementAudioWriterNotReady() {
        snapshot.audioBuffersDroppedWriterNotReady += 1
    }

    func incrementAudioAppendFailed() {
        snapshot.audioBuffersAppendFailed += 1
    }

    func addPartialAudioOverlap(_ duration: CMTime) {
        guard duration.isValid else { return }
        snapshot.partialAudioOverlapMilliseconds += max(0, duration.seconds * 1000)
    }

    func updateCamera(received: UInt64, written: Int64, dropped: Int) {
        snapshot.cameraFramesReceived = received
        snapshot.cameraFramesWritten = written
        snapshot.cameraFramesDropped = dropped
    }

    func recordCameraDrop(_ reason: CameraDropReason) {
        switch reason {
        case .captureOutput: snapshot.cameraFramesDroppedCaptureOutput += 1
        case .queueOverflow: snapshot.cameraFramesDroppedQueueOverflow += 1
        case .writerNotReady: snapshot.cameraFramesDroppedWriterNotReady += 1
        case .nonMonotonicPTS: snapshot.cameraFramesDroppedNonMonotonicPTS += 1
        }
        snapshot.cameraFramesDropped = Int(
            snapshot.cameraFramesDroppedCaptureOutput
                + snapshot.cameraFramesDroppedQueueOverflow
                + snapshot.cameraFramesDroppedWriterNotReady
                + snapshot.cameraFramesDroppedNonMonotonicPTS
        )
    }

    func setDurations(
        session: Double?,
        screen: Double?,
        camera: Double?,
        audio: Double?,
        cameraAudioDriftMilliseconds: Double?,
        screenAudioDriftMilliseconds: Double?
    ) {
        snapshot.sessionDurationSeconds = session
        snapshot.screenDurationSeconds = screen
        snapshot.cameraDurationSeconds = camera
        snapshot.audioDurationSeconds = audio
        snapshot.cameraAudioDriftMilliseconds = cameraAudioDriftMilliseconds
        snapshot.screenAudioDriftMilliseconds = screenAudioDriftMilliseconds
    }

    func setCameraWriterState(maxPendingQueueDepth: Int, lastRelativePTSSeconds: Double?) {
        snapshot.cameraMaxPendingQueueDepth = max(snapshot.cameraMaxPendingQueueDepth, maxPendingQueueDepth)
        snapshot.cameraLastRelativePTSSeconds = lastRelativePTSSeconds
    }

    func applyCameraWriterSnapshot(
        received: UInt64,
        previewDropped: Int,
        framesWritten: Int64,
        droppedQueueOverflow: Int64,
        droppedWriterNotReady: Int64,
        droppedNonMonotonicPTS: Int64,
        maxPendingQueueDepth: Int,
        lastRelativePTSSeconds: Double?
    ) {
        snapshot.cameraFramesReceived = received
        snapshot.cameraFramesWritten = framesWritten
        snapshot.cameraFramesDroppedCaptureOutput = Int64(previewDropped)
        snapshot.cameraFramesDroppedQueueOverflow = droppedQueueOverflow
        snapshot.cameraFramesDroppedWriterNotReady = droppedWriterNotReady
        snapshot.cameraFramesDroppedNonMonotonicPTS = droppedNonMonotonicPTS
        snapshot.cameraFramesDropped = Int(
            snapshot.cameraFramesDroppedCaptureOutput
                + snapshot.cameraFramesDroppedQueueOverflow
                + snapshot.cameraFramesDroppedWriterNotReady
                + snapshot.cameraFramesDroppedNonMonotonicPTS
        )
        setCameraWriterState(
            maxPendingQueueDepth: maxPendingQueueDepth,
            lastRelativePTSSeconds: lastRelativePTSSeconds
        )
    }

    func applyValidation(_ validation: RecordingOutputValidation) {
        snapshot.health = validation.health
        snapshot.issues = validation.issues
        snapshot.outputFileBytes = validation.fileSize
        snapshot.outputDurationSeconds = validation.durationSeconds
    }

    func setExportDuration(_ duration: TimeInterval) {
        snapshot.exportDurationSeconds = duration
    }

    func write(to outputURL: URL) {
        var finalSnapshot = snapshot
        if finalSnapshot.finishedAt == nil {
            finalSnapshot.finishedAt = ISO8601DateFormatter().string(from: Date())
        }

        let metricsURL = Self.metricsURL(for: outputURL)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(finalSnapshot)
            try data.write(to: metricsURL)
            print("✅ Recording metrics saved: \(metricsURL.lastPathComponent)")
        } catch {
            print("❌ Failed to save recording metrics: \(error.localizedDescription)")
        }
    }

    nonisolated static func metricsURL(for outputURL: URL) -> URL {
        let baseName = outputURL.deletingPathExtension().lastPathComponent
        return outputURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(baseName)_metrics")
            .appendingPathExtension("json")
    }

    private static func fourCharCode(_ value: OSType) -> String {
        let scalars = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ]

        let printable = scalars.allSatisfy { $0 >= 32 && $0 <= 126 }
        if printable {
            return String(bytes: scalars, encoding: .macOSRoman) ?? "\(value)"
        }
        return "\(value)"
    }
}

nonisolated enum CameraDropReason: Sendable {
    case captureOutput
    case queueOverflow
    case writerNotReady
    case nonMonotonicPTS
}
