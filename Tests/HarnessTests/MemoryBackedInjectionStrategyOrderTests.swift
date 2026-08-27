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

import Foundation
import VoccaCore
@testable import VoccaInject
import XCTest

/// **The read side of C8's strategy memory** (`memory-order/spec.md` T1–T10): the
/// ``InjectionStrategyOrder`` and ``InjectionAllowlist`` the ladder consults, projected from the
/// per-app strategies the memory holds.
///
/// The decisions being measured are Core's — `StrategyMemory.orderedRungs` and
/// `StrategyMemory.record` are pure and have their own decision-table suite
/// (`StrategyMemoryProjectionTests`, `StrategyMemoryRecordTests`). What is measured *here* is the
/// adapter that puts them on the ladder's path, and the three things only the adapter can get
/// wrong:
///
/// - **the two questions must give one answer.** `orderedRungs(for:)` decides whether to *offer*
///   the accessibility rung and `contains(bundleID:)` decides whether the rung will *accept* the
///   application (`AccessibilityRungStrategy.swift:98`). If they disagree, promotion is
///   structurally dead: the projection offers AX, the rung declines it before any AX call, the
///   probe never happens, and nothing is ever learned. Both questions route through the same
///   projection here, which is why every promotion row below asserts both;
/// - **the candidate marker.** Core's fold demotes what was *attempted and lost*; a
///   non-allowlisted application that delivers by clipboard never attempts AX, so nothing in the
///   fold would ever make it a promotion candidate. Minting that marker — AX demoted with a
///   re-probe window — is the adapter's own decision, and T5/T6 are its whole justification;
/// - **the absent file.** An empty snapshot must project byte-for-byte what
///   ``DefaultInjectionStrategyOrder`` projects (T10), because that is what every user runs on
///   their first dictation and what the zero-network probe drives.
///
/// Time is injected everywhere it matters (``TestEpochClock``): the re-probe window is 604 800
/// seconds and no test waits for one.
final class MemoryBackedInjectionStrategyOrderTests: XCTestCase {

    // MARK: - Fixtures

    /// An application the seeded allowlist blesses — AX is offered on its first dictation.
    private static let allowlisted = "com.apple.Notes"
    /// An ordinary application in neither seed: not blessed, not known-hostile. The promotion
    /// story's subject.
    private static let unknown = "com.example.Editor"
    /// A seeded-hostile application.
    private static let hostile = "com.tinyspeck.slackmacgap"

    /// The memory under test, with every input a test can move: the seed, the loaded snapshot,
    /// the hostile set, the store and the clock.
    private func makeMemory(
        seed: Set<String> = SeededInjectionAllowlist.seedBundleIDs,
        strategies: [InjectionStrategy] = [],
        hostile: Set<String> = SeededHostileApps.hostileBundleIDs,
        store: any InjectionStrategyStore = EphemeralInjectionStrategyStore(),
        clock: TestEpochClock
    ) -> MemoryBackedInjectionStrategyOrder {
        MemoryBackedInjectionStrategyOrder(
            seed: FakeInjectionAllowlist(allowed: seed),
            strategies: strategies,
            hostileBundleIDs: hostile,
            store: store,
            now: clock.read)
    }

    /// The re-probe window, read from Core so this suite cannot drift from the constant.
    private var window: UInt64 { StrategyMemoryTargets.reprobeWindowSeconds }

    // MARK: - T1 · The learned strategy is tried first

