import AVFoundation
import CoreGraphics

/// Provider boundary for live speech recognition. Implementations own their
/// audio capture/decode queues and publish UI-safe events through callbacks.
nonisolated protocol StreamingASRProvider: AnyObject {
    var onTextUpdate: ((String) -> Void)? { get set }
    var onNewSegment: (() -> Void)? { get set }
    var onLevelUpdate: ((CGFloat) -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }

    func start(selectedMicUID: String)
    func startExternalInput()
    func submitExternalAudio(_ buffer: AVAudioPCMBuffer)
    func stop()
}

extension SherpaOnnxStreamingASR: StreamingASRProvider {}
