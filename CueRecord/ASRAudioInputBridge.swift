@preconcurrency import AVFoundation
import Foundation

/// Owns the handoff between a recording microphone tap and live recognition.
/// The callback is read under a lock and invoked after release so ASR work can
/// never hold the routing lock or block recording lifecycle changes.
nonisolated final class ASRAudioInputBridge {
    static let shared = ASRAudioInputBridge()

    private let lock = NSLock()
    private let inputQueue = DispatchQueue(label: "com.nolanlai.cuerecord.asr-input")
    private var recordingInputActive = false
    private var consumer: ((AVAudioPCMBuffer) -> Void)?
    private var stateHandler: ((Bool) -> Void)?

    var isRecordingInputActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return recordingInputActive
    }

    func beginRecordingInput() {
        updateRecordingInput(active: true)
    }

    func endRecordingInput() {
        updateRecordingInput(active: false)
    }

    @discardableResult
    func attach(_ consumer: @escaping (AVAudioPCMBuffer) -> Void) -> Bool {
        lock.lock()
        self.consumer = consumer
        let active = recordingInputActive
        lock.unlock()
        return active
    }

    func detach() {
        lock.lock()
        consumer = nil
        lock.unlock()
    }

    func setStateHandler(_ handler: ((Bool) -> Void)?) {
        lock.lock()
        stateHandler = handler
        lock.unlock()
    }

    func submit(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let consumer = self.consumer
        let active = recordingInputActive
        lock.unlock()

        guard active,
              let consumer,
              let bufferCopy = buffer.copy() as? AVAudioPCMBuffer else {
            return
        }

        inputQueue.async {
            consumer(bufferCopy)
        }
    }

    private func updateRecordingInput(active: Bool) {
        lock.lock()
        let changed = recordingInputActive != active
        recordingInputActive = active
        let handler = stateHandler
        lock.unlock()

        if changed {
            handler?(active)
        }
    }
}
