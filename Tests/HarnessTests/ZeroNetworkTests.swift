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

import XCTest

/// Raised when the module coverage cross-check cannot be evaluated meaningfully.
private enum ZeroNetworkTestError: Error, CustomStringConvertible {
    case noModulesDiscovered(sourcesRoot: String)
    case everyModuleExcluded(candidates: [String], nonDrivable: [String])
    case postConditionNotParseable(String)
    case postConditionMissingField(key: String, present: [String])
    case postConditionHasARepeatedField(key: String)

    var description: String {
        switch self {
        case .postConditionNotParseable(let fragment):
            return """
                The session post-condition is not a sequence of `key=value` fields — could not read \
                '\(fragment)'. It is asserted whole by the invariant and read back field by field \
                by testTheAssertedSessionPostConditionStillDescribesACompleteSession; a shape \
                neither can parse would leave both checking nothing.
                """
        case .postConditionMissingField(let key, let present):
            return """
                The session post-condition no longer reports '\(key)', so the property that field \
                carries is no longer asserted at all. Present: \(present.joined(separator: ", ")).
                """
        case .postConditionHasARepeatedField(let key):
            return """
                The session post-condition reports '\(key)' twice. One of the two would be dropped \
                silently, and there is no telling which.
                """
        case .noModulesDiscovered(let root):
            return
                "No module directories were found under \(root) — the probe's coverage was not checked against anything"
        case .everyModuleExcluded(let candidates, let nonDrivable):
            return """
                Every module was subtracted from the coverage requirement, so the invariant would \
                have been asserted against nothing. Candidates: \
                \(candidates.joined(separator: ", ")). Non-drivable: \
                \(nonDrivable.joined(separator: ", ")).
                """
        }
    }
}

/// A module the coverage check is allowed not to require the probe to drive.
///
/// Every entry is checked structurally before it is honoured — see
/// `ZeroNetworkTests.justifiedExclusions()`. Adding a name here cannot silence a failure for a
/// module that actually ships.
private struct CoverageExclusion {
    let target: String
    /// Recorded so the next reader knows why this was ever acceptable. Not load-bearing on its
    /// own; the structural check is what enforces it.
    let reason: String
}

/// Vocca's headline promise is that audio and text never leave the machine. These two tests are
/// what make that claim auditable rather than marketing, and they are a permanent release
/// blocker: **if one of them ever fails, the product code is wrong, not the test.** Weakening
/// either assertion to restore a green build defeats the entire point of having them.
///
/// The pair is deliberately structured so that neither test can go green vacuously:
///
/// - ``testInterposerDetectsAnOutboundConnection`` is the **positive control**. It drives the
///   probe through code paths that deliberately open outbound TCP connections and asserts the
///   interposer saw each one, by name. If this fails, the interposer is blind, and the other
///   test's green means nothing.
/// - ``testDefaultConfigurationMakesZeroNetworkConnections`` is the **invariant**. It drives the
///   probe through Vocca's default configuration and asserts nothing was contacted.
///
/// Both run the *same* binary through the *same* instrumentation, differing only in which mode
/// the probe is asked to execute. That shared mechanism is what makes the positive control a
/// meaningful guarantee about the invariant rather than a separate, unrelated experiment.
final class ZeroNetworkTests: XCTestCase {

    /// **The session-lifecycle post-condition**: what the probe must report after driving one
    /// complete session through the real ``SessionMachine`` and ``SessionWatchdog``.
    ///
    /// Asserted whole, as one line, and read as an *effect* rather than as a reference — the same
    /// distinction ``reportedActivationPolicy`` exists for, applied to the module where the
    /// distinction now costs the most. `VoccaCore` appearing in the coverage list below proves only
    /// that a type from it was named; while it was a placeholder there was nothing more to prove,
    /// and there now is: a state machine, a watchdog, a decision function and a clock seam.
    ///
    /// Every field is a fact the probe can only produce by running that code. In order: the press
    /// opened a session and was swallowed rather than typed into the user's document; three watchdog
    /// wakes each polled the configured key and each left the session alone; the machine accumulated
    /// the clock's forward motion and did not think the ceiling was near; the release ended the
    /// session through the single custody funnel with the buffer *that capture produced*; and the
    /// microphone was opened once, closed once, and is closed now.
    ///
    /// This is deliberately **not** a golden string to be regenerated when it fails.
    /// ``testTheAssertedSessionPostConditionStillDescribesACompleteSession`` reads it back and
    /// refuses a version that no longer describes a session which captured audio, handed it to
    /// custody and released the microphone — so weakening the probe and pasting in whatever it now
    /// prints does not restore a green suite.
    ///
    /// **Where that claim stops, stated because a review measured it.** It holds against weakening
    /// the *drive*: reordering it, reporting a different value, or dropping a field are all killed
    /// here or by the guard-the-guard. It does not hold against replacing a reported expression with
    /// a **constant** — `let openingWasOwed = watchdog.hasPendingOpening` → `= true`, or
    /// `let microphoneOpensAfterThePress = microphone.opens` → `= 0` — because the assertion lives
    /// inside the process being observed and the same edit that lies can delete what would catch it.
    /// That is the probe pattern's standing cost rather than something these two fields introduced,
    /// and it is why they are *snapshots taken at a named moment* reported beside the effects they
    /// bracket: a constant that survives here still has to agree with `press=`, `opening=`,
    /// `mic.opens` and `mic.closes`, which are all derived from the run.
    /// **Accepted, not fixed, and recorded as accepted.**
    private static let expectedSessionLifecycle = [
        // The hotkey press *decided* on a session and did not open a microphone, because the
        // shipped timing opens it off the tap callback — `AVAudioEngine.start()` is 114 ms
        // (`CaptureStartTiming`). The focused application did not receive the press.
        "press=opening",
        "press.propagation=swallow",
        // Zero, and it is the whole of the phase-3 decision expressed as a post-condition: the
        // callback returned with the microphone still shut.
        "press.openedMicrophone=0",
        // The machine said an opening was owed before it was asked for one. Without this, a drive
        // that asked unconditionally would report the same `opening=started` against a machine that
        // had silently reverted to opening inline, which is the mutation this field exists to kill.
        "openingWasOwed=true",
        // ...and the owner's later turn is what actually started the session.
        "opening=started",
        // The watchdog's wakes ran, read the configured key code each time, and — the key being
        // held and the ceiling being 120 s away — ended nothing.
        "wakes=3",
        "wake.effects=unchanged,unchanged,unchanged",
        "wake.keyReads=3",
        "wake.keyCodesRead=49,49,49",
        // ...and read the chord each time too, which is the half added in `hotkey-source` phase 5.
        // Stop rule (f) asks whether the user is still holding *the binding*, and a binding is a key
        // and a chord: with only the key polled, a modifier release whose `.flagsChanged` never
        // arrived was invisible until the key itself came up. Three, not fewer, because the key was
        // down on every wake — the read is short-circuited on the wakes where it is not, and a count
        // below three here would mean either that the second read is not happening or that the key
        // was reported up.
        "wake.modifierReads=3",
        // The machine accumulated the clock's forward motion across those wakes: three steps of the
        // probe's own 100 ms. Zero here would mean the ceiling can never fire.
        "elapsed=300ms",
        "ceilingNear=false",
        // The owner's timer is armed while recording and stopped once the session ends. The
        // *cadence* is deliberately not reported — see the probe's `describe(_ schedule:)`.
        "scheduleWhileRecording=wake",
        // The release ended the session through the one custody funnel, with a retaining reason,
        // and the key-up was swallowed because Vocca had swallowed its press.
        "release=ended(completed(keyUp))",
        "release.propagation=swallow",
        // The buffer that reached custody is the one *this capture* produced — the probe's
        // microphone stamps each buffer with its close count, so a machine that substituted a fresh
        // empty buffer on the way to the outcome would report `audio.ordinal=0`.
        "audio.ordinal=1",
        "audio.frames=3",
        // The microphone ledger. "The session ended" is not "the microphone was released", and this
        // is the half that says the second thing.
        "mic.open=false",
        "mic.opens=1",
        "mic.closes=1",
        "mic.overlappingOpens=0",
        "mic.closesWithoutOpen=0",
        "state=idle",
        "schedule=stopped",
    ].joined(separator: " ")

