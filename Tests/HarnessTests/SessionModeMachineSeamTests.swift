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

/// The `SessionMode` state machine's seam contract and its committed transition table
/// (`docs/planning/dual-mode/mode-machine/plan_20260916.md` Phase 1, file 1).
///
/// The shape pins are the `ASREngineSeamTests`/`VoiceActivitySeamTests` discipline: the machine
/// is a concrete class, not a protocol-existential seam — a weakened or renamed type stops
/// compiling — and the input and effect enums are **closed** (exhaustive `switch` without a
/// `default:` below; a fifth case fails to compile — the `SessionEffect.swift:21-23`
/// discipline).
///
/// The transition-table tests are one per row of the committed table (the plan's Testing
/// strategy). The whole of the machine's behaviour is that table: mid-session switching is
/// impossible (no `active(m) → active(other)` row — it is `.refused`), one active capture at a
/// time (only `.idle` can produce `.started`), no implicit switching (no input can change the
/// mode except a start from idle), and no session outlives a system trigger (the `.system` row
/// covers every `SystemTrigger` case, swept by `CaseIterable`).
final class SessionModeMachineSeamTests: XCTestCase {

    /// A buffer the fills carry — the interchange format, content irrelevant to the machine.
    private static let someBuffer = AudioBuffer(samples: [0.25, 0.5, 0.75], sampleRate: 16_000)

    // MARK: - Shape pins

    /// The machine is a concrete class with the committed public surface: `currentMode`
    /// (`nil` = idle), the epoch counter, and the in-flight `session` record. The `require`
    /// function is the compile pin — a renamed or weakened type stops this from building.
    func testTheMachineIsAConcreteClassWithTheCommittedSurface() {
        func requireMachine(_ machine: SessionModeMachine<AudioBuffer>)
            -> SessionModeMachine<AudioBuffer>
        {
            machine
        }

        let machine = requireMachine(SessionModeMachine())
        XCTAssertNil(machine.currentMode, "a fresh machine is idle")
        XCTAssertEqual(machine.epoch, 0, "the epoch starts at zero")
        XCTAssertNil(machine.session, "no session exists before the first start")
    }

    /// ``SessionModeIntent`` has **exactly** `.start`, `.stop`, `.system` — the exhaustive
    /// switch without a `default:` is the compile pin: a fourth case stops this test (and every
    /// caller's switch) from building.
    func testSessionModeIntentIsExactlyStartStopAndSystem() {
        func describe(_ intent: SessionModeIntent) -> Int {
            switch intent {
            case .start(let mode):
                return mode == .dictation ? 0 : 1
            case .stop:
                return 2
            case .system:
                return 3
            }
        }

        XCTAssertEqual(describe(.start(.dictation)), 0)
        XCTAssertEqual(describe(.start(.conversing)), 1)
        XCTAssertEqual(describe(.stop), 2)
        XCTAssertEqual(describe(.system(.willSleep)), 3)
        XCTAssertEqual(describe(.system(.secureInputEnabled)), 3)
    }

    /// ``SessionModeEffect`` has **exactly** `.started`, `.sessionControl`, `.refused`,
    /// `.stopped`, `.unchanged` — the same closed-enum pin, over the effect vocabulary.
    func testSessionModeEffectIsExactlyTheFiveCommittedCases() {
        func describe(_ effect: SessionModeEffect<AudioBuffer>) -> Int {
            switch effect {
            case .started:
                return 0
            case .sessionControl:
                return 1
            case .refused:
                return 2
            case .stopped:
                return 3
            case .unchanged:
                return 4
            }
        }

        XCTAssertEqual(describe(.started(.dictation, epoch: 1)), 0)
        XCTAssertEqual(describe(.sessionControl(.dictation)), 1)
        XCTAssertEqual(describe(.refused), 2)
        XCTAssertEqual(
            describe(.stopped(.dictation, epoch: 1, session: ModeSession(mode: .dictation, epoch: 1))),
            3)
        XCTAssertEqual(describe(.unchanged), 4)
    }

