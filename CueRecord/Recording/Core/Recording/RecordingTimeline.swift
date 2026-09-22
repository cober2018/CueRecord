import CoreMedia
import Foundation

nonisolated enum RecordingSource: Hashable, Sendable {
    case screen
    case camera
    case microphone
    case systemAudio
}

/// Maps source presentation timestamps onto one session-relative media clock.
/// The lock keeps the small amount of timeline state safe for capture queues.
nonisolated final class RecordingTimeline: @unchecked Sendable {
    private let lock = NSLock()
    private var sessionOrigin: CMTime?
    private var lastMappedPTS: [RecordingSource: CMTime] = [:]

    init() {}

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        sessionOrigin = nil
        lastMappedPTS.removeAll(keepingCapacity: true)
    }

    func start(at pts: CMTime) {
        guard pts.isValid else { return }
        lock.lock()
        defer { lock.unlock() }
        if sessionOrigin == nil {
            sessionOrigin = pts
        }
    }

    var origin: CMTime? {
        lock.lock()
        defer { lock.unlock() }
        return sessionOrigin
    }

    /// Returns nil for invalid, pre-origin, or non-monotonic samples.
    func map(_ pts: CMTime, source: RecordingSource) -> CMTime? {
        guard pts.isValid else { return nil }
        lock.lock()
        defer { lock.unlock() }

        guard let sessionOrigin else { return nil }
        let mapped = CMTimeSubtract(pts, sessionOrigin)
        guard mapped.isValid, mapped >= .zero else { return nil }
        if let previous = lastMappedPTS[source], mapped < previous {
            return nil
        }
        lastMappedPTS[source] = mapped
        return mapped
    }

    func lastPTS(for source: RecordingSource) -> CMTime? {
        lock.lock()
        defer { lock.unlock() }
        return lastMappedPTS[source]
    }
}
