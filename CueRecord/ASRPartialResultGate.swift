import Foundation

nonisolated struct ASRPartialResultGate: Sendable {
    let minimumInterval: TimeInterval
    private var lastText = ""
    private var lastDeliveryTime: TimeInterval?

    init(minimumInterval: TimeInterval = 0.12) {
        self.minimumInterval = max(0, minimumInterval)
    }

    mutating func accepts(_ text: String, at time: TimeInterval) -> Bool {
        guard !text.isEmpty, text != lastText else { return false }
        guard lastDeliveryTime.map({ time - $0 >= minimumInterval }) ?? true else {
            return false
        }
        lastText = text
        lastDeliveryTime = time
        return true
    }

    mutating func reset() {
        lastText = ""
        lastDeliveryTime = nil
    }
}
