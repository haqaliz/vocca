// Copyright 2026 The Vocca Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import VoccaCore
import XCTest

/// The reply seam: the `ReplyGenerator` protocol (`dual-mode` PRD R7) as code, with the
/// synchronous text-in/text-out contract, the determinism claim and the empty-input policy
/// pinned.
///
/// Where ``ASREngineSeamTests`` pinned the ASR seam's shape and behaviour, this suite pins the
/// reply seam's — against the seam itself and its two shipped implementations. Unlike the
/// synthesizers (whose real engines need models CI has not), **both implementations are
/// headless and real**: `EchoReplyGenerator` (the shipped default — your words back, verbatim,
/// the by-ear ASR check) and `AcknowledgmentReplyGenerator` (`"Vocca is listening."` for every
/// input — the mode's own honest state, nothing more). Everything here is a claim about the
/// seam as the `converse-wiring` aspect will find it:
///
/// - the seam is a `Sendable` protocol with exactly one requirement,
///   `func reply(to text: String) -> String` — synchronous, no actor hop at a decision point;
/// - the echo returns the input byte-for-byte, no normalization, no trimming — "verbatim" is
///   a contract, not a convenience;
/// - the acknowledgment answers the fixed copy for every input, including empty — the copy
///   asserted by exact equality, so a copy edit anywhere fails loudly;
/// - both implementations are deterministic: two calls with the same input return the same
///   reply;
/// - an empty reply is silence, never an error (the synthesizer's empty-text policy) — and the
///   seam's empty behavior is explicit per implementation so the wiring knows what it means;
/// - callers never branch on implementation: the seam is consumed as `any ReplyGenerator`
///   throughout, and the driver below proves the protocol is what a caller speaks.
final class ReplySeamTests: XCTestCase {

    /// The seam exists as a `Sendable` protocol with exactly one requirement, and both
    /// implementations exist as types named `EchoReplyGenerator` and
    /// `AcknowledgmentReplyGenerator` — the compile pin `ASREngineSeamTests` applies: if the
    /// protocol's shape is ever weakened or renamed, this stops compiling rather than
    /// coercing. The `requireSendable` pin makes the `Sendable` conformance a compile
    /// obligation — the house's aversion to `@unchecked Sendable` is structural here, not
    /// stylistic.
    func testTheSeamIsASendableProtocolWithOneReplyRequirement() {
        func requireGenerator(_ generator: any ReplyGenerator) -> any ReplyGenerator {
            generator
        }
        func requireSendable<T: Sendable>(_ value: T) -> T { value }

        let echo: any ReplyGenerator = requireSendable(
            requireGenerator(EchoReplyGenerator()))
        let acknowledgment: any ReplyGenerator = requireSendable(
            requireGenerator(AcknowledgmentReplyGenerator()))

        let echoReply: String = echo.reply(to: "hello vocca")
        let acknowledgmentReply: String = acknowledgment.reply(to: "What time is it?")
        XCTAssertEqual(echoReply, "hello vocca")
        XCTAssertEqual(acknowledgmentReply, "Vocca is listening.")
    }

    /// The echo's committed rows: the input returns verbatim — byte-for-byte, the cleanup
    /// polish included (this seam's input arrives already cleaned, and the echo rewrites
    /// nothing).
    func testEchoReplyGeneratorReturnsTheInputVerbatim() {
        func requireGenerator(_ generator: any ReplyGenerator) -> any ReplyGenerator {
            generator
        }
        let echo = requireGenerator(EchoReplyGenerator())

        XCTAssertEqual(echo.reply(to: "hello vocca"), "hello vocca")
        XCTAssertEqual(echo.reply(to: "What time is it?"), "What time is it?")
        XCTAssertEqual(
            echo.reply(to: "Set a reminder for nine am"), "Set a reminder for nine am")
    }

    /// The echo's whitespace row: `"  "` returns `"  "` — no trimming, no normalization. The
    /// generator never rewrites; "verbatim" is the whole contract.
    func testEchoReplyGeneratorReturnsWhitespaceVerbatim() {
        let echo = EchoReplyGenerator()

        XCTAssertEqual(echo.reply(to: "  "), "  ")
    }