    /// A pre-seeded demotion is what the next dictation reads: the failed rung is gone from the
    /// order, and the rung that works leads. The same application with no entry answers the
    /// unlearned order — so the difference is the memory, not the seed.
    func testLearnedStrategyIsTriedFirst() {
        let clock = TestEpochClock(1_000)
        let learned = InjectionStrategy(
            bundleID: Self.allowlisted,
            demotedRungs: [.accessibility],
            reprobeWindows: [.accessibility: 1_000 + window])

        let remembering = makeMemory(strategies: [learned], clock: clock)
        XCTAssertEqual(
            remembering.orderedRungs(for: Self.allowlisted),
            [.clipboardPaste, .keystrokeSynthesis],
            """
            A remembered demotion did not reach the order. This is the whole point of C8: the \
            application already failed the accessibility rung once, and re-trying it costs the \
            user that latency on every single dictation.
            """)

        let blank = makeMemory(clock: clock)
        XCTAssertEqual(
            blank.orderedRungs(for: Self.allowlisted),
            [.accessibility, .clipboardPaste, .keystrokeSynthesis],
            "Without a learned entry the allowlisted application must see the unlearned order.")
    }

    // MARK: - T2 · Demote on fail, through the real ladder

    /// The write side and the read side, joined by the real ``LadderInjector`` and the real
    /// decision: AX is offered, AX fails, clipboard delivers — and the *next* order excludes AX.
    ///
    /// Driven through the injector rather than by calling `record` directly, because the trace
    /// the fold demotes from (`InjectionResult.attempted`) is produced by the decision and has to
    /// survive the round trip intact (`InjectionLadderDecision.swift:142-151`).
    @MainActor
    func testDemoteOnFailThroughDecideOverTheMemoryOrder() async {
        let clock = TestEpochClock(500)
        let memory = makeMemory(clock: clock)
        let ladder = LadderInjector(
            strategies: [
                .accessibility: FakeInjectionStrategy(rung: .accessibility, outcome: .failed),
                .clipboardPaste: FakeInjectionStrategy(
                    rung: .clipboardPaste, outcome: .succeeded(verified: false)),
            ],
            order: memory,
            handoff: RecordingFailsafeHandoff(),
            clock: TestClock(),
            recorder: memory)

        let result = await ladder.inject(
            "hello",
            into: TargetContext(
                bundleID: Self.allowlisted, windowTitle: nil, isSecureInput: false))

        XCTAssertEqual(result.rung, .clipboardPaste)
        XCTAssertEqual(
            result.attempted, [.accessibility, .clipboardPaste],
            "The trace the demotion is derived from did not survive the ladder run.")
        XCTAssertEqual(
            memory.orderedRungs(for: Self.allowlisted),
            [.clipboardPaste, .keystrokeSynthesis],
            """
            The ladder ran, accessibility lost, clipboard won — and the next dictation would \
            still start at accessibility. Nothing was learned.
            """)
    }

    // MARK: - T3 · Re-probe rediscovery, on an injected clock

    /// A demoted rung is not written off permanently: before its window it stays out, at the
    /// window it is offered exactly once, and a verified win restores it outright — window
    /// dropped, not merely satisfied.
    @MainActor
    func testReprobeRediscoveryAfterWindowWithInjectedClock() async {
        let clock = TestEpochClock(0)
        let demoted = InjectionStrategy(
            bundleID: Self.allowlisted,
            demotedRungs: [.accessibility],
            reprobeWindows: [.accessibility: window])
        let memory = makeMemory(strategies: [demoted], clock: clock)

        clock.set(to: window - 1)
        XCTAssertEqual(
            memory.orderedRungs(for: Self.allowlisted), [.clipboardPaste, .keystrokeSynthesis],
            "A rung was re-probed one second early — the window is inclusive, not approximate.")

        clock.set(to: window)
        XCTAssertEqual(
            memory.orderedRungs(for: Self.allowlisted),
            [.accessibility, .clipboardPaste, .keystrokeSynthesis],
            "The re-probe window elapsed and the rung was never re-offered: an application whose "
            + "next update fixes its accessibility support is written off forever.")

        await memory.record(
            bundleID: Self.allowlisted,
            orderedRungs: [.accessibility, .clipboardPaste, .keystrokeSynthesis],
            result: InjectionResult(
                rung: .accessibility, attempted: [.accessibility], verified: true,
                elapsed: .zero))

        clock.set(to: window + 10)
        XCTAssertEqual(
            memory.orderedRungs(for: Self.allowlisted),
            [.accessibility, .clipboardPaste, .keystrokeSynthesis],
            "A re-probe that succeeded must restore the rung, not merely postpone its demotion.")
        XCTAssertEqual(
            memory.snapshot().first { $0.bundleID == Self.allowlisted }?.reprobeWindows, [:],
            "The restored rung kept its re-probe window — a stale window is a second re-probe "
            + "waiting to happen for a rung that is no longer demoted.")
    }