    /// **The injection-lifecycle post-condition**: what the probe must report after driving the
    /// ladder — two complete runs through the real ``LadderInjector`` — and what
    /// ``testDefaultConfigurationMakesZeroNetworkConnections`` asserts wholesale.
    ///
    /// Asserted as an *effect* for the same reason the session post-condition is. `VoccaInject`
    /// appearing in the coverage list below proves only that a type from it was named; while it
    /// was a placeholder there was nothing more to prove, and there now is: a decision function,
    /// rung strategies, a strategy order and a failsafe handoff. Every field below is a fact the
    /// probe can only produce by running that code. In order: the first run injected into an
    /// ordinary focused (unallowlisted) application and stopped at the clipboard rung with the
    /// trace and no read-back; the second run's rungs all failed, the decision fell through to
    /// the failsafe, and the shared handoff ledger records exactly one held transcript — and
    /// none on the run that delivered — with the reason and the capture instant from the injected
    /// clock.
    ///
    /// This is deliberately **not** a golden string to be regenerated when it fails.
    /// ``testTheAssertedInjectionPostConditionStillDescribesADeliveryAndAHandoff`` reads it back
    /// and refuses a version that no longer describes a ladder that delivered once, held once,
    /// never lost a transcript, and moved its clock — so weakening the probe and pasting in
    /// whatever it now prints does not restore a green suite.
    private static let expectedInjectionLifecycle = [
        // Run 1: an ordinary focused, unallowlisted application — the default order the shipped
        // ladder actually runs, clipboard first. The clipboard rung delivers; the trace stops
        // there; there is no read-back (verified is clipboard's raw truth, false).
        "success.rung=clipboardPaste",
        "success.attempted=clipboardPaste",
        "success.verified=false",
        // One boundary crossing, at the probe's own 10 ms step.
        "success.elapsed=10ms",
        // Run 2: the same target, every rung forced to fail. The decision falls through to the
        // widget, and the full trace is carried for C8's strategy memory.
        "failsafe.rung=widgetFailsafe",
        "failsafe.attempted=clipboardPaste,keystrokeSynthesis",
        "failsafe.verified=false",
        // Two boundary crossings this time, and the full 100 ms budget is nowhere near spent.
        "failsafe.elapsed=20ms",
        // The shared handoff ledger: the run that delivered held nothing, the run that fell
        // through held exactly one — with reason .exhausted at the monotonic instant the
        // decision last read the clock.
        "handoff.holds=1",
        "handoff.reason=exhausted",
        "handoff.capturedAt=30ms",
    ].joined(separator: " ")

    /// **The full-cycle post-condition**: what the probe must report after driving one complete
    /// dictation cycle through the composed root — press → opening → microphone opens (the fake
    /// graph hands over its scripted frames) → release → `.ended` → the stub engine transcribes →
    /// the ladder delivers → the surfaces record — and what
    /// ``testDefaultConfigurationMakesZeroNetworkConnections`` asserts wholesale.
    ///
    /// Asserted as an *effect* for the same reason the other three post-conditions are.
    /// `VoccaAudio` and `VoccaASR` appearing in the coverage list below proves only that a type
    /// from each was named — which is exactly what their placeholder entries used to satisfy, and
    /// why the coverage guard could not tell a module that was *reached* from a module whose work
    /// was *run*. Every field below is a fact the probe can only produce by running the composed
    /// loop: the press was swallowed and the machine was recording immediately after it; the
    /// graph's ledger shows one open and one close; the hand-over carried the three scripted
    /// frames complete; the stub engine transcribed them exactly once into `"1 2 3"` (reported
    /// space-free, because the report grammar is space-separated `key=value` fields) with the
    /// completeness echo of `0`, attributed to the stub, not to a shipped engine; the shipped
    /// Parakeet manifest loaded; the same text reached the injector and the ladder stopped at the
    /// clipboard rung; and every surface that must stay quiet on the happy path — the failsafe
    /// panel, the handoff ledger, the download session and the toggle wiring's microphone —
    /// recorded nothing.
    ///
    /// This is deliberately **not** a golden string to be regenerated when it fails.
    /// ``testTheAssertedCyclePostConditionStillDescribesACompleteDictationCycle`` reads it back
    /// and refuses a version that no longer describes a cycle which started, captured, transcribed
    /// with the stub's attribution, delivered through a real rung, and never touched the failsafe,
    /// the handoff or the download session — so weakening the probe and pasting in whatever it now
    /// prints does not restore a green suite.
    private static let expectedCycleLifecycle = [
        // The press was swallowed — the focused application never saw the hotkey — and the
        // machine was recording the moment it returned: the owner's deferral had already opened
        // the microphone by then (the drive's deferral is synchronous).
        "press=swallow",
        "recording=1",
        // The graph ledger: opened once, closed once. "The session ended" is not "the microphone
        // was released", and these are the two halves.
        "mic.opens=1",
        "mic.stops=1",
        // The three scripted frames reached the engine, complete: the ring refused nothing, so
        // the hand-over's completeness link is the honest 0.
        "frames=3",
        "transcript=1-2-3",
        "transcript.missing=0",
        // The transcript's attribution is the stub's, not a shipped engine's — a composition that
        // quietly built the real engine would report the real id here, and would also be the
        // process that just downloaded a model. The stub transcribed exactly once.
        "engine=probe-stub-engine",
        "engine.transcribes=1",
        // The shipped manifest — real `VoccaASR` code, no model bytes — names the Parakeet
        // artifact the stub stands in for.
        "manifest.engine=parakeet-tdt-0.6b-v3",
        // The cleanup stage's attribution: the same text the engine produced reached the real
        // rules provider (empty dictionary — no rewrite of the digits) and the seam's machine
        // key is reported with it. `injected` below carries the cleaned text, terminal
        // punctuation included.
        "cleanup.engine=rules-cleanup",
        // The egress badge's fold: the resolved provider is rules (absent config — the default
        // path), so the widget carries no ☁︎ marker. `egress=none` is the byte-for-byte surface
        // the shipped rules path must show (`egress-badge`, `root-wiring` B1).
        "egress=none",
        // The cleaned text reached the injector — the digits untouched, the terminal period the
        // rules engine appends to any unpunctuated utterance included — and the ladder stopped
        // at the clipboard rung with the trace to match: a delivery, not a fall-through.
        "injected=1-2-3.",
        "rung=clipboardPaste",
        "attempted=clipboardPaste",
        // The happy path's quiet surfaces: the failsafe panel presented nothing, the handoff held
        // nothing, and no download session started.
        "failsafe=0",
        "holds=0",
        "download.starts=0",
        // The widget projection folded the delivery — the composed loop's surface, real
        // `VoccaUI` code — and the machine came to rest. The toggle wiring's microphone never
        // opened: only the active configuration may hold the input.
        "widget=delivered",
        "toggle.opens=0",
        "state=idle",
        // The latency ledger closed exactly one record over the cycle — the finalized-record
        // count as a structured token (`records=N`), so the "exactly one record" fact is
        // asserted in the same grammar as every other field, not inside the PROBE-LATENCY
        // payload, whose durations are measurements rather than constants.
        "records=1",
    ].joined(separator: " ")