    /// ``ModeSession`` has **exactly** the members `mode`, `epoch`, `buffer`, `transcript`,
    /// `target` — the tuple bind below is the compile pin: a sixth member (or a changed type)
    /// stops the extractor from building, and no member of any other type can appear.
    func testModeSessionHasExactlyTheFiveCommittedMembers() {
        func extract(
            from session: ModeSession<AudioBuffer>
        ) -> (mode: SessionMode, epoch: UInt64, buffer: AudioBuffer?, transcript: String?,
            target: TargetContext?)
        {
            (session.mode, session.epoch, session.buffer, session.transcript, session.target)
        }

        let session = ModeSession<AudioBuffer>(mode: .conversing, epoch: 7)
        let members = extract(from: session)
        XCTAssertEqual(members.mode, .conversing)
        XCTAssertEqual(members.epoch, 7)
        XCTAssertNil(members.buffer)
        XCTAssertNil(members.transcript)
        XCTAssertNil(members.target)
    }

    // MARK: - The committed transition table, one test per row

    /// Row 1: `idle` + `.start(.dictation)` → `.started(.dictation, epoch+1)` — the only route
    /// into `.active`, one capture at a time.
    func testStartFromIdleDictation() {
        let machine = SessionModeMachine<AudioBuffer>()

        XCTAssertEqual(machine.observe(.start(.dictation)), .started(.dictation, epoch: 1))
        XCTAssertEqual(machine.currentMode, .dictation)
        XCTAssertEqual(machine.epoch, 1)
        XCTAssertEqual(machine.session?.mode, .dictation)
        XCTAssertEqual(machine.session?.epoch, 1)
    }

    /// Row 2: `idle` + `.start(.conversing)` → `.started(.conversing, epoch+1)`.
    func testStartFromIdleConversing() {
        let machine = SessionModeMachine<AudioBuffer>()

        XCTAssertEqual(machine.observe(.start(.conversing)), .started(.conversing, epoch: 1))
        XCTAssertEqual(machine.currentMode, .conversing)
        XCTAssertEqual(machine.epoch, 1)
        XCTAssertEqual(machine.session?.mode, .conversing)
    }

    /// Row 3: `active(dictation)` + `.start(.dictation)` → `.sessionControl(.dictation)` — the
    /// session's own chord; the owner forwards it to the dictate wiring, where the rules decide
    /// (toggle-off / hold-release).
    func testSameModeChordIsSessionControlDictation() {
        let machine = SessionModeMachine<AudioBuffer>()
        _ = machine.observe(.start(.dictation))

        XCTAssertEqual(machine.observe(.start(.dictation)), .sessionControl(.dictation))
        XCTAssertEqual(machine.currentMode, .dictation, "session control does not change the mode")
        XCTAssertEqual(machine.epoch, 1, "session control does not mint")
        XCTAssertNotNil(machine.session, "the session stays in flight")
    }

    /// Row 4: `active(conversing)` + `.start(.conversing)` → `.sessionControl(.conversing)` —
    /// the stop affordance's chord leg (R4).
    func testSameModeChordIsSessionControlConversing() {
        let machine = SessionModeMachine<AudioBuffer>()
        _ = machine.observe(.start(.conversing))

        XCTAssertEqual(machine.observe(.start(.conversing)), .sessionControl(.conversing))
        XCTAssertEqual(machine.currentMode, .conversing)
        XCTAssertEqual(machine.epoch, 1)
        XCTAssertNotNil(machine.session)
    }

    /// Row 5a: `active(m)` + `.start(other)` → `.refused` — the other-mode chord is a no-op,
    /// never a switch (R1, G2); nothing changes, not even the epoch.
    func testOtherModeChordIsRefusedWhileDictating() {
        let machine = SessionModeMachine<AudioBuffer>()
        _ = machine.observe(.start(.dictation))

        XCTAssertEqual(machine.observe(.start(.conversing)), .refused)
        XCTAssertEqual(machine.currentMode, .dictation, "a refusal is never a switch")
        XCTAssertEqual(machine.epoch, 1, "a refusal never mints")
        XCTAssertEqual(machine.session?.mode, .dictation, "the original session is untouched")
    }

    /// Row 5b: the converse mirror.
    func testOtherModeChordIsRefusedWhileConversing() {
        let machine = SessionModeMachine<AudioBuffer>()
        _ = machine.observe(.start(.conversing))

        XCTAssertEqual(machine.observe(.start(.dictation)), .refused)
        XCTAssertEqual(machine.currentMode, .conversing)
        XCTAssertEqual(machine.epoch, 1)
        XCTAssertEqual(machine.session?.mode, .conversing)
    }

