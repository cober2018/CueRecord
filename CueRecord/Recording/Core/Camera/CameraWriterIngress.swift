import CoreMedia
import CoreVideo
import Foundation

nonisolated enum CameraWriterIngressSubmission: Equatable {
    case scheduled
    case enqueued
    case droppedOldest
    case rejected
}

nonisolated struct CameraWriterIngressSnapshot: Equatable, Sendable {
    let droppedQueueOverflow: Int64
    let maxPendingDepth: Int
}

/// A lock-protected ingress keeps capture callbacks non-blocking while placing
/// a strict bound on work waiting for the serial camera writer.
nonisolated final class CameraWriterIngress<Element>: @unchecked Sendable {
    private let lock = NSLock()
    private let capacity: Int
    private var pending: [Element] = []
    private var isDraining = false
    private var isOpen = true
    private var droppedQueueOverflow: Int64 = 0
    private var maxPendingDepth = 0

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    func submit(_ element: Element) -> CameraWriterIngressSubmission {
        lock.lock()
        defer { lock.unlock() }

        guard isOpen else { return .rejected }

        var didDropOldest = false
        if pending.count >= capacity {
            pending.removeFirst()
            droppedQueueOverflow += 1
            didDropOldest = true
        }
        pending.append(element)
        maxPendingDepth = max(maxPendingDepth, pending.count)

        if !isDraining {
            isDraining = true
            return .scheduled
        }
        return didDropOldest ? .droppedOldest : .enqueued
    }

    func takeNext() -> Element? {
        lock.lock()
        defer { lock.unlock() }

        guard !pending.isEmpty else {
            isDraining = false
            return nil
        }
        return pending.removeFirst()
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        isOpen = false
    }

    var snapshot: CameraWriterIngressSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return CameraWriterIngressSnapshot(
            droppedQueueOverflow: droppedQueueOverflow,
            maxPendingDepth: maxPendingDepth
        )
    }
}

nonisolated final class CameraRecordingSink: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((CameraFrameSample) -> Void)?
    private var sequence: UInt64 = 0

    func setHandler(_ handler: ((CameraFrameSample) -> Void)?) {
        lock.lock()
        defer { lock.unlock() }
        self.handler = handler
    }

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return handler != nil
    }

    func deliver(pixelBuffer: CVPixelBuffer, timestamp: CMTime) {
        lock.lock()
        sequence &+= 1
        let handler = handler
        let frame = CameraFrameSample(pixelBuffer: pixelBuffer, timestamp: timestamp, sequence: sequence)
        lock.unlock()
        handler?(frame)
    }
}
