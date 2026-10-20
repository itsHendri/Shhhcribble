import Foundation

/// Splits a transcript into windows the on-device model can actually summarize.
///
/// **Every constant here is measured, not guessed** — see the ceiling table in
/// CLAUDE.md, produced by `PromptBenchTests.testMeasureContextCeiling` on
/// macOS 26.6.2 (2026-10-20):
///
/// | words | result | ms |
/// |---|---|---|
/// | 416 | ok | 2,823 |
/// | 468 | ok | 6,517 |
/// | 624 | ok | 8,578 |
/// | 728 | **failed** | 36,047 |
///
/// Two facts drive the design. **The hard ceiling is between 624 and 728 words**,
/// and **latency triples between 416 and 624** — so the window size is chosen for
/// the latency knee, not the ceiling. That is counter-intuitive and worth
/// spelling out: *smaller windows finish a long call sooner*, because per-window
/// cost grows super-linearly while window count grows linearly. For a
/// 9,000-word hour-long call:
///
/// - 400-word windows → 23 windows × ~2.8 s ≈ **64 s**
/// - 624-word windows → 15 windows × ~8.6 s ≈ **129 s**
///
/// Twice as slow for fewer, bigger windows. Don't "optimise" by raising this.
enum TranscriptChunker {

    /// Words per window. Sits below the latency knee (416) with margin, and far
    /// below the 624-word ceiling so a window can't land on the 36-second
    /// failure even if the model's appetite shifts with an OS update.
    static let maxWordsPerWindow = 400

    /// Above this, `TranscriptSummarizer` takes the chunked path. Deliberately
    /// below the measured 624 ceiling: a single pass at 572–624 words costs
    /// 8.4–8.6 s against 2.8 s at 416, so chunking is *faster* well before it
    /// becomes necessary, and leaves headroom for a slower future model.
    static let singlePassWordLimit = 450

    /// Word count on the same definition the ceiling was measured with
    /// (`split(whereSeparator: \.isWhitespace)`), so the numbers above remain
    /// comparable. Don't swap in a different tokenisation without re-measuring.
    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    /// Split into windows of at most `maxWords`, preferring to break on turn
    /// boundaries.
    ///
    /// A merged call transcript is blank-line-separated speaker turns
    /// (`CallTranscriptMerger.render`), and splitting mid-turn would hand the
    /// model half a sentence and strand an action item's evidence across two
    /// windows — which `SummaryGuard.isCited` would then correctly reject.
    /// So blocks are packed greedily and only split internally when one block
    /// alone exceeds the window.
    static func windows(of text: String, maxWords: Int = maxWordsPerWindow) -> [String] {
        precondition(maxWords > 0, "maxWords must be positive")
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard wordCount(trimmed) > maxWords else { return [trimmed] }

        var windows: [String] = []
        var current: [String] = []
        var currentWords = 0

        for block in turnBlocks(trimmed) {
            let blockWords = wordCount(block)

            // One turn bigger than a whole window: flush, then split the turn
            // itself. Rare (a four-minute uninterrupted monologue) but it must
            // not silently produce an over-ceiling window.
            if blockWords > maxWords {
                if !current.isEmpty {
                    windows.append(current.joined(separator: "\n\n"))
                    current = []; currentWords = 0
                }
                windows.append(contentsOf: splitOversizedBlock(block, maxWords: maxWords))
                continue
            }

            if currentWords + blockWords > maxWords, !current.isEmpty {
                windows.append(current.joined(separator: "\n\n"))
                current = []; currentWords = 0
            }
            current.append(block)
            currentWords += blockWords
        }
        if !current.isEmpty { windows.append(current.joined(separator: "\n\n")) }
        return windows
    }

    /// Blank-line-separated blocks, each trimmed, empties dropped. Falls back to
    /// the whole text as one block when there are no blank lines (a plain
    /// dictation rather than a rendered call).
    private static func turnBlocks(_ text: String) -> [String] {
        let blocks = text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return blocks.isEmpty ? [text] : blocks
    }

    /// Split a single over-long block on sentence boundaries where possible,
    /// falling back to a hard word split so the result is always within budget.
    private static func splitOversizedBlock(_ block: String, maxWords: Int) -> [String] {
        var out: [String] = []
        var current: [String] = []
        var currentWords = 0

        for sentence in sentences(block) {
            let n = wordCount(sentence)
            if n > maxWords {
                if !current.isEmpty {
                    out.append(current.joined(separator: " ")); current = []; currentWords = 0
                }
                out.append(contentsOf: hardWordSplit(sentence, maxWords: maxWords))
                continue
            }
            if currentWords + n > maxWords, !current.isEmpty {
                out.append(current.joined(separator: " ")); current = []; currentWords = 0
            }
            current.append(sentence)
            currentWords += n
        }
        if !current.isEmpty { out.append(current.joined(separator: " ")) }
        return out
    }

    /// Sentence-ish split that keeps the terminator attached, so a window still
    /// reads as prose and a quote spanning it stays intact.
    private static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if ch == "." || ch == "!" || ch == "?" {
                let s = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !s.isEmpty { out.append(s) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { out.append(tail) }
        return out.isEmpty ? [text] : out
    }

    /// Last resort: a sentence longer than a whole window (unpunctuated speech).
    /// Splits on words so no window can exceed the budget.
    private static func hardWordSplit(_ text: String, maxWords: Int) -> [String] {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        return stride(from: 0, to: words.count, by: maxWords).map {
            words[$0 ..< min($0 + maxWords, words.count)].joined(separator: " ")
        }
    }
}