    /// The other half of R4: a re-probe that fails is re-demoted with a *fresh* window, so the
    /// application is retried on a decaying schedule rather than on every dictation.
    @MainActor
    func testReprobeFailureReDemotesWithFreshWindow() async {
        let clock = TestEpochClock(window)
        let demoted = InjectionStrategy(
            bundleID: Self.allowlisted,
            demotedRungs: [.accessibility],
            reprobeWindows: [.accessibility: window])
        let memory = makeMemory(strategies: [demoted], clock: clock)

        await memory.record(
            bundleID: Self.allowlisted,
            orderedRungs: [.accessibility, .clipboardPaste, .keystrokeSynthesis],
            result: InjectionResult(
                rung: .clipboardPaste, attempted: [.accessibility, .clipboardPaste],
                verified: false, elapsed: .zero))

        XCTAssertEqual(
            memory.orderedRungs(for: Self.allowlisted), [.clipboardPaste, .keystrokeSynthesis],
            "A failed re-probe left the rung offered — the application pays the failure again "
            + "on the very next dictation.")
        XCTAssertEqual(
            memory.snapshot().first { $0.bundleID == Self.allowlisted }?
                .reprobeWindows[.accessibility],
            window + window,
            "The re-probe window was not re-minted from the failure instant.")
    }

    // MARK: - T4 · The seeded hostile applications

    /// A known-hostile application starts on clipboard — and, unlike an application nobody has
    /// ever seen, it carries a re-probe window from launch, so its rediscovery is already
    /// scheduled. Both halves matter: the first is the user promise (no AX discovery cost on a
    /// first dictation into Slack), the second is what keeps the seed an *initial condition*
    /// rather than a permanent veto.
    func testSeededHostileExcludesAXOnFirstDictation() {
        let clock = TestEpochClock(0)
        let memory = makeMemory(clock: clock)

        for identifier in SeededHostileApps.hostileBundleIDs {
            XCTAssertEqual(
                memory.orderedRungs(for: identifier), [.clipboardPaste, .keystrokeSynthesis],
                "\(identifier) was offered the accessibility rung on its first dictation.")
            XCTAssertFalse(
                memory.contains(bundleID: identifier),
                "\(identifier) passed the accessibility rung's own gate on its first dictation.")
        }

        clock.set(to: window)
        for identifier in SeededHostileApps.hostileBundleIDs {
            XCTAssertEqual(
                memory.orderedRungs(for: identifier),
                [.accessibility, .clipboardPaste, .keystrokeSynthesis],
                """
                \(identifier)'s seeded demotion never expires. The seed is meant to be the \
                initial condition, not a life sentence — an app update that fixes accessibility \
                support has to be rediscoverable.
                """)
        }

        let neverSeen = makeMemory(clock: TestEpochClock(window))
        XCTAssertEqual(
            neverSeen.orderedRungs(for: Self.unknown), [.clipboardPaste, .keystrokeSynthesis],
            """
            An application nobody has ever dictated into was offered accessibility merely \
            because time passed. The seeded window is minted by the seed; an unseen app has no \
            window at all.
            """)
    }

    // MARK: - T5 · Learned promotion, and the gate that must agree with it

