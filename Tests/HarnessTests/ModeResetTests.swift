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

/// **R2b, the roadmap's mode-transition reset acceptance** (`CAPABILITY_ROADMAP.md:319`): "A
/// mode-transition test asserts state is fully reset between modes with no carryover of buffer,
/// transcript, or target."
///
/// The reset is pinned by the epoch-minted ``ModeSession`` handoff (D5): the machine owns the
/// mode-scoped session record — the three slots `buffer`, `transcript`, `target` — minted fresh
/// at every `.start`, filled by the owner through the `fill*` methods, handed out inside
/// `.stopped`, and cleared with `currentMode` at the stop. There is exactly one `session` field,
/// replaced at every start: **carryover is unrepresentable inside the machine**.
///
/// Every test here drives full cycles — slots filled, records asserted — in both directions and
/// in the same-mode restart, because a reset assertion that never filled the three slots could
/// pass by construction (asserting only `currentMode` without a record behind it proves
/// nothing).
final class ModeResetTests: XCTestCase {

    /// A buffer the fills carry — the interchange format, content irrelevant to the machine.
    private static let someBuffer = AudioBuffer(samples: [0.25, 0.5, 0.75], sampleRate: 16_000)

    /// A dictate-cycle target — filled only in a dictate cycle, never in a converse one.
    private static let someTarget = TargetContext(
        bundleID: "com.example", windowTitle: "Doc", isSecureInput: false)

    /// Dictate → converse: the full dictate cycle fills all three slots, the stopped record
    /// carries all three, and the converse start mints a fresh record with **all three slots
    /// nil** — the dictate values are reachable nowhere on the machine.
    func testModeTransitionResetsBufferTranscriptAndTarget() {
        let machine = SessionModeMachine<AudioBuffer>()

        XCTAssertEqual(machine.observe(.start(.dictation)), .started(.dictation, epoch: 1))
        machine.fill(buffer: Self.someBuffer)
        machine.fill(transcript: "dictated text")
        machine.fill(target: Self.someTarget)
        guard case .stopped(.dictation, 1, let dictateRecord) = machine.observe(.stop) else {
            XCTFail("expected the dictate stop to carry its record")
            return
        }
        XCTAssertEqual(dictateRecord.buffer, Self.someBuffer)
        XCTAssertEqual(dictateRecord.transcript, "dictated text")
        XCTAssertEqual(dictateRecord.target, Self.someTarget)
        XCTAssertNil(machine.currentMode)
        XCTAssertNil(machine.session)

        XCTAssertEqual(machine.observe(.start(.conversing)), .started(.conversing, epoch: 2))
        XCTAssertEqual(machine.currentMode, .conversing)
        guard let fresh = machine.session else {
            XCTFail("a start mints a session")
            return
        }
        XCTAssertEqual(fresh.mode, .conversing)
        XCTAssertEqual(fresh.epoch, 2)
        XCTAssertNil(fresh.buffer, "no buffer carries over into the converse session")
        XCTAssertNil(fresh.transcript, "no transcript carries over into the converse session")
        XCTAssertNil(fresh.target, "no target carries over into the converse session")
    }

    /// Converse → dictate: the converse cycle fills buffer and transcript — and **never fills
    /// the target slot** (never a target in converse, `PRODUCT_SPEC.md:200`, asserted as part of
    /// the cycle: the stopped converse record's `target == nil`) — and the dictate start mints a
    /// fresh record with every slot nil.
    func testConverseToDictateCarriesNothing() {
        let machine = SessionModeMachine<AudioBuffer>()

        XCTAssertEqual(machine.observe(.start(.conversing)), .started(.conversing, epoch: 1))
        machine.fill(buffer: Self.someBuffer)
        machine.fill(transcript: "a spoken reply")
        guard case .stopped(.conversing, 1, let converseRecord) = machine.observe(.stop) else {
            XCTFail("expected the converse stop to carry its record")
            return
        }
        XCTAssertEqual(converseRecord.buffer, Self.someBuffer)
        XCTAssertEqual(converseRecord.transcript, "a spoken reply")
        XCTAssertNil(
            converseRecord.target,
            "a converse cycle never fills the target slot — never a target in converse (PRODUCT_SPEC.md:200)")

        XCTAssertEqual(machine.observe(.start(.dictation)), .started(.dictation, epoch: 2))
        XCTAssertEqual(machine.currentMode, .dictation)
        guard let fresh = machine.session else {
            XCTFail("a start mints a session")
            return
        }
        XCTAssertEqual(fresh.epoch, 2)
        XCTAssertNil(fresh.buffer)
        XCTAssertNil(fresh.transcript)
        XCTAssertNil(fresh.target)
    }

    /// A same-mode restart is a transition too (R1's reset wording holds for **any** start, not
    /// just a mode change): a fresh record and a fresh epoch.
    func testSameModeRestartIsAlsoATransition() {
        let machine = SessionModeMachine<AudioBuffer>()

        XCTAssertEqual(machine.observe(.start(.dictation)), .started(.dictation, epoch: 1))
        machine.fill(buffer: Self.someBuffer)
        machine.fill(transcript: "first cycle")
        _ = machine.observe(.stop)

        XCTAssertEqual(machine.observe(.start(.dictation)), .started(.dictation, epoch: 2))
        XCTAssertEqual(machine.currentMode, .dictation)
        XCTAssertEqual(machine.epoch, 2)
        XCTAssertEqual(machine.session?.epoch, 2)
        XCTAssertNil(machine.session?.buffer)
        XCTAssertNil(machine.session?.transcript)
        XCTAssertNil(machine.session?.target)
    }

    /// The epoch distinguishes the activations: the second cycle's record is epoch-2-minted and
    /// the first cycle's values are gone — two consecutive cycles never share a record.
    func testTwoConsecutiveCyclesDoNotShareRecords() {
        let machine = SessionModeMachine<AudioBuffer>()

        _ = machine.observe(.start(.dictation))
        machine.fill(transcript: "first")
        machine.fill(target: Self.someTarget)
        guard case .stopped(.dictation, 1, let first) = machine.observe(.stop) else {
            XCTFail("expected the first stop to carry its record")
            return
        }
        XCTAssertEqual(first.epoch, 1)
        XCTAssertEqual(first.transcript, "first")

        _ = machine.observe(.start(.dictation))
        machine.fill(transcript: "second")
        guard case .stopped(.dictation, 2, let second) = machine.observe(.stop) else {
            XCTFail("expected the second stop to carry its record")
            return
        }
        XCTAssertEqual(second.epoch, 2, "the epoch distinguishes the activations")
        XCTAssertEqual(second.transcript, "second")
        XCTAssertNil(second.buffer, "the first cycle's buffer is gone")
        XCTAssertNil(second.target, "the first cycle's target is gone")
    }
}