    /// The only modules the probe is not required to drive.
    ///
    /// This list is deliberately *not* trusted on its own. `justifiedExclusions()` refuses any
    /// entry that the manifest says is part of something the package ships, so adding a real
    /// module's name here to make a coverage failure go away does not work — the test fails on
    /// the exclusion instead, and says why. That matters because silencing this check is the
    /// path of least resistance for anyone who just wants CI green, and this file's own header
    /// declares that forbidden.
    private static let candidateExclusions: [CoverageExclusion] = [
        CoverageExclusion(
            target: "VoccaNetworkProbe",
            reason: "The probe itself. Belongs to no product; built only because HarnessTests depends on it."),
        CoverageExclusion(
            target: "CVoccaNetworkInterposer",
            reason: "The dyld shim. Reachable only from the underscored _VoccaNetworkInterposerTestFixture product."),
    ]

    // MARK: - Test A: the positive control

    /// Proves the detection mechanism actually works, for both calls that matter.
    ///
    /// The probe binds a `SOCK_STREAM` listener on `127.0.0.1` port 0 (kernel-assigned) and
    /// connects to it. That is deterministic, needs no DNS, and works offline and in CI — the
    /// test never depends on the internet being reachable.
    ///
    /// It checks `connect(2)` **and** `connectx(2)` separately, and asserts on the name of the
    /// call observed rather than merely on a count. `connectx` is how `URLSession` and
    /// `Network.framework` actually reach the kernel, so it is the hook that carries almost all
    /// real-world egress; asserting only a non-zero count would let that hook be deleted with the
    /// suite still green, which is exactly the blindness this test exists to rule out.
    ///
    /// Loopback deliberately *counts* as a network connection here. Vocca's default configuration
    /// talks to nothing at all, including `localhost`: the opt-in local LLM (Ollama) that a user
    /// may later enable lives on loopback, and this test exists partly to catch it becoming
    /// reachable by default.
    func testInterposerDetectsAnOutboundConnection() throws {
        for (mode, expectedCall) in [
            (ProbeMode.deliberateConnection, "connect"),
            (ProbeMode.deliberateConnectx, "connectx"),
        ] {
            let observation = try runProbe(mode: mode)

            XCTAssertGreaterThanOrEqual(
                observation.networkConnectionCount, 1,
                """
                The probe deliberately opened one outbound TCP connection to a loopback listener \
                in mode '\(mode.rawValue)' and the interposer did not see it. The interposer is \
                blind, which means testDefaultConfigurationMakesZeroNetworkConnections cannot be \
                trusted either.
                \(observation.diagnosticSummary)
                """)

            XCTAssertTrue(
                observation.networkConnections.contains { $0.call == expectedCall },
                """
                The connection in mode '\(mode.rawValue)' was expected to be observed via \
                '\(expectedCall)', and was not. The interposer is missing that hook, so every \
                caller that uses it goes unseen — and for connectx that means URLSession and all \
                of Network.framework.
                \(observation.diagnosticSummary)
                """)
        }
    }

    // MARK: - Test B: the invariant