    /// The load-bearing flow (R6). An application in neither seed: clipboard delivers, which
    /// makes it a promotion *candidate*; the window elapses, so AX is probed — and the rung's own
    /// gate must agree, or the probe never runs; a read-back-verified win promotes it for good.
    @MainActor
    func testLearnedPromotionReachesAXAndItsGate() async {
        let clock = TestEpochClock(0)
        let memory = makeMemory(clock: clock)

        XCTAssertEqual(
            memory.orderedRungs(for: Self.unknown), [.clipboardPaste, .keystrokeSynthesis])
        XCTAssertFalse(memory.contains(bundleID: Self.unknown))

        // A plain clipboard delivery — the only outcome an unlisted app can produce today.
        await memory.record(
            bundleID: Self.unknown,
            orderedRungs: [.clipboardPaste, .keystrokeSynthesis],
            result: InjectionResult(
                rung: .clipboardPaste, attempted: [.clipboardPaste], verified: false,
                elapsed: .zero))

        XCTAssertEqual(
            memory.orderedRungs(for: Self.unknown), [.clipboardPaste, .keystrokeSynthesis],
            "A clipboard delivery must not promote anything by itself — promotion is earned by a "
            + "verified accessibility win, never by the absence of one.")

        clock.set(to: window)
        XCTAssertEqual(
            memory.orderedRungs(for: Self.unknown),
            [.accessibility, .clipboardPaste, .keystrokeSynthesis],
            """
            The promotion probe was never scheduled. Without the candidate marker a clipboard \
            success writes nothing that can ever expire, so no application outside the three \
            seeded ones can ever reach the accessibility rung — and the seed's own comment \
            promises they reach it "only through C8's learned memory".
            """)
        XCTAssertTrue(
            memory.contains(bundleID: Self.unknown),
            """
            The order offers the accessibility rung and the rung's own gate declines it. This is \
            the promotion deadlock: `AccessibilityRungStrategy` returns `.failed` before making \
            one AX call, so the probe the projection just scheduled cannot happen, and the \
            failure is then recorded as the rung losing.
            """)

        await memory.record(
            bundleID: Self.unknown,
            orderedRungs: [.accessibility, .clipboardPaste, .keystrokeSynthesis],
            result: InjectionResult(
                rung: .accessibility, attempted: [.accessibility], verified: true, elapsed: .zero))

        clock.set(to: window * 3)
        XCTAssertEqual(
            memory.orderedRungs(for: Self.unknown),
            [.accessibility, .clipboardPaste, .keystrokeSynthesis],
            "A verified accessibility win did not promote the application permanently.")
        XCTAssertTrue(
            memory.contains(bundleID: Self.unknown),
            "The promoted application does not pass the accessibility rung's own gate.")
        XCTAssertEqual(
            memory.snapshot().first { $0.bundleID == Self.unknown }?.learnedAllowlist, true,
            "The promotion was not recorded as learned — it would not survive a relaunch.")
    }

    // MARK: - T6 · A failed promotion probe is not a promotion

    /// The bound on X1: a candidate whose one probe fails is re-demoted with a fresh window and
    /// is *not* on the learned allowlist. Promotion is one-shot and verification-gated, so an
    /// application that lies about AX insertion cannot talk its way onto the list.
    @MainActor
    func testPromotionProbeFailureReDemotesTheCandidate() async {
        let clock = TestEpochClock(0)
        let memory = makeMemory(clock: clock)

        await memory.record(
            bundleID: Self.unknown,
            orderedRungs: [.clipboardPaste, .keystrokeSynthesis],
            result: InjectionResult(
                rung: .clipboardPaste, attempted: [.clipboardPaste], verified: false,
                elapsed: .zero))
        clock.set(to: window)
        XCTAssertTrue(memory.contains(bundleID: Self.unknown), "Precondition: the probe is due.")

        await memory.record(
            bundleID: Self.unknown,
            orderedRungs: [.accessibility, .clipboardPaste, .keystrokeSynthesis],
            result: InjectionResult(
                rung: .clipboardPaste, attempted: [.accessibility, .clipboardPaste],
                verified: false, elapsed: .zero))

        XCTAssertFalse(
            memory.contains(bundleID: Self.unknown),
            "A failed probe promoted the application anyway.")
        XCTAssertEqual(
            memory.orderedRungs(for: Self.unknown), [.clipboardPaste, .keystrokeSynthesis])
        XCTAssertEqual(
            memory.snapshot().first { $0.bundleID == Self.unknown }?.learnedAllowlist, false,
            "The failed probe was recorded as a promotion.")
        XCTAssertEqual(
            memory.snapshot().first { $0.bundleID == Self.unknown }?
                .reprobeWindows[.accessibility],
            window + window,
            "The failed probe did not re-mint the window from the failure instant.")
    }

