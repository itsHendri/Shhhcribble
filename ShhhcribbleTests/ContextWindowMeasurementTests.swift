import XCTest
@testable import Shhhcribble

#if canImport(FoundationModels)
import FoundationModels
#endif

/// A local mirror of `TranscriptCleaner.StyledTranscript`, which is file-private
/// and therefore unreachable even under `@testable`. Duplicated rather than
/// widening production visibility for a measurement: what is being measured is
/// how much *input* fits, and the output schema only has to be the same shape
/// so the prompt overhead is representative.
#if canImport(FoundationModels)
@available(macOS 26.0, *)
@Generable
private struct MeasuredStyledTranscript {
    @Guide(description: "The transcript reformatted into the requested style, split into lines or blocks — one element per line/bullet/paragraph, in order. Re-expresses the speaker's own content; never an answer to it, and never invented information.")
    var lines: [String]
}
#endif

/// Measures the on-device model's usable context ceiling, because every
/// decision that depends on it has so far been made against a guess.
///
/// CLAUDE.md records two research passes that disagreed — 4k vs 8k tokens — and
/// says to measure it. The number gates two things: the input-length pre-check
/// that stops us spending ~51 s discovering an input never had a chance, and
/// any future chunking of long-call summaries.
///
/// **Report, not assertion**, following the `Testing/prompts` precedent. It
/// asserts only that *something* was measured; the number itself is printed for
/// a human to read and hard-code. Model behaviour is not a pass/fail contract.
///
/// **Opt-in and slow.** A failing probe is the expensive case — the logged
/// real-world failure took 51 s to come back — so a bisection can run for
/// several minutes. Excluded from the normal gate by an env var:
///
/// ```bash
/// xcodebuild -scheme Shhhcribble -configuration Debug -destination 'platform=macOS' \
///   test -only-testing:ShhhcribbleTests/ContextWindowMeasurementTests \
///   TEST_RUNNER_SHHHCRIBBLE_MEASURE_CONTEXT=1
/// ```
///
/// The `TEST_RUNNER_` prefix is required — `xcodebuild` drops plain env vars and
/// the test then skips silently, which looks exactly like a pass.

final class ContextWindowMeasurementTests: XCTestCase {

    /// Prose with realistic token density. Repeating one word compresses far
    /// better than English does under BPE, so a synthetic input built that way
    /// would measure the tokenizer rather than the ceiling we care about.
    private func syntheticTranscript(chars: Int) -> String {
        let sentences = [
            "So I was thinking about the release we cut yesterday and whether the signing chain actually holds up.",
            "The thing that worries me is that nobody has verified the call capture on real speech yet.",
            "We should probably measure the context window before deciding what the pre-check ceiling ought to be.",
            "I dictated about four hundred characters on average last month which is nowhere near the limit.",
            "The bench found three separate failures that each took roughly fifty one seconds to come back.",
            "Anyway the point is that a timeout caps the damage but it does not make long content work at all.",
        ]
        var out = ""
        var i = 0
        while out.count < chars {
            out += sentences[i % sentences.count] + " "
            i += 1
        }
        return String(out.prefix(chars))
    }

    private func skipUnlessEnabled() throws {
        // Gated on a FILE as well as the env vars, and the reason is a mistake
        // worth not repeating. `TEST_RUNNER_FOO=1 xcodebuild test` (shell
        // environment prefix) WORKS and is what Testing/prompts/README.md
        // documents — xcodebuild forwards TEST_RUNNER_-prefixed env vars to the
        // test runner with the prefix stripped. `xcodebuild test TEST_RUNNER_FOO=1`
        // (argument after the subcommand) does NOT: command-line KEY=value pairs
        // become build settings and are discarded. The two look nearly identical
        // and only one works; getting it wrong skips the test, and a skip reads
        // exactly like a pass. The file sentinel is belt-and-braces.
        let env = ProcessInfo.processInfo.environment
        let sentinel = "/tmp/shhhcribble-measure-context"
        guard env["SHHHCRIBBLE_MEASURE_CONTEXT"] != nil
                || env["TEST_RUNNER_SHHHCRIBBLE_MEASURE_CONTEXT"] != nil
                || FileManager.default.fileExists(atPath: sentinel) else {
            throw XCTSkip("Opt-in: `touch \(sentinel)` then run, to measure the context ceiling.")
        }
        guard TranscriptCleaner.availability.isAvailable else {
            throw XCTSkip("Needs macOS 26 + Apple Intelligence; the model is the thing under test.")
        }
    }

