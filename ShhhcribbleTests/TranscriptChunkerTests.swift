import XCTest
@testable import Shhhcribble

/// Pins the chunker's invariants. The one that matters above all others:
/// **no window may exceed the budget**, because a window that does lands on the
/// measured 36-second failure (728 words) that this whole feature exists to
/// avoid.
final class TranscriptChunkerTests: XCTestCase {

    private func words(_ n: Int) -> String {
        (0 ..< n).map { "word\($0)" }.joined(separator: " ")
    }

    /// A rendered two-party call, the shape `CallTranscriptMerger` produces.
    private func call(turns: Int, wordsPerTurn: Int) -> String {
        (0 ..< turns).map { i in
            "\(i.isMultiple(of: 2) ? "Me" : "Others"): \(words(wordsPerTurn))"
        }.joined(separator: "\n\n")
    }

    // MARK: - The budget invariant

    func testNoWindowEverExceedsTheBudget() {
        // Across shapes that each stress a different branch: tidy turns,
        // turns that don't divide evenly, one giant turn, and unpunctuated run-on.
        let corpora = [
            call(turns: 40, wordsPerTurn: 50),
            call(turns: 7, wordsPerTurn: 137),
            "Me: " + words(1500),
            words(2000),
            "Me: short.\n\nOthers: " + words(900) + "\n\nMe: also short.",
        ]
        for (i, text) in corpora.enumerated() {
            for (j, w) in TranscriptChunker.windows(of: text, maxWords: 400).enumerated() {
                XCTAssertLessThanOrEqual(
                    TranscriptChunker.wordCount(w), 400,
                    "corpus \(i) window \(j) is over budget — this is the 36-second failure")
            }
        }
    }

    func testShortTranscriptIsOneWindowUnchanged() {
        let text = call(turns: 3, wordsPerTurn: 20)
        let w = TranscriptChunker.windows(of: text)
        XCTAssertEqual(w.count, 1)
        XCTAssertEqual(w[0], text)
    }

    func testEmptyAndWhitespaceYieldNoWindows() {
        XCTAssertTrue(TranscriptChunker.windows(of: "").isEmpty)
        XCTAssertTrue(TranscriptChunker.windows(of: "   \n\n  \t ").isEmpty)
    }

    // MARK: - Content preservation

    /// Chunking must not lose or duplicate the speaker's words — a dropped turn
    /// is silent data loss in a meeting summary.
    func testEveryWordSurvivesExactlyOnce() {
        let text = call(turns: 25, wordsPerTurn: 40)
        let original = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let rejoined = TranscriptChunker.windows(of: text, maxWords: 400)
            .joined(separator: " ")
            .split(whereSeparator: \.isWhitespace).map(String.init)
        XCTAssertEqual(rejoined, original, "chunking altered the transcript")
    }

    /// Turn boundaries are preferred, so a window should not begin mid-turn
    /// while a clean break was available.
    func testPacksOnTurnBoundaries() {
        // 10 turns × 100 words; 400-word budget → 4 turns per window.
        let text = call(turns: 10, wordsPerTurn: 100)
        let w = TranscriptChunker.windows(of: text, maxWords: 400)
        XCTAssertGreaterThan(w.count, 1)
        for window in w {
            XCTAssertTrue(window.hasPrefix("Me:") || window.hasPrefix("Others:"),
                          "window starts mid-turn: \(window.prefix(40))")
        }
    }

    // MARK: - The measured constants

    /// These are the numbers the ceiling run produced. If someone raises them,
    /// this test is the prompt to re-measure rather than assume.
    func testConstantsStayBelowTheMeasuredCeiling() {
        // 624 words succeeded, 728 failed (macOS 26.6.2, 2026-10-20).
        XCTAssertLessThan(TranscriptChunker.maxWordsPerWindow, 624,
                          "window budget must stay under the measured ceiling")
        XCTAssertLessThan(TranscriptChunker.singlePassWordLimit, 624,
                          "single-pass limit must stay under the measured ceiling")
        // Chosen for the latency knee at 416, not the ceiling.
        XCTAssertLessThanOrEqual(TranscriptChunker.maxWordsPerWindow, 416,
                                 "window budget should sit at or below the latency knee")
    }

    /// An hour-long call is the case this exists for; it must window sanely
    /// rather than producing one monster or thousands of fragments.
    func testHourLongCallWindowsSensibly() {
        let text = call(turns: 180, wordsPerTurn: 50)  // ~9,000 words
        let w = TranscriptChunker.windows(of: text)
        XCTAssertGreaterThan(w.count, 15)
        XCTAssertLessThan(w.count, 40)
        for window in w {
            XCTAssertLessThanOrEqual(TranscriptChunker.wordCount(window),
                                     TranscriptChunker.maxWordsPerWindow)
        }
    }

    // MARK: - Degenerate input

    func testSingleUnpunctuatedRunOnIsStillSplit() {
        let w = TranscriptChunker.windows(of: words(1200), maxWords: 400)
        XCTAssertEqual(w.count, 3)
        for window in w {
            XCTAssertLessThanOrEqual(TranscriptChunker.wordCount(window), 400)
        }
    }

    func testPlainDictationWithNoBlankLinesStillChunks() {
        let text = (0 ..< 60).map { "This is sentence number \($0) in a long dictation." }
            .joined(separator: " ")
        for window in TranscriptChunker.windows(of: text, maxWords: 100) {
            XCTAssertLessThanOrEqual(TranscriptChunker.wordCount(window), 100)
        }
    }
}