    /// An *unverified* accessibility "success" — the silent lie — is not a promotion either. The
    /// decision already treats it as a failure and falls through
    /// (`InjectionLadderDecision.swift:130-136`), so it never hands the memory a result shaped
    /// like this one; the row is here because the memory must not become the place the lie is
    /// believed if some future caller does.
    @MainActor
    func testUnverifiedAccessibilitySuccessNeverPromotes() async {
        let clock = TestEpochClock(0)
        let memory = makeMemory(clock: clock)

        await memory.record(
            bundleID: Self.unknown,
            orderedRungs: [.accessibility, .clipboardPaste, .keystrokeSynthesis],
            result: InjectionResult(
                rung: .accessibility, attempted: [.accessibility], verified: false,
                elapsed: .zero))

        XCTAssertNotEqual(
            memory.snapshot().first { $0.bundleID == Self.unknown }?.learnedAllowlist, true,
            "An unverified accessibility claim promoted the application — the silent lie was "
            + "believed by the memory after the decision had already caught it.")
        XCTAssertFalse(
            memory.contains(bundleID: Self.unknown),
            "The unverified claim let the application through the accessibility rung's gate.")
        XCTAssertNil(
            memory.snapshot().first { $0.bundleID == Self.unknown },
            """
            The claim was recorded as something. It taught the memory nothing — no rung was \
            demoted, nothing was promoted — and a row that records nothing still costs one of \
            the 512 applications the store will ever remember.
            """)
    }

    // MARK: - T7 · The failsafe is not a rung to learn

    /// Across the closed space of states this adapter can be in, `.widgetFailsafe` never appears
    /// in a projection. It is the decision's terminal, and an order that offered it would hand
    /// the decision a rung that cannot exist in its strategy map
    /// (`InjectionStrategyOrder.swift:26-33`).
    func testWidgetFailsafeNeverAppearsInAnyProjection() {
        let states: [InjectionStrategy] = [
            InjectionStrategy(bundleID: Self.unknown),
            InjectionStrategy(bundleID: Self.unknown, demotedRungs: [.accessibility]),
            InjectionStrategy(
                bundleID: Self.unknown, demotedRungs: [.accessibility],
                reprobeWindows: [.accessibility: 10]),
            InjectionStrategy(bundleID: Self.unknown, learnedAllowlist: true),
            InjectionStrategy(
                bundleID: Self.unknown,
                demotedRungs: [.accessibility, .keystrokeSynthesis, .widgetFailsafe],
                reprobeWindows: [.accessibility: 10, .widgetFailsafe: 10]),
        ]

        for state in states {
            for second in [UInt64(0), 5, 10, window, window * 2] {
                let clock = TestEpochClock(second)
                for identifier in [Self.unknown, Self.allowlisted, Self.hostile] {
                    var scoped = state
                    scoped.bundleID = identifier
                    let memory = makeMemory(strategies: [scoped], clock: clock)
                    XCTAssertFalse(
                        memory.orderedRungs(for: identifier).contains(.widgetFailsafe),
                        "The failsafe was offered as a rung for \(identifier) at t=\(second).")
                }
                XCTAssertFalse(
                    makeMemory(strategies: [state], clock: clock)
                        .orderedRungs(for: nil).contains(.widgetFailsafe))
            }
        }
    }