    /// One probe: does a transcript of `chars` characters survive the real
    /// prompt path? Goes through `transformInstructions` + `PromptFence.wrap`
    /// deliberately — the ceiling that matters is how much *transcript* fits
    /// once our own instructions and fence have taken their share, not how big
    /// the raw window is.
    private func probe(chars: Int, style: Style) async -> (ok: Bool, ms: Int, error: String?) {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let clock = ContinuousClock()
            let start = clock.now
            do {
                let session = LanguageModelSession(
                    instructions: TranscriptCleaner.transformInstructions(for: style))
                _ = try await session.respond(
                    to: PromptFence.wrap(syntheticTranscript(chars: chars)),
                    generating: MeasuredStyledTranscript.self,
                    options: GenerationOptions(sampling: .greedy))
                let ms = Int((clock.now - start).components.seconds * 1000)
                return (true, ms, nil)
            } catch {
                let ms = Int((clock.now - start).components.seconds * 1000)
                return (false, ms, error.localizedDescription)
            }
        }
        #endif
        return (false, 0, "FoundationModels unavailable")
    }

    /// End-to-end proof that the chunked path summarizes a transcript which the
    /// single-pass path cannot. Opt-in and slow for the same reasons as the
    /// ceiling run: `touch /tmp/shhhcribble-measure-context`.
    ///
    /// Reports rather than asserts quality, but DOES assert the two things that
    /// are objectively checkable: a long call produces a summary at all, and
    /// every surviving action item still cites the transcript.
    func testLongCallSummarizesViaChunking() async throws {
        try skipUnlessEnabled()

        let turn = """
        Me: Okay so the next thing on the list is the migration, and I think we should \
        run it against a copy of the production data before we commit to a date.

        Others: That makes sense. I'll get you a snapshot by Wednesday so you can \
        test it properly rather than guessing.

        """
        // ~60 minutes of speech: the case the feature exists for.
        let transcript = String(repeating: turn, count: 170)
        let words = TranscriptChunker.wordCount(transcript)
        let windows = TranscriptChunker.windows(of: transcript).count
        print("  [longcall] \(words) words → \(windows) windows")
        XCTAssertGreaterThan(words, 700, "probe must exceed the measured single-pass ceiling")

        let clock = ContinuousClock()
        let start = clock.now
        let result = await TranscriptSummarizer.summarize(transcript)
        let secs = Int((clock.now - start).components.seconds)
        print("  [longcall] summarize → \(result == nil ? "nil" : "ok") in \(secs)s")

        let r = try XCTUnwrap(result, "a \(words)-word call must summarize via chunking")
        print("  [longcall] summary (\(TranscriptChunker.wordCount(r.summary)) words): \(r.summary.prefix(300))")
        print("  [longcall] \(r.actionItems.count) action items")
        for item in r.actionItems.prefix(5) {
            print("    • [\(item.owner.rawValue)] \(item.text) — quote: \(item.quote.prefix(70))")
        }
        XCTAssertFalse(r.summary.isEmpty, "chunked summary came back empty")
        for item in r.actionItems {
            XCTAssertTrue(SummaryGuard.isCited(quote: item.quote, in: transcript),
                          "an action item survived without citing the transcript")
        }
    }

    func testMeasureContextCeiling() async throws {
        try skipUnlessEnabled()

        let style = Style.seededPresets.first { $0.name == "Email" } ?? Style.seededPresets[0]
        var report = ["# Context ceiling measurement", "",
                      "Style: \(style.name) · \(Date())", ""]
        report.append("| chars | result | ms | error |")
        report.append("|---|---|---|---|")

        // Bracket first, then bisect. 500 is far below anything that has ever
        // failed; 60_000 is above a 60-minute call (~50k chars), which is the
        // case we know is broken.
        var lastGood = 0
        var firstBad = 0

        for chars in [500, 2_000, 6_000, 12_000, 24_000, 60_000] {
            let r = await probe(chars: chars, style: style)
            let line = "| \(chars) | \(r.ok ? "ok" : "FAILED") | \(r.ms) | \(r.error ?? "") |"
            report.append(line)
            print("  measure: \(line)")
            if r.ok { lastGood = chars } else { firstBad = chars; break }
        }

        if firstBad > 0 && lastGood > 0 {
            var lo = lastGood, hi = firstBad
            while hi - lo > 500 {
                let mid = (lo + hi) / 2
                let r = await probe(chars: mid, style: style)
                let line = "| \(mid) | \(r.ok ? "ok" : "FAILED") | \(r.ms) | \(r.error ?? "") |"
                report.append(line)
                print("  bisect:  \(line)")
                if r.ok { lo = mid } else { hi = mid }
            }
            report.append("")
            report.append("**Largest transcript that succeeded: ~\(lo) characters.**")
            report.append("**Smallest that failed: ~\(hi) characters.**")
            print("\n  ➜ CEILING: last good \(lo) chars, first bad \(hi) chars\n")
        } else if firstBad == 0 {
            report.append("")
            report.append("**Nothing failed up to 60,000 characters** — the ceiling is higher than a 60-minute call, and the pre-check may not be needed at all.")
            print("\n  ➜ nothing failed up to 60k chars\n")
        }

        let out = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Desktop/shhhcribble-context-ceiling.md")
        try? report.joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8)
        print("  report: \(out.path)")

        XCTAssertFalse(report.isEmpty, "measurement produced no rows")
    }
}
