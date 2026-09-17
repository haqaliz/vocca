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

/// The reply fixture suite's machinery: fixtures in, per-generator legs out — one harness, run
/// parameterized over every `ReplyGenerator` (`speech-seam`'s `SpeechFixtureSuite` shape).
///
/// Everything here runs headlessly: the fixtures are plain text with a hand-written expected
/// reply, and both shipped implementations (`EchoReplyGenerator`,
/// `AcknowledgmentReplyGenerator`) are real — no stub, no env gate.
struct ReplyFixtureCase: Sendable {
    /// The fixture's base name — `echo-short-phrase`, `ack-question`, …
    let name: String
    /// The input the generator is asked to reply to — the cleaned transcript text of a
    /// committed `.conversing` turn (the wiring runs ASR + per-mode cleanup first).
    let input: String
    /// The expected reply, written by hand — never read back from the implementation.
    let expected: String
}

/// One generator's legs on one fixture.
struct ReplyFixtureResult: Sendable {
    let name: String
    /// The reply the generator produced for the fixture's input.
    let reply: String
}

enum ReplyFixtureSuite {

    /// Runs one generator over the fixtures and records every leg the seam promises
    /// (`reply-seam` plan D3): the reply each fixture's input produces, as written.
    ///
    /// The body applies the cases and records; the assertions live in the tests, where the
    /// expected replies are written by hand rather than read back from the generator. The
    /// body takes the protocol type only, so a future real generator compiles against the
    /// same body with no knowledge of these implementations.
    static func evaluate(
        _ generator: any ReplyGenerator, cases: [ReplyFixtureCase]
    ) -> [ReplyFixtureResult] {
        cases.map {
            ReplyFixtureResult(name: $0.name, reply: generator.reply(to: $0.input))
        }
    }
}