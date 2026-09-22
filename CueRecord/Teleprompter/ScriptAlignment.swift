import Foundation

nonisolated struct ScriptToken: Identifiable, Equatable, Sendable {
    let id: Int
    let raw: String
    let normalized: String
    let spoken: Bool
    let displayEndOffset: Int
}

nonisolated enum ScriptAlignmentMode: Sendable, Equatable {
    case tracking
    case uncertain
    case lost
}

nonisolated struct ScriptAlignmentState: Sendable, Equatable {
    var committedTokenIndex = 0
    var speculativeTokenIndex = 0
    var confidence = 0.0
    var mode: ScriptAlignmentMode = .tracking
}

nonisolated struct ScriptAlignmentResult: Sendable, Equatable {
    let candidateTokenIndex: Int
    let score: Double
    let committed: Bool
    let mode: ScriptAlignmentMode
    let isLargeJump: Bool

    var allowsLegacyFallback: Bool {
        mode != .lost && !isLargeJump
    }
}

nonisolated enum ScriptNormalizer {
    static func normalize(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    static func tokenize(_ text: String) -> [ScriptToken] {
        var result: [ScriptToken] = []
        var buffer = ""
        var bufferEndOffset = 0
        var inAnnotation = false
        var displayOffset = 0

        func flush(spoken: Bool = true) {
            guard !buffer.isEmpty else { return }
            let raw = buffer
            buffer = ""
            let normalized = normalize(raw)
            guard !normalized.isEmpty else { return }
            result.append(
                ScriptToken(
                    id: result.count,
                    raw: raw,
                    normalized: normalized,
                    spoken: spoken,
                    displayEndOffset: bufferEndOffset
                )
            )
        }

        for character in text {
            if ["[", "【", "（"].contains(character) {
                flush()
                inAnnotation = true
                displayOffset += 1
                continue
            }
            if inAnnotation {
                if ["]", "】", "）"].contains(character) {
                    inAnnotation = false
                }
                displayOffset += 1
                continue
            }

            let isCJK = character.unicodeScalars.first?.isCJK == true
            if isCJK {
                flush()
                result.append(
                    ScriptToken(
                        id: result.count,
                        raw: String(character),
                        normalized: normalize(String(character)),
                        spoken: true,
                        displayEndOffset: displayOffset + 1
                    )
                )
            } else if character.isLetter || character.isNumber {
                buffer.append(character)
                bufferEndOffset = displayOffset + 1
            } else {
                flush()
            }
            displayOffset += 1
        }
        flush(spoken: !inAnnotation)
        return result
    }
}

nonisolated final class ScriptAligner {
    let tokens: [ScriptToken]
    private(set) var state = ScriptAlignmentState()
    private var recentCandidates: [Int] = []
    private var lastTrustedTime: TimeInterval?
    private var untrustedSince: TimeInterval?

    private let observedTailLimit = 12
    private let normalLookAhead = 61
    private let recoveryLookAhead = 241
    private let lostTimeout: TimeInterval = 1.5

    init(script: String) {
        tokens = ScriptNormalizer.tokenize(script)
    }

    @discardableResult
    func consume(_ asrText: String, now: TimeInterval) -> ScriptAlignmentResult? {
        let allObserved = ScriptNormalizer.tokenize(asrText).filter(\.spoken).map(\.normalized)
        let observed = Array(allObserved.suffix(observedTailLimit))
        guard !observed.isEmpty, !tokens.isEmpty else { return nil }

        if lastTrustedTime == nil, untrustedSince == nil {
            untrustedSince = now
        }
        let elapsedWithoutTrust = lastTrustedTime.map { now - $0 }
            ?? untrustedSince.map { now - $0 }
            ?? 0
        let isRecovering = state.mode == .lost || elapsedWithoutTrust >= lostTimeout
        let lookBehind = max(3, observed.count + 3)
        let lowerBound = max(0, state.committedTokenIndex - lookBehind)
        let lookAhead = isRecovering ? recoveryLookAhead : normalLookAhead
        let upperBound = min(tokens.count, state.committedTokenIndex + lookAhead)
        var best: (index: Int, score: Double)?

        for start in lowerBound..<upperBound {
            let minimumLength = max(1, observed.count - 2)
            let maximumLength = min(observed.count + 3, upperBound - start)
            guard minimumLength <= maximumLength else { continue }
            for length in minimumLength...maximumLength {
                let candidate = tokens[start..<(start + length)].filter(\.spoken).map(\.normalized)
                let similarity = Self.similarity(observed, candidate)
                let candidateEnd = start + length
                let positionPrior = candidateEnd >= state.committedTokenIndex ? 1.0 : 0.85
                let score = similarity * 0.85 + positionPrior * 0.15
                if best == nil || score > best!.score {
                    best = (candidateEnd, score)
                }
            }
        }

        guard let best else { return nil }
        state.speculativeTokenIndex = max(state.speculativeTokenIndex, best.index)
        state.confidence = best.score

        let largeJump = best.index - state.committedTokenIndex > 12
        recentCandidates.append(best.index)
        if recentCandidates.count > 3 { recentCandidates.removeFirst() }
        let consensus = recentCandidates.filter { abs($0 - best.index) <= 3 }.count >= 2
        let trusted = best.score >= (largeJump ? 0.80 : 0.68) && (!largeJump || consensus)

        if trusted {
            state.committedTokenIndex = max(state.committedTokenIndex, best.index)
            state.mode = .tracking
            lastTrustedTime = now
            untrustedSince = nil
        } else if elapsedWithoutTrust >= lostTimeout {
            state.mode = .lost
        } else {
            state.mode = .uncertain
        }

        return ScriptAlignmentResult(
            candidateTokenIndex: best.index,
            score: best.score,
            committed: trusted,
            mode: state.mode,
            isLargeJump: largeJump
        )
    }

    func reanchor(to tokenIndex: Int) {
        let clamped = min(max(0, tokenIndex), tokens.count)
        state.committedTokenIndex = clamped
        state.speculativeTokenIndex = clamped
        state.confidence = 1
        state.mode = .tracking
        recentCandidates = [clamped]
        lastTrustedTime = nil
        untrustedSince = nil
    }

    func reanchor(displayOffset: Int) {
        let clampedOffset = max(0, displayOffset)
        let tokenIndex = tokens.firstIndex { $0.displayEndOffset > clampedOffset }
            ?? tokens.count
        reanchor(to: tokenIndex)
    }

    func displayOffset(afterTokenIndex tokenIndex: Int) -> Int {
        let clamped = min(max(0, tokenIndex), tokens.count)
        guard clamped > 0 else { return 0 }
        return tokens[clamped - 1].displayEndOffset
    }

    private static func similarity(_ lhs: [String], _ rhs: [String]) -> Double {
        guard !lhs.isEmpty || !rhs.isEmpty else { return 1 }
        var previous = Array(0...rhs.count).map(Double.init)
        for (i, left) in lhs.enumerated() {
            var current = [Double(i + 1)]
            for (j, right) in rhs.enumerated() {
                let substitution = previous[j] + (left == right ? 0 : 1)
                let insertion = current[j] + 0.65
                let deletion = previous[j + 1] + 0.75
                current.append(min(substitution, insertion, deletion))
            }
            previous = current
        }
        let distance = previous[rhs.count]
        return max(0, 1 - distance / Double(max(lhs.count, rhs.count)))
    }
}