    /// Asserts Vocca's default configuration makes zero network calls.
    ///
    /// **This test is only as strong as the path it exercises**, which is the body of
    /// `VoccaNetworkProbe.exerciseDefaultConfiguration()`. Two mechanisms defend that from
    /// quietly decaying, and neither replaces reading the function itself:
    ///
    /// - The probe holds the process open for a settle window after the path returns, so
    ///   asynchronous work — which is nearly everything Vocca will do — gets to reach the network
    ///   before the observation ends.
    /// - The module cross-check below fails the suite when any new module is added without being
    ///   driven from that function — keyed on the package manifest and on the `Sources/` listing,
    ///   never on what the module is named.
    ///
    /// What neither can check is whether an *existing* module's new work is exercised. When a
    /// capability lands, extending that function is still a judgement call.
    func testDefaultConfigurationMakesZeroNetworkConnections() throws {
        let observation = try runProbe(mode: .defaultConfiguration)

        XCTAssertEqual(
            observation.networkConnectionCount, 0,
            """
            Vocca's default configuration must make zero network calls. The probe contacted:
            \(observation.networkConnectionDescriptions.joined(separator: "\n"))
            Fix the code. Do not weaken this test.
            \(observation.diagnosticSummary)
            """)

        XCTAssertEqual(
            observation.nameResolutionCount, 0,
            """
            Vocca's default configuration must resolve no hostnames. A DNS lookup leaves the \
            machine even when the connection that follows it never opens. The probe resolved:
            \(observation.nameResolutionDescriptions.joined(separator: "\n"))
            Fix the code. Do not weaken this test.
            \(observation.diagnosticSummary)
            """)

        // The bootstrap post-condition. Checked as an *effect* — the activation policy the probe
        // read back after calling AppBootstrap.configure(_:) — rather than as a module name in the
        // coverage list below.
        //
        // The distinction is load-bearing and was demonstrated, not assumed: deleting the
        // configure(_:) call from the probe while keeping `AppBootstrap.self` in its placeholder
        // list left this suite 2/2 green. Module granularity is enough for the four remaining
        // placeholder modules (VoccaHotkey's flag translation, VoccaText, VoccaSpeech and
        // VoccaUI's non-panel surface), which have no work the probe reaches yet — VoccaBootstrap
        // was the first module where the work *is* the deliverable, because it is the app's real
        // start-up path and the only code in this package that runs before the run loop.
        XCTAssertEqual(
            observation.reportedActivationPolicy, "accessory",
            """
            The probe did not observe Vocca's start-up leaving the application in the .accessory \
            activation policy (saw: \(observation.reportedActivationPolicy ?? "no report at all")).
            Either AppBootstrap.configure(_:) was not called on the default-configuration path, or \
            it no longer sets the policy. Both matter: the first means the app's real start-up code \
            is no longer covered by this invariant at all, and the second means Vocca takes focus \
            on launch and types into the wrong window.
            Do not fix this by removing the call — that is the change this assertion exists to \
            refuse.
            \(observation.diagnosticSummary)
            """)

        // The session-lifecycle post-condition. The second effect-not-reference check, and the one
        // that matters most now: `VoccaCore` stopped being a placeholder and became the state
        // machine that owns both of this project's invariants, and the coverage guard below is at
        // module granularity by construction — it can say the module was reached, never that its
        // work ran. Before this line, `SessionState.self` in the probe's list satisfied the guard
        // whether or not a single line of `VoccaCore` executed.
        //
        // Deleting the drive from the probe removes this line from its output entirely, so the
        // comparison fails against `nil` rather than quietly covering less.
        XCTAssertEqual(
            observation.reportedSessionLifecycle, Self.expectedSessionLifecycle,
            """
            The probe did not report driving a complete session through VoccaCore's real state \
            machine and watchdog.
              expected: \(Self.expectedSessionLifecycle)
              observed: \(observation.reportedSessionLifecycle ?? "no report at all")
            Either VoccaNetworkProbe.exerciseSessionLifecycle() was not called on the \
            default-configuration path — in which case VoccaCore's actual behaviour is outside this \
            invariant, and only its name is inside it — or the session no longer behaves as \
            written. Both matter, and the second more: the fields cover custody (a buffer reached \
            the outcome) and the hot mic (the microphone was opened once and released), which are \
            the two things this project promised would not fail silently.
            Do not fix this by deleting the call, and do not fix it by pasting in whatever the \
            probe now prints — see testTheAssertedSessionPostConditionStillDescribesACompleteSession.
            \(observation.diagnosticSummary)
            """)

        // The injection-lifecycle post-condition. The third effect-not-reference check: `VoccaInject`
        // stopped being a placeholder and became the ladder — the decision function, the rung
        // strategies, the strategy order and the failsafe handoff — and the coverage guard below is
        // at module granularity by construction, so it can say the module was reached, never that its
        // work ran. Before this line, `VoccaInjectPlaceholder.self` in the probe's list satisfied the
        // guard whether or not a single line of `VoccaInject` executed.
        //
        // Deleting the drive from the probe removes this line from its output entirely, so the
        // comparison fails against `nil` rather than quietly covering less.
        XCTAssertEqual(
            observation.reportedInjectionLifecycle, Self.expectedInjectionLifecycle,
            """
            The probe did not report driving the ladder through VoccaInject's real decision \
            function and LadderInjector.
              expected: \(Self.expectedInjectionLifecycle)
              observed: \(observation.reportedInjectionLifecycle ?? "no report at all")
            Either VoccaNetworkProbe.exerciseInjectionLifecycle() was not called on the \
            default-configuration path — in which case VoccaInject's actual behaviour is outside \
            this invariant, and only its name is inside it — or the ladder no longer behaves as \
            written. Both matter, and the second more: the fields cover the two halves of I1 on \
            the injection path — a run that delivered (and held nothing) and a run that fell \
            through to the failsafe (and held exactly one transcript, so none was lost).
            Do not fix this by deleting the call, and do not fix it by pasting in whatever the \
            probe now prints — see \
            testTheAssertedInjectionPostConditionStillDescribesADeliveryAndAHandoff.
            \(observation.diagnosticSummary)
            """)

        // The full-cycle post-condition. The fourth effect-not-reference check, and the one that
        // closes the loop the invariant exists for: `VoccaAudio` and `VoccaASR` stopped being
        // placeholders and became the capture path and the engines, and the coverage guard below
        // is at module granularity by construction — it can say a module was reached, never that
        // its work ran. Before this line, `VoccaAudioPlaceholder.self` and
        // `VoccaASRPlaceholder.self` in the probe's list satisfied the guard whether or not a
        // single line of either module executed.
        //
        // Deleting the drive from the probe removes this line from its output entirely, so the
        // comparison fails against `nil` rather than quietly covering less.
        XCTAssertEqual(
            observation.reportedCycleLifecycle, Self.expectedCycleLifecycle,
            """
            The probe did not report driving a complete dictation cycle through the composed root.
              expected: \(Self.expectedCycleLifecycle)
              observed: \(observation.reportedCycleLifecycle ?? "no report at all")
            Either VoccaNetworkProbe.exerciseDictationCycle() was not called on the \
            default-configuration path — in which case VoccaAudio's and VoccaASR's actual \
            behaviour is outside this invariant, and only their names are inside it — or the \
            composed loop no longer behaves as written. Both matter, and the second more: the \
            fields cover the capture path (the graph ledger and the completeness link), the \
            transcription (the stub's attribution and its one call), the injection (the clipboard \
            rung with the trace), and every surface that must stay quiet on the happy path (no \
            failsafe, no hold, no download, the toggle's microphone never opened).
            Do not fix this by deleting the call, and do not fix it by pasting in whatever the \
            probe now prints — see \
            testTheAssertedCyclePostConditionStillDescribesACompleteDictationCycle.
            \(observation.diagnosticSummary)
            """)

        // The latency post-condition. The fifth effect-not-reference check: after the cycle, the
        // probe reports its ledger's `describe()` — the pure, deterministic rendering of every
        // finalized record — so the loop's own numbers are observable headlessly (spec §5, W5).
        // The line exists only when exerciseDictationCycle() is followed by a latency report, so
        // its absence is a missing drive rather than an empty ledger. It is asserted by property
        // rather than verbatim: the record count and the class/spans/id facts are stable, but the
        // ASR span's duration is a real measurement (the drive's engine clock is the shipped
        // ContinuousMonotonicClock), and a measured number is a fact, not a constant.
        //
        // Deleting the report removes the line entirely, so the unwrap below fails against nil
        // rather than quietly covering less — the same shape as the four post-conditions above.
        let latency = try XCTUnwrap(
            latencyPayload(of: observation),
            """
            The probe did not report its latency ledger's describe() output after the dictation \
            cycle. Either VoccaNetworkProbe.exerciseDictationCycle() is no longer followed by a \
            PROBE-LATENCY report, or the composed root is no longer wired to a ledger at all. \
            Both matter: without the line, the loop's own latency numbers are observable to \
            nothing, and the zero-network assertion says nothing about the recording path.
            \(observation.diagnosticSummary)
            """)
        // Exactly one record: describe() renders one "session <id>:" per finalized record, and
        // the drive runs exactly one cycle. Zero would be a cycle that recorded nothing; more
        // than one would be a session that closed two records.
        XCTAssertEqual(
            occurrences(of: "session ", in: latency), 1,
            """
            The latency report does not contain exactly one record. One cycle must finalize \
            exactly one record — anything else is a cycle that recorded nothing or recorded \
            twice. payload: \(latency)
            """)
        // The record's id, minted by the cycle's own ledger: a fresh ledger's first mint is
        // deterministic, and describe() renders in mint order (W5's stability claim).
        XCTAssertTrue(
            latency.hasPrefix("session 0:"),
            "The latency report's single record is not the first-minted id: \(latency)")
        // The class: delivered, off the clipboard rung — the cycle delivered, and only a
        // delivered record may carry that class.
        XCTAssertTrue(
            latency.contains("delivered("),
            "The latency report's record is not class delivered: \(latency)")
        // The four spans the P0 loop measures — capture-close closing on the stop path, the
        // pipeline's asr and inject, and the cleanup span the wired cleanup stage records on
        // every answer. The cleanup span C5 wired is *in the record*: the ledger's notPresent
        // is the absence of the span (describe() renders only what was recorded), so the honest
        // assertion is that the recorded cleanup token appears — never a fabricated zero, and
        // never a span the pipeline did not measure.
        XCTAssertTrue(
            latency.contains("captureClose") && latency.contains("asr")
                && latency.contains("cleanup") && latency.contains("inject"),
            """
            The latency report's record is missing one of the captureClose/asr/cleanup/inject \
            spans. payload: \(latency)
            """)
        XCTAssertTrue(
            latency.contains("cleanup"),
            """
            The latency report's record carries no cleanup span — C5 is wired, and the ledger \
            carries the recorded cleanup span the pipeline measured around the rules provider, \
            which describe() renders. payload: \(latency)
            """)

        // The coverage cross-check. Without it the assertions above stay green while covering an
        // ever-smaller fraction of the product, which is the most likely way this gate rots.
        let manifest = try PackageManifest.load(
            packageRoot: try PackageRootLocator.find(from: #filePath))
        let expected = try modulesRequiringCoverage(manifest: manifest)
        let exercised = observation.reportedModules
        XCTAssertEqual(
            exercised, expected,
            """
            The probe's default-configuration path does not cover every module in this package.
              never driven by the probe: \(expected.subtracting(exercised).sorted())
              reported but not a module: \(exercised.subtracting(expected).sorted())
            A module the probe never reaches is a module the zero-network invariant says nothing \
            about. Drive it from VoccaNetworkProbe.exerciseDefaultConfiguration() — including its \
            default-configuration start-up work, not just a reference to one of its types.
            \(observation.diagnosticSummary)
            """)
    }

    // MARK: - Test C: the post-condition is still worth asserting

    /// **Guards the guard.** ``expectedSessionLifecycle`` must keep describing a session that
    /// started, captured, handed its audio to custody and released the microphone.
    ///
    /// Test B compares the probe's report against that constant, which makes the constant the whole
    /// strength of the check — and constants that appear in a failing diff get regenerated. That is
    /// the realistic way this gate rots: someone shortens the drive (drops the wakes, stops before
    /// the release, lets the outcome carry a fresh buffer), sees Test B fail, and pastes in what the
    /// probe now prints. The suite goes green having asserted a post-condition that no longer says
    /// anything.
    ///
    /// So this test reads the constant back and refuses that edit. It asserts *properties* rather
    /// than the literal — no buffer may be missing, no microphone may be left open, the session must
    /// end through the completed side of the custody funnel, and the clock must have moved — so it
    /// stays true across legitimate changes to the drive while failing every weakening of it.
    ///
    /// It costs no probe run: the constant is what is under test, not the process.
    func testTheAssertedSessionPostConditionStillDescribesACompleteSession() throws {
        let fields = try Self.parseFields(of: Self.expectedSessionLifecycle)

        func value(_ key: String) throws -> String {
            guard let found = fields[key] else {
                throw ZeroNetworkTestError.postConditionMissingField(
                    key: key, present: fields.keys.sorted())
            }
            return found
        }

        // A session began, and the press did not also reach the focused application.
        //
        // It began in **two** steps, which is the shipped timing rather than an accident of this
        // drive: the press decides, and the owner opens the microphone afterwards, off the tap
        // callback. All three clauses are asserted, because each refuses a different weakening — a
        // drive that reverted to opening inline (`press=started`), one that asked for an opening
        // nobody owed (`openingWasOwed=false`), and one that opened the microphone on the callback
        // after all (`press.openedMicrophone` non-zero). The third is the decision `CaptureStartTiming`
        // records, asserted end-to-end in the only place in `Sources/` that runs it.
        XCTAssertEqual(
            try value("press"), "opening",
            "The asserted post-condition no longer decides a session on the press, so nothing after it is a session.")
        XCTAssertEqual(
            try value("openingWasOwed"), "true",
            """
            The asserted post-condition no longer checks that an opening was *owed* before it was \
            performed, so it would pass against a machine that had reverted to opening the \
            microphone inline on the tap callback.
            """)
        XCTAssertEqual(
            try value("opening"), "started",
            "The asserted post-condition no longer starts a session, so nothing after it is a session.")
        XCTAssertEqual(
            try value("press.openedMicrophone"), "0",
            """
            The asserted post-condition tolerates the microphone being opened on the tap callback. \
            That is the 114 ms engine start this phase exists to move off it — see CaptureStartTiming.
            """)

        // It ended through the funnel, on the side that hands audio downstream. `cancelled` here —
        // or anything but `ended(completed(…))` — would mean the invariant is being asserted against
        // the one path that is *allowed* to discard, which proves the opposite of what is wanted.
        let release = try value("release")
        XCTAssertTrue(
            release.hasPrefix("ended(completed("),
            """
            The asserted post-condition no longer ends the session through the retaining side of the \
            custody funnel (release=\(release)). "A transcript is never lost" is exactly what this \
            line is here to witness.
            """)

        // A buffer travelled with it. `none` is what the probe reports when no audio reached the
        // outcome, and it is the single most valuable thing this post-condition can refuse.
        XCTAssertNotEqual(
            try value("audio.ordinal"), "none",
            "The asserted post-condition no longer carries captured audio into the outcome.")
        XCTAssertNotEqual(
            try value("audio.frames"), "none",
            "The asserted post-condition no longer carries captured audio into the outcome.")

        // The microphone was opened, released, and is not open now. Every one of these is a
        // separate way for the widget to say idle over a live input device.
        XCTAssertEqual(
            try value("mic.open"), "false",
            "The asserted post-condition leaves the microphone open after the session ended.")
        XCTAssertEqual(
            try value("mic.overlappingOpens"), "0",
            "The asserted post-condition tolerates a second microphone opened inside the first.")
        XCTAssertEqual(
            try value("mic.closesWithoutOpen"), "0",
            "The asserted post-condition tolerates a close with no matching open.")
        let opens = Int(try value("mic.opens")) ?? 0
        let closes = Int(try value("mic.closes")) ?? -1
        XCTAssertGreaterThanOrEqual(
            opens, 1, "The asserted post-condition never opens the microphone at all.")
        XCTAssertEqual(
            closes, opens,
            "The asserted post-condition does not balance every microphone open with a close.")

        // The watchdog ran, polled, and moved the machine's clock. Without this the drive could be
        // shortened to a press and a release, leaving the timer path — the only thing that can end a
        // session nobody is holding a key for — outside the invariant again.
        XCTAssertGreaterThanOrEqual(
            Int(try value("wakes")) ?? 0, 1,
            "The asserted post-condition no longer turns the watchdog's timer.")
        XCTAssertGreaterThanOrEqual(
            Int(try value("wake.keyReads")) ?? 0, 1,
            "The asserted post-condition no longer polls the physical key state.")
        XCTAssertGreaterThan(
            Int(try value("elapsed").replacingOccurrences(of: "ms", with: "")) ?? 0, 0,
            """
            The asserted post-condition accumulates no elapsed time, so the drive would pass with a \
            clock that never advances — which disables the 120 s ceiling outright rather than \
            delaying it.
            """)

        // And it came to rest: no session, no timer.
        XCTAssertEqual(try value("state"), "idle")
        XCTAssertEqual(try value("schedule"), "stopped")
    }

    // MARK: - Test D: the injection post-condition is still worth asserting

    /// **Guards the guard.** ``expectedInjectionLifecycle`` must keep describing a ladder that
    /// delivered once, held once, and moved its clock — the same protection
    /// ``testTheAssertedSessionPostConditionStillDescribesACompleteSession`` gives the session
    /// constant, for the same reason: a constant that appears in a failing diff gets regenerated,
    /// and regenerating `expectedInjectionLifecycle` to whatever the probe now prints is the
    /// realistic way this gate rots.
    ///
    /// So this test reads the constant back and refuses that edit, asserting *properties* rather
    /// than the literal:
    ///
    /// - the run named "success" delivered through a real rung, never the widget — otherwise the
    ///   "one successful path" claim is being witnessed by a run that actually failed over;
    /// - the run named "failsafe" ended in the widget, with the full attempted trace intact;
    /// - exactly one transcript reached the handoff — so the run that delivered held nothing and
    ///   the run that exhausted held its transcript, which is the zero-loss claim in the only
    ///   form a two-run drive can witness it;
    /// - the held transcript's reason is exhaustion, and the clock moved on every run.
    ///
    /// Like its session sibling it costs no probe run: the constant is what is under test, not the
    /// process.
    func testTheAssertedInjectionPostConditionStillDescribesADeliveryAndAHandoff() throws {
        let fields = try Self.parseFields(of: Self.expectedInjectionLifecycle)

        func value(_ key: String) throws -> String {
            guard let found = fields[key] else {
                throw ZeroNetworkTestError.postConditionMissingField(
                    key: key, present: fields.keys.sorted())
            }
            return found
        }

        func milliseconds(_ value: String) -> Int {
            Int(value.replacingOccurrences(of: "ms", with: "")) ?? 0
        }

        // The "success" run really delivered: it stopped on a shipping rung, not the widget, and
        // the trace records that rung as attempted. A `success.rung=widgetFailsafe` here would
        // mean the drive's one claimed delivery never happened — the constant is witnessing the
        // exact failure it says it prevented.
        XCTAssertNotEqual(
            try value("success.rung"), "widgetFailsafe",
            "The asserted injection post-condition's success run never delivered — it ended in the "
            + "widget, so the drive's one successful path is not being asserted at all.")
        let successAttempted = try value("success.attempted").split(separator: ",")
        XCTAssertFalse(
            successAttempted.isEmpty,
            "The asserted injection post-condition's success run attempted no rung.")
        XCTAssertTrue(
            successAttempted.contains(Substring(try value("success.rung"))),
            "The asserted injection post-condition's success run did not record the rung it claims "
            + "won in its attempted trace.")

        // The failsafe run ended in the widget — `.widgetFailsafe` is a *successful* outcome under
        // I1, and this is the half that says a delivered run and a held run are told apart.
        XCTAssertEqual(
            try value("failsafe.rung"), "widgetFailsafe",
            "The asserted injection post-condition's failsafe run does not end in the widget "
            + "failsafe, so nothing is witnessed about the fall-through path.")
        XCTAssertEqual(
            try value("failsafe.attempted"), "clipboardPaste,keystrokeSynthesis",
            "The asserted injection post-condition no longer carries the full attempted trace — "
            + "that trace is C8's strategy-memory input and must survive the round trip.")

        // Exactly one transcript was held. One is the whole point: the run that delivered held
        // nothing, and the run that exhausted held its transcript — both halves, on one ledger. A
        // `handoff.holds=0` would be a silent transcript loss wearing a green suite, and a value
        // above one would mean the drive lost a transcript somewhere it does not claim to.
        XCTAssertEqual(
            try value("handoff.holds"), "1",
            "The asserted injection post-condition does not hold exactly one transcript: the run "
            + "that exhausted must hold its transcript and the run that delivered must hold "
            + "nothing, which is the zero-loss claim in the only form a two-run drive can witness "
            + "it.")

        // Why it was held, and when: the exhaustion reason, at a non-zero monotonic instant.
        XCTAssertEqual(
            try value("handoff.reason"), "exhausted",
            "The asserted injection post-condition no longer reports the held transcript's reason "
            + "as exhaustion.")
        XCTAssertGreaterThan(
            milliseconds(try value("handoff.capturedAt")), 0,
            "The asserted injection post-condition holds its transcript at a clock that never "
            + "moved, so the drive would pass with time standing still.")

        // Both runs charged their clock, and the failed run charged more of it than the delivered
        // one — otherwise the runs are indistinguishable on the one field time contributes, and a
        // drive where the clock never advances passes.
        XCTAssertGreaterThan(
            milliseconds(try value("success.elapsed")), 0,
            "The asserted injection post-condition accumulates no time on the delivered run.")
        XCTAssertGreaterThan(
            milliseconds(try value("failsafe.elapsed")), 0,
            "The asserted injection post-condition accumulates no time on the failsafe run.")
        XCTAssertGreaterThan(
            milliseconds(try value("failsafe.elapsed")),
            milliseconds(try value("success.elapsed")),
            "The asserted injection post-condition's failsafe run does not outlast its delivered "
            + "run, so the per-rung clock accumulation is not being asserted.")

        // Clipboard truth is unverified, and the failsafe result carries no read-back either. A
        // verified success on either would be a fabricated claim the rungs never made.
        XCTAssertEqual(
            try value("success.verified"), "false",
            "The asserted injection post-condition reports a verified clipboard delivery; the "
            + "clipboard rung has no read-back.")
        XCTAssertEqual(
            try value("failsafe.verified"), "false",
            "The asserted injection post-condition reports a verified failsafe outcome.")
    }

    // MARK: - Test E: the full-cycle post-condition is still worth asserting

    /// **Guards the guard.** ``expectedCycleLifecycle`` must keep describing a complete dictation
    /// cycle — started, captured, transcribed with the stub's attribution, delivered through a
    /// real rung, and quiet on every surface that must stay quiet — the same protection the other
    /// three guard-the-guard tests give their constants, for the same reason: a constant that
    /// appears in a failing diff gets regenerated, and regenerating `expectedCycleLifecycle` to
    /// whatever the probe now prints is the realistic way this gate rots.
    ///
    /// It costs no probe run: the constant is what is under test, not the process.
    func testTheAssertedCyclePostConditionStillDescribesACompleteDictationCycle() throws {
        let fields = try Self.parseFields(of: Self.expectedCycleLifecycle)

        func value(_ key: String) throws -> String {
            guard let found = fields[key] else {
                throw ZeroNetworkTestError.postConditionMissingField(
                    key: key, present: fields.keys.sorted())
            }
            return found
        }

        // The session began and ended: the press was swallowed, the machine was recording right
        // after it, and it came to rest at the end. `state` not idle would mean the constant is
        // witnessing a session that never ended.
        XCTAssertEqual(
            try value("press"), "swallow",
            "The asserted full-cycle post-condition no longer swallows the hotkey press.")
        XCTAssertEqual(
            try value("recording"), "1",
            "The asserted full-cycle post-condition never starts a session.")
        XCTAssertEqual(
            try value("state"), "idle",
            "The asserted full-cycle post-condition leaves the machine in a session.")

        // The microphone opened exactly once and closed exactly once, and audio travelled.
        XCTAssertEqual(
            try value("mic.opens"), "1",
            "The asserted full-cycle post-condition never opens the microphone.")
        XCTAssertEqual(
            try value("mic.stops"), "1",
            "The asserted full-cycle post-condition does not close the microphone exactly once.")
        XCTAssertGreaterThan(
            Int(try value("frames")) ?? 0, 0,
            "The asserted full-cycle post-condition carries no frames into the engine.")

        // The transcript is the stub's, it is complete, and the engine was asked exactly once —
        // a second call would be a pipeline that re-transcribed, and a non-stub attribution would
        // be a composition that built the real engine (and downloaded a model to do it).
        XCTAssertEqual(
            try value("transcript.missing"), "0",
            "The asserted full-cycle post-condition's transcript is marked incomplete.")
        XCTAssertEqual(
            try value("transcript"), "1-2-3",
            "The asserted full-cycle post-condition's transcript is not the stub's canonical "
            + "`1 2 3` (reported space-free as `1-2-3`).")
        XCTAssertEqual(
            try value("engine"), "probe-stub-engine",
            """
            The asserted full-cycle post-condition's transcript is attributed to something other \
            than the probe's stub engine. The whole point of the substitution is that the real \
            engine's construction — and its model download — is structurally unreachable from the \
            probe's composition.
            """)
        XCTAssertEqual(
            try value("engine.transcribes"), "1",
            "The asserted full-cycle post-condition does not transcribe exactly once.")
        XCTAssertEqual(
            try value("manifest.engine"), "parakeet-tdt-0.6b-v3",
            "The asserted full-cycle post-condition no longer names the shipped Parakeet manifest.")
        XCTAssertEqual(
            try value("cleanup.engine"), "rules-cleanup",
            "The asserted full-cycle post-condition no longer names the shipped rules cleanup "
            + "provider — a constant that dropped the cleanup fact must fail here.")
        XCTAssertEqual(
            try value("egress"), "none",
            "The asserted full-cycle post-condition no longer folds the egress badge to none on "
            + "the default (rules) path — a constant that dropped the badge fact, or one that "
            + "claimed a badge where the default shows none, must fail here.")

        // The same text reached the injector and was delivered through a real rung, with the
        // trace to match — `widgetFailsafe` here would mean the drive's one claimed delivery
        // never happened, exactly as in the injection post-condition's guard.
        XCTAssertEqual(
            try value("injected"), "1-2-3.",
            "The asserted full-cycle post-condition's cleaned text never reached the injector — "
            + "the digits survive the empty-dictionary rules path, the terminal punctuation the "
            + "rules engine appends is the only change.")
        let rung = try value("rung")
        XCTAssertNotEqual(
            rung, "widgetFailsafe",
            "The asserted full-cycle post-condition's cycle never delivered — it ended in the "
            + "widget failsafe, so the happy path is not being asserted at all.")
        XCTAssertTrue(
            try value("attempted").split(separator: ",").contains(Substring(rung)),
            "The asserted full-cycle post-condition did not record the rung it claims won in its "
            + "attempted trace.")

        // The happy path's quiet surfaces: nothing presented, nothing held, nothing downloaded,
        // and the inactive configuration never opened its microphone. Each is a separate way the
        // constant could stop describing the happy path while still looking like one.
        XCTAssertEqual(
            try value("failsafe"), "0",
            "The asserted full-cycle post-condition tolerates a failsafe presentation on the "
            + "happy path.")
        XCTAssertEqual(
            try value("holds"), "0",
            "The asserted full-cycle post-condition tolerates a held transcript on the happy path.")
        XCTAssertEqual(
            try value("download.starts"), "0",
            "The asserted full-cycle post-condition tolerates a model download starting during "
            + "the probe run.")
        XCTAssertEqual(
            try value("toggle.opens"), "0",
            "The asserted full-cycle post-condition tolerates the inactive configuration opening "
            + "its microphone.")
        XCTAssertEqual(
            try value("widget"), "delivered",
            "The asserted full-cycle post-condition no longer ends with the widget showing the "
            + "delivery.")

        // The latency ledger closed exactly one record: the structured count token of the
        // whole-line assertion. Zero would mean the drive no longer records anything, and a
        // value above one would mean one session closed two records.
        XCTAssertEqual(
            try value("records"), "1",
            "The asserted full-cycle post-condition does not close exactly one latency record.")
    }

    /// The `PROBE-LATENCY` line's payload — the ledger's `describe()` output — or `nil` when the
    /// probe never reported one.
    ///
    /// Mirrors the report-prefix scanning of the observation accessors in `NetworkInterposer`:
    /// the line exists only when `exerciseDictationCycle()` is followed by a latency report, so
    /// its absence is a missing drive rather than an empty ledger.
    private func latencyPayload(of observation: NetworkObservation) -> String? {
        for line in observation.probeStandardOutput.split(separator: "\n")
        where line.hasPrefix("PROBE-LATENCY\t") {
            return String(line.dropFirst("PROBE-LATENCY\t".count))
        }
        return nil
    }

    /// How many times `needle` occurs in `haystack` — the exactly-one-record count of the
    /// `describe()` payload, which renders one `session <id>:` per finalized record.
    private func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    /// Splits a `key=value key=value` post-condition, refusing anything that is not one.
    ///
    /// Fails closed on an empty line, a malformed field or a repeated key: each would leave the test
    /// above asserting against a dictionary that quietly lost a field, which is the same vacuous
    /// green it exists to prevent.
    private static func parseFields(of line: String) throws -> [String: String] {
        let parts = line.split(separator: " ")
        guard !parts.isEmpty else { throw ZeroNetworkTestError.postConditionNotParseable(line) }
        var fields: [String: String] = [:]
        for part in parts {
            guard let separator = part.firstIndex(of: "="), separator != part.startIndex else {
                throw ZeroNetworkTestError.postConditionNotParseable(String(part))
            }
            let key = String(part[part.startIndex..<separator])
            guard fields.updateValue(String(part[part.index(after: separator)...]), forKey: key)
                == nil
            else {
                throw ZeroNetworkTestError.postConditionHasARepeatedField(key: key)
            }
        }
        return fields
    }

    // MARK: - Shared plumbing

    /// Runs one probe mode under the interposer and returns what was observed, having already
    /// asserted the three things that must hold before any observation can be believed: the probe
    /// ran, it ran to completion, and something was watching while it did.
    private func runProbe(
        mode: ProbeMode, file: StaticString = #filePath, line: UInt = #line
    ) throws -> NetworkObservation {
        let session = try NetworkInterposer.startObserving()
        let exitStatus = try session.runProbe(mode: mode)
        let observation = try session.stopObserving()

        XCTAssertEqual(
            exitStatus, 0, "Probe did not run cleanly:\n\(observation.diagnosticSummary)",
            file: file, line: line)

        // Checked before any zero-assertion: a failure to instrument would otherwise present
        // itself as a perfect score.
        XCTAssertTrue(
            observation.interposerDidLoad,
            """
            The interposer never loaded into the probe process, so it observed nothing and could \
            not have observed anything. Zero observed connections here is the absence of \
            evidence, not evidence of absence.
            \(observation.diagnosticSummary)
            """,
            file: file, line: line)

        XCTAssertTrue(
            observation.probeCompleted(mode: mode),
            """
            The probe never reported completing mode '\(mode.rawValue)'. Whatever it did, it was \
            not the work this test believes it was observing.
            \(observation.diagnosticSummary)
            """,
            file: file, line: line)

        return observation
    }

    /// The set of modules the probe must drive.
    ///
    /// Built to **fail closed**: it is the union of every directory under `Sources/` and every
    /// drivable target the manifest declares, minus the target kinds no Swift code can import and
    /// minus only those exclusions that survive ``justifiedExclusions(manifest:)``. Taking the
    /// union of both sources means neither a module that exists on disk without a manifest entry,
    /// nor one declared with a custom `path:`, can slip past — and nothing keys on what the
    /// module happens to be *named*.
    ///
    /// That last point is the fix for a real miss: an earlier version filtered on a `Vocca`
    /// prefix, so adding `Sources/KokoroTTS/` — a plausible module, given Kokoro is the locked
    /// TTS choice — left the suite green.
    private func modulesRequiringCoverage(manifest: PackageManifest) throws -> Set<String> {
        let candidates = try sourceDirectories().union(manifest.drivableTargetNames)
        guard !candidates.isEmpty else {
            throw ZeroNetworkTestError.noModulesDiscovered(
                sourcesRoot: try PackageRootLocator.find(from: #filePath)
                    .appendingPathComponent("Sources").path)
        }
        // Subtracted before exclusions are consulted, so a plugin or binary target neither has to
        // be driven (impossible) nor has to be excluded (which the shipping guard would rightly
        // refuse). Applied to the directory-derived half too, since a plugin target has a
        // `Sources/` directory like any other.
        let required =
            candidates
            .subtracting(manifest.nonDrivableTargetNames)
            .subtracting(justifiedExclusions(manifest: manifest))

        // Re-checked *after* the subtractions, not just before. `candidates` being non-empty says
        // nothing about what survives them: if the two subtractions between them removed
        // everything, Test B would compare an empty set against an empty set and pass while
        // requiring nothing at all. No route to that is known today — it is closed because
        // vacuous-green is the exact shape of every hole this file has had to fix.
        guard !required.isEmpty else {
            throw ZeroNetworkTestError.everyModuleExcluded(
                candidates: candidates.sorted(),
                nonDrivable: manifest.nonDrivableTargetNames.sorted())
        }
        return required
    }

    /// Filters ``candidateExclusions`` down to the ones the manifest actually justifies, and
    /// fails the test for any that it does not.
    ///
    /// An exclusion is honoured only when the manifest says the target is not reachable from any
    /// product whose name does not begin with `_`. So a module that ships — or that anything
    /// shipping depends on — cannot be excluded, no matter what is written in the list.
    ///
    /// That rests on the underscore vocabulary being **closed**, which it is:
    /// `PackageManifest.permittedUnderscoredProducts` pins it to the one legitimate fixture
    /// product. This is load-bearing, not bookkeeping. While the vocabulary was open, the rule
    /// was self-service — renaming `VoccaSpeech`'s product to `_VoccaSpeech` took it out of the
    /// shipping set, which made excluding it legal and lifted it out of the invariant entirely.
    ///
    /// **Residual limitation, stated rather than hidden:** a target that belongs to no product
    /// *and* that nothing shipping depends on is structurally not part of the app, so it can
    /// still be excluded. If it is later wired into a product or depended on by one, this check
    /// starts failing until the probe drives it.
    private func justifiedExclusions(manifest: PackageManifest) -> Set<String> {
        let shipping = manifest.shippingTargets
        var honoured: Set<String> = []

        for exclusion in Self.candidateExclusions {
            XCTAssertNotNil(
                manifest.targets[exclusion.target],
                """
                Coverage exclusion '\(exclusion.target)' is not a target in this package. Remove \
                the stale entry rather than leaving a name here that excludes nothing.
                """)

            if shipping.contains(exclusion.target) {
                XCTFail(
                    """
                    Coverage exclusion '\(exclusion.target)' is not allowed: the manifest says it \
                    is reachable from a product this package ships, so it is product code and the \
                    probe must drive it.
                      stated reason: \(exclusion.reason)
                    Excluding a shipping module would make the zero-network invariant silently \
                    stop covering it. Drive it from \
                    VoccaNetworkProbe.exerciseDefaultConfiguration() instead.
                    """)
                continue
            }
            honoured.insert(exclusion.target)
        }
        return honoured
    }

    /// Every directory directly under `Sources/`, whatever it is called.
    private func sourceDirectories() throws -> Set<String> {
        let sourcesRoot = try PackageRootLocator.find(from: #filePath)
            .appendingPathComponent("Sources")
        let entries = try FileManager.default.contentsOfDirectory(
            at: sourcesRoot, includingPropertiesForKeys: [.isDirectoryKey])
        var names: Set<String> = []
        for entry in entries {
            let isDirectory =
                (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory { names.insert(entry.lastPathComponent) }
        }
        return names
    }
}