    // MARK: - T8 · Clipboard is never demoted, so the order is never empty

    /// The workhorse is exempt (`ROADMAP.md:47`), which is what makes the never-empty guarantee
    /// structural rather than incidental: demotion removes rungs from the attempt list, and if
    /// the last one could go, a learned application would fall straight to the failsafe forever.
    func testClipboardPasteIsNeverDemotedAndTheProjectionIsNeverEmpty() {
        let everythingDemoted = InjectionStrategy(
            bundleID: Self.unknown,
            demotedRungs: [.accessibility, .clipboardPaste, .keystrokeSynthesis],
            reprobeWindows: [
                .accessibility: .max, .clipboardPaste: .max, .keystrokeSynthesis: .max,
            ])

        for second in [UInt64(0), window, UInt64.max - 1] {
            let memory = makeMemory(
                strategies: [everythingDemoted], clock: TestEpochClock(second))
            let projection = memory.orderedRungs(for: Self.unknown)
            XCTAssertTrue(
                projection.contains(.clipboardPaste),
                "The clipboard rung was demoted out of the order at t=\(second) — the ladder has "
                + "no workhorse left and every dictation into this app reaches the failsafe.")
            XCTAssertFalse(projection.isEmpty)
        }
    }

    // MARK: - T9 · A learned entry beats the seed

    /// The merge's learned-wins clause: a hostile application that later earned a verified AX win
    /// is not re-demoted at the next launch by the seed that once described it.
    func testLearnedEntryOverridesTheHostileSeed() {
        let promoted = InjectionStrategy(bundleID: Self.hostile, learnedAllowlist: true)
        let memory = makeMemory(strategies: [promoted], clock: TestEpochClock(0))

        XCTAssertEqual(
            memory.orderedRungs(for: Self.hostile),
            [.accessibility, .clipboardPaste, .keystrokeSynthesis],
            """
            The hostile seed re-demoted an application that had already earned its promotion. \
            The seed is the initial condition for an application nothing is known about; a \
            learned entry is knowledge, and knowledge wins.
            """)
        XCTAssertTrue(memory.contains(bundleID: Self.hostile))
    }

    // MARK: - T10 · An absent file is the C4 ladder, byte for byte

    /// What every user runs on their first dictation, and what the zero-network probe drives: an
    /// empty snapshot must project exactly what ``DefaultInjectionStrategyOrder`` projects, for
    /// every shape of bundle identifier — otherwise C8 changed the shipped ladder for people who
    /// have learned nothing yet.
    func testAbsentFileIsSilentAndDefaultsToTheC4Ordering() {
        let seed = SeededInjectionAllowlist()
        let c4 = DefaultInjectionStrategyOrder(allowlist: seed)
        let memory = makeMemory(clock: TestEpochClock(0))

        let identifiers: [String?] = [
            nil, Self.allowlisted, "com.apple.mail", "com.apple.TextEdit", Self.unknown,
            Self.hostile, "com.google.Chrome", "",
        ]
        for identifier in identifiers {
            XCTAssertEqual(
                memory.orderedRungs(for: identifier), c4.orderedRungs(for: identifier),
                """
                The memory-backed order diverges from the shipped C4 order for \
                \(identifier ?? "nil") with nothing learned. An empty strategies file is what a \
                fresh install has, so this is the ladder every new user runs.
                """)
        }
        for identifier in identifiers.compactMap({ $0 }) {
            XCTAssertEqual(
                memory.contains(bundleID: identifier), seed.contains(bundleID: identifier),
                "The accessibility gate diverges from the seeded allowlist for \(identifier) "
                + "with nothing learned.")
        }
    }
}