    /// Row 6: `active(m)` + `.stop` → `.stopped(m, epoch, session)` — the stop affordance seam
    /// (R4/O5); the record travels out inside the effect.
    func testStopEndsTheActiveSession() {
        let machine = SessionModeMachine<AudioBuffer>()
        _ = machine.observe(.start(.dictation))
        machine.fill(buffer: Self.someBuffer)
        machine.fill(transcript: "dictated")

        let effect = machine.observe(.stop)
        guard case .stopped(let mode, let epoch, let session) = effect else {
            XCTFail("expected .stopped, got \(effect)")
            return
        }
        XCTAssertEqual(mode, .dictation)
        XCTAssertEqual(epoch, 1)
        XCTAssertEqual(session.mode, .dictation)
        XCTAssertEqual(session.epoch, 1)
        XCTAssertEqual(session.buffer, Self.someBuffer)
        XCTAssertEqual(session.transcript, "dictated")
        XCTAssertNil(machine.currentMode, "a stop returns to idle")
        XCTAssertNil(machine.session, "a stop clears the record")
    }

    /// Row 7: `idle` + `.stop` → `.unchanged` — nothing to stop; a stop is never queued and
    /// never errors (the B9 no-op posture).
    func testStopInIdleIsUnchanged() {
        let machine = SessionModeMachine<AudioBuffer>()

        XCTAssertEqual(machine.observe(.stop), .unchanged)
        XCTAssertNil(machine.currentMode)
        XCTAssertEqual(machine.epoch, 0)

        XCTAssertEqual(machine.observe(.stop), .unchanged, "a second stop lands in idle the same way")
    }

    /// Row 8: `active(m)` + `.system(t)`, every `t` → `.stopped(m, epoch, session)` — continuous
    /// listening never outlives the system triggers (R4). The `CaseIterable` sweep pins all five
    /// cases; a new `SystemTrigger` case fails this loop unless it is added here too.
    func testEverySystemTriggerEndsTheActiveSession() {
        for trigger in SystemTrigger.allCases {
            let machine = SessionModeMachine<AudioBuffer>()
            XCTAssertEqual(machine.observe(.start(.conversing)), .started(.conversing, epoch: 1))

            let effect = machine.observe(.system(trigger))
            guard case .stopped(let mode, let epoch, let session) = effect else {
                XCTFail("expected .stopped for \(trigger), got \(effect)")
                continue
            }
            XCTAssertEqual(mode, .conversing)
            XCTAssertEqual(epoch, 1)
            XCTAssertEqual(session.mode, .conversing)
            XCTAssertNil(machine.currentMode, "a system trigger returns to idle")
            XCTAssertNil(machine.session, "a system trigger clears the record")
        }
    }

    /// Row 9: `idle` + `.system(t)` → `.unchanged` — nothing to stop.
    func testSystemTriggerInIdleIsUnchanged() {
        let machine = SessionModeMachine<AudioBuffer>()

        for trigger in SystemTrigger.allCases {
            XCTAssertEqual(
                machine.observe(.system(trigger)), .unchanged,
                "\(trigger) in idle is a no-op")
        }
        XCTAssertNil(machine.currentMode)
        XCTAssertEqual(machine.epoch, 0)
    }

    /// The epoch increments **per start, not per refusal**: a `.refused` press must not mint
    /// (R1's "refused as a no-op" — total, not merely "no visible effect").
    func testEpochIncrementsPerStartNotPerRefusal() {
        let machine = SessionModeMachine<AudioBuffer>()

        XCTAssertEqual(machine.observe(.start(.dictation)), .started(.dictation, epoch: 1))
        XCTAssertEqual(machine.observe(.start(.conversing)), .refused)
        XCTAssertEqual(machine.observe(.start(.dictation)), .sessionControl(.dictation))
        XCTAssertEqual(
            machine.observe(.stop),
            .stopped(.dictation, epoch: 1, session: ModeSession(mode: .dictation, epoch: 1)))
        XCTAssertEqual(machine.epoch, 1, "neither the refusal nor the session control minted")

        XCTAssertEqual(machine.observe(.start(.conversing)), .started(.conversing, epoch: 2))
        XCTAssertEqual(machine.epoch, 2)
    }

