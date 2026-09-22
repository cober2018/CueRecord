import Foundation

nonisolated struct ASRRuntimeMetricsSnapshot: Codable, Equatable, Sendable {
    let audioSeconds: Double
    let decodeSeconds: Double
    let realTimeFactor: Double?
}

nonisolated struct ASRRuntimeMetrics: Sendable {
    private var audioSeconds = 0.0
    private var decodeSeconds = 0.0

    mutating func record(audioSeconds: Double, decodeSeconds: Double) {
        self.audioSeconds += max(0, audioSeconds)
        self.decodeSeconds += max(0, decodeSeconds)
    }

    var snapshot: ASRRuntimeMetricsSnapshot {
        ASRRuntimeMetricsSnapshot(
            audioSeconds: audioSeconds,
            decodeSeconds: decodeSeconds,
            realTimeFactor: audioSeconds > 0 ? decodeSeconds / audioSeconds : nil
        )
    }
}