    /// The echo's punctuation row: byte-for-byte, em-dash and all — `String` identity, no
    /// normalization. Pinned once so the behavior is explicit, not accidental.
    func testEchoReplyGeneratorReturnsPunctuationVerbatim() {
        let echo = EchoReplyGenerator()

        XCTAssertEqual(echo.reply(to: "It's — really?"), "It's — really?")
    }

    /// The echo is deterministic — the R7 "deterministic" claim pinned, not assumed: two calls
    /// with the same input return identical replies.
    func testEchoReplyGeneratorIsDeterministic() {
        let echo = EchoReplyGenerator()

        XCTAssertEqual(echo.reply(to: "hello vocca"), echo.reply(to: "hello vocca"))
    }

    /// The acknowledgment answers the fixed copy for every input — the committed rows and the
    /// exact-copy pin: the string is asserted by exact equality, so a copy edit anywhere fails
    /// this test loudly.
    func testAcknowledgmentReplyGeneratorAnswersTheFixedCopyForEveryInput() {
        func requireGenerator(_ generator: any ReplyGenerator) -> any ReplyGenerator {
            generator
        }
        let acknowledgment = requireGenerator(AcknowledgmentReplyGenerator())

        XCTAssertEqual(acknowledgment.reply(to: "hello vocca"), "Vocca is listening.")
        XCTAssertEqual(acknowledgment.reply(to: "What time is it?"), "Vocca is listening.")
        XCTAssertEqual(acknowledgment.reply(to: "  "), "Vocca is listening.")
    }

    /// The acknowledgment ignores the input's length and shape: a long multi-sentence
    /// utterance answers the same fixed copy — the machine is listening, nothing more.
    func testAcknowledgmentReplyGeneratorIsInputIndependent() {
        let acknowledgment = AcknowledgmentReplyGenerator()
        let longText =
            "The meeting is at three and I need to prepare the slides before then, "
            + "so please remind me an hour early, and also check whether the projector is booked."

        XCTAssertEqual(acknowledgment.reply(to: longText), "Vocca is listening.")
    }

    /// The acknowledgment is deterministic — two calls with the same input return the same
    /// reply (and the fixed copy, being constant, makes it so by construction).
    func testAcknowledgmentReplyGeneratorIsDeterministic() {
        let acknowledgment = AcknowledgmentReplyGenerator()

        XCTAssertEqual(
            acknowledgment.reply(to: "hello vocca"),
            acknowledgment.reply(to: "hello vocca"))
    }

    /// The empty-input pin: an echo of empty is empty, an ack of empty is the fixed string —
    /// so `converse-wiring` knows the seam. An empty reply renders silence (the synthesizer's
    /// empty-text policy): nothing to say is an answer, never an error.
    func testEmptyInputIsPinnedForBothImplementations() {
        func requireGenerator(_ generator: any ReplyGenerator) -> any ReplyGenerator {
            generator
        }
        let echo = requireGenerator(EchoReplyGenerator())
        let acknowledgment = requireGenerator(AcknowledgmentReplyGenerator())

        XCTAssertEqual(echo.reply(to: ""), "", "the echo of empty is empty")
        XCTAssertEqual(
            acknowledgment.reply(to: ""), "Vocca is listening.",
            "the ack of empty is the fixed string — an empty input is still an utterance")
    }

    /// Callers never branch on implementation: the driver below is written against the seam's
    /// existential alone — the shipped defaults are invisible to it — and the fixed double
    /// proves the protocol (not a concrete implementation) is what the caller speaks. A caller
    /// that names `EchoReplyGenerator` or `AcknowledgmentReplyGenerator` at a decision point
    /// would not satisfy this shape (the Phase-3 family lint confines those names to their
    /// files for the same reason).
    func testCallersDriveTheSeamThroughTheProtocolOnly() {
        struct FixedReplyGenerator: ReplyGenerator {
            func reply(to text: String) -> String { "fixed: \(text)" }
        }

        func drive(_ generator: any ReplyGenerator, inputs: [String]) -> [String] {
            inputs.map { generator.reply(to: $0) }
        }

        let generator: any ReplyGenerator = FixedReplyGenerator()
        XCTAssertEqual(
            drive(generator, inputs: ["a", "b"]), ["fixed: a", "fixed: b"],
            "the caller's contract is the protocol — both answers flow through the existential, "
                + "and the caller never names the implementation")
    }
}