    /// One active capture at a time, as a script: start dictate → start converse `.refused` →
    /// start dictate `.sessionControl` → stop → start converse `.started`. `.started` never
    /// follows `.started` without an intervening `.stopped`.
    func testOneActiveCaptureAtATime() {
        let machine = SessionModeMachine<AudioBuffer>()
        var effects: [SessionModeEffect<AudioBuffer>] = []
        effects.append(machine.observe(.start(.dictation)))
        effects.append(machine.observe(.start(.conversing)))
        effects.append(machine.observe(.start(.dictation)))
        effects.append(machine.observe(.stop))
        effects.append(machine.observe(.start(.conversing)))

        XCTAssertEqual(
            effects,
            [
                .started(.dictation, epoch: 1),
                .refused,
                .sessionControl(.dictation),
                .stopped(.dictation, epoch: 1, session: ModeSession(mode: .dictation, epoch: 1)),
                .started(.conversing, epoch: 2),
            ])

        var startedCount = 0
        var previous: SessionModeEffect<AudioBuffer>?
        for effect in effects {
            if case .started = effect {
                startedCount += 1
                switch previous {
                case nil, .stopped?:
                    break
                default:
                    XCTFail(
                        "a .started followed a non-.stopped effect: \(String(describing: previous))")
                    return
                }
            }
            previous = effect
        }
        XCTAssertEqual(startedCount, 2, "exactly two activations in the script")
    }

    /// The fill preconditions: a fill addresses the in-flight record, and **there is no record
    /// to address outside an activation** — the guarded facts the preconditions are written over
    /// (`currentMode != nil`).
    ///
    /// A `precondition` cannot be caught in-process (`AudioBuffer.swift:26-27`), so this test
    /// pins the facts the guard reads instead: a fresh machine and a stopped machine are both
    /// idle (`currentMode == nil`, `session == nil` — a fill would trap), and a refused press
    /// mints nothing — the refusal is not an activation, and a fill after it still addresses the
    /// *original* session.
    func testFillRequiresAnActiveSession() {
        let machine = SessionModeMachine<AudioBuffer>()

        XCTAssertNil(machine.currentMode, "a fresh machine is idle — fill would trap")
        XCTAssertNil(machine.session, "a fresh machine carries no record — fill would trap")

        _ = machine.observe(.start(.dictation))
        XCTAssertEqual(machine.observe(.stop), .stopped(.dictation, epoch: 1, session: ModeSession(mode: .dictation, epoch: 1)))
        XCTAssertNil(machine.currentMode, "a stopped machine is idle — fill would trap")
        XCTAssertNil(machine.session, "a stopped machine carries no record — fill would trap")

        _ = machine.observe(.start(.dictation))
        XCTAssertEqual(machine.observe(.start(.conversing)), .refused)
        XCTAssertEqual(machine.currentMode, .dictation)
        XCTAssertEqual(machine.epoch, 2, "the refusal did not mint — the epoch is the second dictate start's")
        XCTAssertEqual(machine.session?.mode, .dictation, "the refusal is not an activation")

        machine.fill(transcript: "dictated")
        XCTAssertEqual(
            machine.session?.transcript, "dictated",
            "a fill after a refusal still addresses the original session — the refusal minted no record of its own")
    }

    /// `.stopped` carries the record, and the machine retains nothing after the stop — the
    /// reset carrier at the machine's own boundary.
    func testStoppedCarriesTheRecordAndTheMachineRetainsNothing() {
        let machine = SessionModeMachine<AudioBuffer>()
        _ = machine.observe(.start(.dictation))
        machine.fill(buffer: Self.someBuffer)
        machine.fill(transcript: "hello")
        machine.fill(target: TargetContext(bundleID: "com.example", windowTitle: "Doc", isSecureInput: false))

        let effect = machine.observe(.stop)
        guard case .stopped(let mode, let epoch, let session) = effect else {
            XCTFail("expected .stopped, got \(effect)")
            return
        }
        XCTAssertEqual(mode, .dictation)
        XCTAssertEqual(epoch, 1)
        XCTAssertEqual(session.mode, .dictation)
        XCTAssertEqual(session.epoch, 1)
        XCTAssertEqual(session.buffer, Self.someBuffer)
        XCTAssertEqual(session.transcript, "hello")
        XCTAssertEqual(
            session.target,
            TargetContext(bundleID: "com.example", windowTitle: "Doc", isSecureInput: false))

        XCTAssertNil(machine.currentMode)
        XCTAssertNil(machine.session)
    }
}