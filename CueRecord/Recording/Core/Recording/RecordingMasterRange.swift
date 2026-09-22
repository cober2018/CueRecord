import CoreMedia
import Foundation

nonisolated enum RecordingCameraTailHandling: Equatable, Sendable {
    case none
    case holdLastFrame
    case hidden
}

nonisolated struct RecordingMasterRange: Equatable, Sendable {
    let duration: CMTime
    let cameraTail: RecordingCameraTailHandling

    static func resolve(
        sessionDuration: CMTime?,
        screenDuration: CMTime?,
        cameraDuration: CMTime?,
        audioDuration: CMTime?
    ) -> RecordingMasterRange {
        let duration = firstUsableDuration(sessionDuration)
            ?? firstUsableDuration(screenDuration)
            ?? firstUsableDuration(audioDuration)
            ?? .zero

        let cameraTail: RecordingCameraTailHandling
        if let cameraDuration = firstUsableDuration(cameraDuration) {
            cameraTail = cameraDuration < duration ? .holdLastFrame : .none
        } else {
            cameraTail = .hidden
        }

        return RecordingMasterRange(duration: duration, cameraTail: cameraTail)
    }

    func matchesOutputDuration(_ outputDuration: CMTime, tolerance: CMTime) -> Bool {
        guard duration.isValid,
              outputDuration.isValid,
              tolerance.isValid,
              duration >= .zero,
              outputDuration >= .zero,
              tolerance >= .zero else {
            return false
        }

        return CMTimeAbsoluteValue(outputDuration - duration) <= tolerance
    }

    private static func firstUsableDuration(_ duration: CMTime?) -> CMTime? {
        guard let duration, duration.isValid, duration > .zero else { return nil }
        return duration
    }
}
