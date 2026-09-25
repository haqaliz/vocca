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
        // C8's strategy memory, on the path every fresh install runs: the ladder is the
        // memory-backed one, and the store it loaded from had no file — so the projection is
        // the shipped C4 order, `rung` above is unchanged, and no `strategies.json` was read or
        // written by a process the interposer is watching for `connect(2)`.
        "strategy=absent",
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

    /// **The streaming-cycle post-condition**: what the probe must report after driving one
    /// streaming dictation cycle through the composed root — a streaming stub engine in the
    /// resolver's slot, a scripted chunk source handed to `routeStreaming`, each partial folded
    /// into the widget store, and the one final routed through cleanup → inject — and what
    /// ``testStreamingCycleDeliversPartialsToTheWidgetStoreWithZeroNetworkCalls`` asserts
    /// wholesale.
    ///
    /// Asserted as an *effect* for the same reason the other post-conditions are. Every field
    /// below is a fact the probe can only produce by running the `widget-streaming` wiring: the
    /// route's surface (idle — the delivered final has nothing for the widget to present); the
    /// sink's presentation count and the store's carried partial (the two halves of "partials
    /// reach the widget store" — the store keeps only the newest, so the count is the witness
    /// that *each* partial reached the wiring); the cleaned final that reached the injector
    /// with the clipboard rung and its trace; the streaming engine's ledgers (never prepared —
    /// preparation is the launch path's job — and never asked to transcribe, so the route
    /// consumed `stream()`); and the surfaces that must stay quiet (no hold, no download
    /// started, exactly one latency record closed).
    ///
    /// This is deliberately **not** a golden string to be regenerated when it fails.
    /// ``testTheAssertedStreamingCyclePostConditionStillDescribesAStreamingCycle`` reads it
    /// back and refuses a version that no longer describes a cycle which streamed, folded
    /// partials into the widget store, delivered the final through a real rung, and never
    /// prepared or downloaded — so weakening the probe and pasting in whatever it now prints
    /// does not restore a green suite.
    private static let expectedStreamingCycleLifecycle = [
        // The route's answer: the delivered final has nothing for the widget to present — the
        // DELIVERED fold is the projection's, and the streaming route is `.idle` exactly as the
        // batch route's delivered row is.
        "surface=idle",
        // The two halves of "partials reach the widget store": every partial the pipeline
        // presented reached the sink (the count), and the store carries the newest one — the
        // script's last partial, `"hello "` (the final transcript is never a partial, by the
        // seam's own contract; the reducer's S3 rule shows the text while RECORDING/TRANSCRIBING).
        "partials=2",
        "partial.last=hello-",
        // The cleaned final reached the injector — the rules engine capitalizes the utterance
        // and appends the terminal punctuation, exactly as it does for the batch cycle's
        // `1 2 3.` — and the ladder stopped at the clipboard rung with the trace to match: the
        // streaming final travels the same decision table the batch final does.
        "injected=Hello-world.",
        "rung=clipboardPaste",
        "attempted=clipboardPaste",
        // The streaming engine's ledgers: never prepared (preparation is the launch path's
        // job — the warm-start aspect's pin) and never asked to transcribe — the route
        // consumed `stream()`, which is the whole point of the drive.
        "engine.prepares=0",
        "engine.transcribes=0",
        // The quiet surfaces: no download session started and nothing held — the same happy
        // path the batch cycle asserts, on the streaming route.
        "download.starts=0",
        "holds=0",
        // The latency ledger closed exactly one record: the streaming route's own finalize
        // row — the minted id the drive handed it, closed once.
        "records=1",
    ].joined(separator: " ")

    /// **The usage-ledger post-condition**: what the probe must report after driving a
    /// launch-shaped round trip through the daily-use ledger — a first-run load against a
    /// directory that does not exist, a finalized record carried by the real `LatencyLedger`
    /// sink, the fold, the cadence declining, termination's flush, and a second
    /// `PersistentUsageStore` loading the committed bytes back — and what
    /// ``testDefaultConfigurationMakesZeroNetworkConnections`` asserts wholesale.
    ///
    /// **This constant is how `usage-store`'s witness debt is discharged.** Until this line,
    /// `VoccaUsage`'s entry in the probe's module list was `PersistentUsageStore.self` — a
    /// metatype reference that satisfied the coverage guard whether or not a line of the module
    /// ever ran, recorded in `usage-store/spec.md` as "bookkeeping, not proof". Every field below
    /// is a fact the probe can only produce by running the module.
    ///
    /// Two of them are not about the ledger at all. `store.location` and `store.isDefaultLocation`
    /// are the standing promise that **no test writes to the founder's real
    /// `~/Library/Application Support/Vocca/`**: the drive reports the directory it built its
    /// store over, and a drive that quietly took `PersistentUsageStore()`'s default location would
    /// fail here rather than silently fold a probe run into a real install's history.
    ///
    /// This is deliberately **not** a golden string to be regenerated when it fails.
    /// ``testTheAssertedUsagePostConditionStillDescribesALoadAndARoundTrip`` reads it back and
    /// refuses a version that no longer loads, no longer round-trips, tolerates a write on the
    /// fold, or lets the drive point at the default location.
    private static let expectedUsageLedgerLifecycle = [
        // Where the drive wrote — the two halves of the temp-directory promise.
        "store.location=temporary",
        "store.isDefaultLocation=false",
        // The first run: the store's directory does not exist, so neither does the file, and the
        // load answers the empty window silently rather than erroring.
        "file.beforeLoad=absent",
        "load.days=0",
        // The composition's seam, run: the ledger finalized one record and its sink delivered it.
        // A `finalized=false` would be a refused finalize, which delivers nothing at all.
        "finalized=true",
        "sink.records=1",
        // The fold landed in the day the provider named — and the file system stayed silent for
        // it. `file.afterFold=absent` is the probe's own echo of D3: writing is not O(1) and must
        // never happen inside the loop the P2 latency gate reads.
        "fold.sessions=1",
        "file.afterFold=absent",
        // Termination's write, the `AppBootstrap.main()` quit hook's half.
        "file.afterFlush=present",
        // The round trip through real bytes: a second store over the same directory got the
        // session back, with its outcome class, its rung and the day the provider resolved.
        "reload.days=1",
        "reload.sessions=1",
        "reload.delivered=1",
        "reload.clipboardPaste=1",
        "reload.dayMatchesProvider=true",
    ].joined(separator: " ")

    /// **The turn-loop post-condition** (PROBE-TURN): the verbatim report of the loop's
    /// fallback default work — two commits, two replies, one barge-in, one gated echo frame,
    /// 61 fed frames, ending idle. Asserted whole, as one line — the `expectedSessionLifecycle`
    /// shape. This is deliberately **not** a golden string to be regenerated when it fails:
    /// ``testTheAssertedTurnPostConditionStillDescribesATurnAndABargeIn`` reads it back and
    /// refuses a version that no longer describes a turn with a barge-in.
    private static let expectedTurnLoopLifecycle =
        "started=1 turnCommits=2 replies=2 bargeIns=1 gated=1 fed=61 state=idle"

    /// **The converse-loop post-condition** (PROBE-CONVERSE): the verbatim report of the
    /// converse driver's fallback default work — two commits, two replies, one barge-in, one
    /// gated echo frame, two ASR transcriptions under `.conversing`, ending idle. Asserted
    /// whole, as one line — the `expectedTurnLoopLifecycle` shape. This is deliberately **not**
    /// a golden string to be regenerated when it fails:
    /// ``testTheAssertedConversePostConditionStillDescribesATurnWithAConversingCleanup`` reads
    /// it back and refuses a version that no longer describes a converse turn.
    private static let expectedConverseLifecycle =
        "started=1 turnCommits=2 replies=2 bargeIns=1 gated=1 asrTranscribes=2 cleanupMode=conversing state=idle"

    /// **The context composition's post-condition** (PROBE-CONTEXT): the verbatim report of
    /// the composed context default work — the **shipped** `AccessibilityContext` provider
    /// over a fresh-empty consent store, never a read (the no-consents gate declines before
    /// any provider call), the unlit fold, two resolutions, no revoke. Asserted whole, as one
    /// line — the `expectedConverseLifecycle` shape. This is deliberately **not** a golden
    /// string to be regenerated when it fails:
    /// ``testTheAssertedContextPostConditionStillDescribesTheShippedAccessibilityContextDefault``
    /// reads it back and refuses a version that no longer describes the composed default.
    private static let expectedContextLifecycle =
        "provider=real reads=0 consents=0 indicator=unlit resolves=2 revoke=no"

    /// **The audit log's post-condition** (PROBE-ACTIONS): the verbatim report of the
    /// `VoccaActions` store's default work — the real store over a fresh temporary directory,
    /// driven through the **composed action recipe** (`wiring` aspect, C13 slice 5): the real
    /// `AuditActionProvider` armed through the wiring's own closures, the binding-mismatch
    /// re-prompt (a sentence that drifted between show and confirm, refused by attempting the
    /// call, re-prompted), the confirm that ran the real clear, the clear's own record
    /// reconstructing off the disk, and the composed default's facts (`servers=0`,
    /// `spawnsSubprocess=false` — the D2 narrowed promise as a reported line, the
    /// `requiresNetwork` analogue). Asserted whole, as one line — the `expectedContextLifecycle`
    /// shape. This is deliberately **not** a golden string to be regenerated when it fails:
    /// ``testTheAssertedActionAuditPostConditionStillDescribesARoundTripThroughRealBytes`` reads
    /// it back and refuses a version that no longer describes the composed round trip.
    ///
    /// The drive exists because creating a module obliges this unit to prove the module does not
    /// egress (`audit-log/spec.md`'s 2026-09-19 amendment). A store that was constructed and
    /// discarded would satisfy the coverage list while never touching the file system, which is
    /// the half of `VoccaActions` that could egress at all.
    ///
    /// `store.location` and `store.isDefaultLocation` are the `expectedUsageLedgerLifecycle`
    /// promise, restated for this module: **no probe run writes to the founder's real
    /// `~/Library/Application Support/Vocca/actions/`**. A drive that quietly took the shipped
    /// location would fold probe entries into a real install's audit log — the one file whose
    /// whole value is that it records what actually happened.
    ///
    /// The wiring aspect owns this line's final shape; what is pinned here is that the decision
    /// source is the composed recipe (the executor inside the wiring) and the sentence binding
    /// is live in the probe's path.
    private static let expectedActionAuditLifecycle = [
        "store=real",
        // Where the drive wrote — the two halves of the temp-directory promise.
        "store.location=temporary",
        "store.isDefaultLocation=false",
        // The composed default's facts: no server is configured out of the box and the default
        // configuration cannot create a child — the D2 narrowed promise, reported not commented.
        "servers=0",
        "spawnsSubprocess=false",
        // The round trip, through the wiring: the log's peak before the clear (two seed stops,
        // the arm's stop, the drift entry, the mismatch's declined decision), the real clear
        // running over all of them, and the clear's own record — the only entry a reader finds —
        // reconstructing with its ordinal and its decision intact.
        "recorded=5",
        "reloaded=1",
        "ordinals=1-1",
        "decisions=confirmed",
        // The wiring's binding: the final confirm carried the re-prompted card's shown sentence
        // and reached the provider — the N2 binding live in the composed path.
        "binding=matched",
        // The binding actually refused once: the drift made the gate render a different
        // sentence, and the wiring re-prompted rather than dead-ending.
        "mismatch=reprompted",
        // And nothing left behind on the machine that ran it.
        "cleared=0",
    ].joined(separator: " ")

    /// **The MCP protocol layer's post-condition** (PROBE-MCP): the verbatim report of a whole
    /// MCP conversation — the shipped `InMemoryMCPTransport`, a successful negotiation, the three
    /// requests that left in order, the two tools discovered, and the tool that declared nothing
    /// answering `false` to "may I be treated as read-only". Asserted whole, as one line — the
    /// `expectedActionAuditLifecycle` shape. This is deliberately **not** a golden string to be
    /// regenerated when it fails:
    /// ``testTheAssertedMCPPostConditionStillDescribesANegotiatedConversation`` reads it back and
    /// refuses a version that no longer describes one.
    ///
    /// ## What a green line here proves, and what it does not
    ///
    /// It proves the **protocol layer** — encoder, frame parser, negotiation, discovery,
    /// annotation reading, call — reaches no network name while a whole conversation runs. That
    /// claim is available only because the card's Q3 decision put an **in-memory** transport
    /// behind the seam, which appends to an array rather than opening anything.
    ///
    /// It proves **nothing** about a stdio transport. That is deviation **D2**, measured rather
    /// than assumed: `DYLD_INSERT_LIBRARIES` is stripped *and purged* from a restricted child's
    /// environment, so a spawned MCP server is invisible to this interposer for its whole
    /// descendant tree, and the failure mode there is a green suite while a child egresses.
    /// `ActionTransportProhibitionTests` is what keeps that a reviewed edit; this line is not a
    /// substitute for it and must never be cited as one.
    ///
    /// `unannotatedIsReadOnly` is the field worth reading twice: the scripted peer offers a tool
    /// with no annotations at all, and this is that tool's own answer. **Absent means unsafe**,
    /// observed here in a live process rather than only in a unit test.
    private static let expectedMCPLifecycle = [
        // The shipped transport, named from its own type — a swapped-in double flips it.
        "transport=in-memory",
        "negotiated=yes",
        // Read off the transport's record of what actually left, in order.
        "requests=3",
        "methods=initialize,tools/list,tools/call",
        // What discovery parsed: one tool claiming read-only, one claiming nothing.
        "tools=2",
        "readOnlyTools=1",
        // The fail-safe default, live.
        "unannotatedIsReadOnly=false",
        // The tool answered, so the call completed rather than merely being attempted.
        "called=ok",
    ].joined(separator: " ")

    /// **The intent voice round trip's post-condition** (PROBE-INTENT): the verbatim report of
    /// the `intent-layer` probe drive's composed-recipe round trip — the real audit store over a
    /// fresh temporary directory, the intent recipe composed over a call-logged probe provider
    /// and the **real** `KeywordIntentResolver` (a probe-seeded synonym table), the utterance
    /// resolving, the gate asking (the card with the provider's sentence verbatim), the existing
    /// confirm closure answering with the shown sentence bound, the provider's `invoke` counted,
    /// and the audit row reconstructing off the disk. Asserted whole, as one line — the
    /// `expectedActionAuditLifecycle` shape. This is deliberately **not** a golden string to be
    /// regenerated when it fails:
    /// ``testTheAssertedIntentPostConditionStillDescribesAVoiceRoundTripThroughTheRecipe`` reads
    /// it back and refuses a version that no longer describes the composed round trip.
    ///
    /// `store.location` and `store.isDefaultLocation` are the `expectedUsageLedgerLifecycle`
    /// promise, restated for this module's voice leg: **no probe run writes to the founder's real
    /// `~/Library/Application Support/Vocca/`**.
    private static let expectedIntentLifecycle = [
        // The real store, named from its own type — a swapped-in double flips it.
        "store=real",
        // Where the drive wrote — the two halves of the temp-directory promise.
        "store.location=temporary",
        "store.isDefaultLocation=false",
        // The wiring's resolve answered a confident match — the round trip has a first leg.
        "resolved=1",
        // The gate asked: the card appeared with the provider's sentence.
        "card=yes",
        // The provider's own call log: confirm → invoke exactly once, counted.
        "invoked=1",
        // The audit store's own decoded answer: the withheld stop (refused) and the confirmed
        // invoke, in ordinal order — the reconstruct, read off the disk by a second store.
        "decisions=refused,confirmed",
        "ordinals=1-2",
        // The N2 binding live in the probe's path: the confirmed entry's summary is the card's
        // shown sentence, verbatim.
        "binding=matched",
    ].joined(separator: " ")

    /// **The composed default's facts** (PROBE-INTENT-DEFAULT): the verbatim report of the
    /// intent composition `AppBootstrap.configure` makes — the composed root's
    /// `NullIntentResolver` fact carrier, one resolution through the **composed** wiring
    /// resolving nothing (`intentResolved=0` — the R7 unwired posture as an effect, not a
    /// comment), and the composed wiring's declared no-spawn fact (`spawnsSubprocess=false` —
    /// the D2 narrowed promise extended to the voice leg). Asserted whole, as one line, and
    /// deliberately **not** a golden string: ``testTheAssertedIntentDefaultPostConditionStillDescribesTheComposedDefault``
    /// reads it back and refuses a version that no longer describes the composed default.
    private static let expectedIntentDefaultLifecycle = [
        // The composed root's fact carrier, derived from the dynamic type of the resolver the
        // root's per-turn provider builds — a composition that wired a different resolver flips
        // it. `phrase-intent-resolver` flipped it deliberately (NullIntentResolver →
        // PhraseIntentResolver): an absent phrase file resolves nothing, so `intentResolved=0`
        // below still holds on a clean machine.
        "resolver=PhraseIntentResolver",
        // The drive actually resolved through the composed wiring — one resolution, counted.
        "resolves=1",
        // That resolution was not a tool call — distinguishable from "the drive didn't run" by
        // the `resolves` field sitting next to it.
        "intentResolved=0",
        // The composed intent wiring's declared fact — the voice leg spawns nothing.
        "spawnsSubprocess=false",
        // The arm-surface-only fact (founder decision): the shipped resolver catalog never
        // names a `dev.vocca.shell` row — the voice leg has no learned phrase that could ever
        // resolve to a shell command, counted off the shipped synonym table.
        "intentShellRows=0",
    ].joined(separator: " ")

    /// **The composed shell drive's post-condition** (PROBE-SHELL): the verbatim report of the
    /// `shell-provider` probe drive — the composed default's facts (`commands=0`,
    /// `spawnsSubprocess=false` — the D2 narrowed promise as a reported line, read off a wiring
    /// composed over an absent registry, the true first-launch default) and the **seeded** round
    /// trip over a benign real command (`/bin/echo`): the registry seeded and enabled, the
    /// argv-derived sentence on the widget card, the confirm running the real child, the dry-run
    /// row that never invoked, and the audit reconstructing off the disk (ordinals, decisions,
    /// binding). Asserted whole, as one line — the `expectedIntentDefaultLifecycle` shape. This
    /// is deliberately **not** a golden string to be regenerated when it fails:
    /// ``testTheAssertedShellPostConditionStillDescribesTheComposedDefaultAndARoundTripThroughRealBytes``
    /// reads it back and refuses a version that no longer describes the composed default and a
    /// round trip.
    ///
    /// `store.location` and `store.isDefaultLocation` are the `expectedUsageLedgerLifecycle`
    /// promise, restated for the shell leg: **no probe run writes to the founder's real
    /// `~/Library/Application Support/Vocca/`**.
    ///
    /// The drive exists because the shell composition is the slice's one route to a real child
    /// under the interposer: the default cannot spawn (proven by the wiring's declared fact and
    /// the empty registry) and the seeded round trip drives the real engine through the gate —
    /// the only spawn this invariant ever observes, and the child itself is exactly what it
    /// cannot see (D2, recorded in the drive's own documentation).
    private static let expectedShellLifecycle = [
        // The real store, named from its own type — a swapped-in double flips it.
        "store=real",
        // Where the drive wrote — the two halves of the temp-directory promise.
        "store.location=temporary",
        "store.isDefaultLocation=false",
        // The composed default's facts: an absent registry is zero commands, and the composed
        // default cannot create a child — the D2 narrowed promise, reported not commented.
        "commands=0",
        "spawnsSubprocess=false",
        // The seeded registry's own answer — the round trip had a command to arm.
        "seeded=1",
        // The gate asked: the card appeared with the argv-derived sentence.
        "card=yes",
        // The engine's own call log: the confirm ran the child exactly once; the dry-run row
        // reached it zero times — counted, never inferred from the audit.
        "invoked=1",
        // The audit store's own decoded answer: the arm's withheld stop, the confirmed run and
        // the dry-run row, in ordinal order — the reconstruct, read off the disk by a second
        // store.
        "decisions=refused,confirmed,dryRun",
        "ordinals=1-3",
        // The N2 binding live in the probe's path: the confirmed entry's summary is the card's
        // shown sentence, verbatim.
        "binding=matched",
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

        // The usage-ledger post-condition. The seventh effect-not-reference check, and the one
        // that pays off a recorded debt: `usage-store` made `VoccaUsage` a shipping target and
        // satisfied this coverage guard with `PersistentUsageStore.self`, writing in its own spec
        // that a reference shows the module was *reached* and says nothing about whether it opens
        // a socket. The module has real default-configuration work now — a launch-time load, a
        // fold per finalized session and a write cadence — and the drive runs all three, so the
        // metatype literal is gone from the probe's list and this line is what stands in its
        // place. Deleting the drive takes the line with it and the comparison fails against `nil`.
        XCTAssertEqual(
            observation.reportedUsageLedger, Self.expectedUsageLedgerLifecycle,
            """
            The probe did not report driving a launch-shaped round trip through VoccaUsage's real \
            store, day provider and recorder.
              expected: \(Self.expectedUsageLedgerLifecycle)
              observed: \(observation.reportedUsageLedger ?? "no report at all")
            Either VoccaNetworkProbe.exerciseUsageLedger() was not called on the \
            default-configuration path — in which case VoccaUsage's actual behaviour is outside \
            this invariant and only its name is inside it, which is exactly the state usage-store \
            recorded as a debt — or the daily-use ledger no longer behaves as written. Both \
            matter: the fields cover the first-run load, the fold that must touch no file, the \
            termination write, the round trip through real bytes, and the directory the drive \
            wrote to.
            Do not fix this by deleting the call, and do not fix it by pasting in whatever the \
            probe now prints — see \
            testTheAssertedUsagePostConditionStillDescribesALoadAndARoundTrip.
            \(observation.diagnosticSummary)
            """)

        // The voice-detection construct post-condition. The eighth effect-not-reference check:
        // the Silero VAD adapter's default-configuration surface is *constructing it over a
        // fresh, empty temporary directory and classifying an empty frame* — the pure init and
        // the empty-frame short-circuit, neither of which touches a model byte or a network
        // name. `VoccaASR` is already covered by the cycle's witness, so the module coverage
        // list alone would not notice a deleted drive; this line is the leg's survival
        // guarantee.
        //
        // Deleting the drive removes the line from the probe's output entirely, so the unwrap
        // below fails against nil rather than quietly covering less.
        let vadFields = try Self.parseFields(
            of: try XCTUnwrap(
                vadConstructPayload(of: observation),
                """
                The probe did not report constructing the Silero VAD adapter over an empty \
                directory and classifying an empty frame.
                Either VoccaNetworkProbe.exerciseVoiceDetection() was not called on the \
                default-configuration path — in which case the adapter's construct-only surface \
                (the pure init the probe contract pins) is outside this invariant — or the \
                adapter no longer behaves as written. Both matter: the report covers the \
                construction, the empty-frame short-circuit and the model-untouched pin.
                \(observation.diagnosticSummary)
                """))
        XCTAssertEqual(
            vadFields["identity"], "silero-vad",
            "the VAD drive must report the adapter's engine identity: \(vadFields)")
        XCTAssertEqual(
            vadFields["construct"], "true",
            "the adapter must construct over a fresh, empty directory without touching anything: "
                + "\(vadFields)")
        XCTAssertEqual(
            vadFields["emptyFrame"], "silence",
            "an empty frame carries no evidence and must classify .silence: \(vadFields)")
        XCTAssertEqual(
            vadFields["modelTouched"], "false",
            "an empty frame must not reach the model — the model dir is empty, so a touch would "
                + "record a load failure: \(vadFields)")
        XCTAssertEqual(
            vadFields["eou"], "pending",
            "the EOU conformance is recorded pending (Branch B, sdk-adapters): \(vadFields)")

        // The turn-loop post-condition. The ninth effect-not-reference check, and the one
        // that pins the loop's **default work** (G6): `VoccaCore`'s turn-taking loop driven
        // over the fallback implementations only — `EnergyVAD` + `SilenceThresholdDetector`,
        // a probe stub synthesizer and a probe fake playback. No model artifact, no SDK, no
        // network name is reachable; the report's `fed`/`gated` counts are derived from the
        // loop's own counters and the commit/reply/barge-in tallies from the effect history —
        // an effect-not-reference check the verbatim comparison below cannot be weakened to
        // a constant without the guard-the-guard noticing.
        //
        // Deleting the drive removes the line from the probe's output entirely, so the
        // comparison fails against nil rather than quietly covering less.
        XCTAssertEqual(
            try XCTUnwrap(turnLoopPayload(of: observation)),
            Self.expectedTurnLoopLifecycle,
            """
            The probe did not report driving the turn-taking loop's fallback default work.
              expected: \(Self.expectedTurnLoopLifecycle)
              observed: \(turnLoopPayload(of: observation) ?? "no report at all")
            Either VoccaNetworkProbe.exerciseTurnLoop() was not called on the \
            default-configuration path — in which case the loop's default work is outside this \
            invariant — or the loop no longer behaves as written. Both matter: the report \
            covers the two commits, the two replies, the single barge-in, the gated echo \
            frame, the 61 fed frames and the idle end state — the shape of a complete turn \
            with a barge-in. Do not fix this by deleting the call, and do not fix it by \
            pasting in whatever the probe now prints — see \
            testTheAssertedTurnPostConditionStillDescribesATurnAndABargeIn.
            \(observation.diagnosticSummary)
            """)

        // The converse-loop post-condition. The tenth effect-not-reference check, and the one
        // that pins the converse loop's **default work** (G7): the `ConverseLoopDriver` driven
        // over the fallback implementations only — `EnergyVAD` + `SilenceThresholdDetector`,
        // the probe's ASR double, a recording probe cleanup provider, the shipped minimal
        // reply generator, a probe stub synthesizer and a probe fake playback. No model
        // artifact, no SDK, no network name is reachable; the report's `gated` count is
        // derived from the loop's own counter, the `asrTranscribes` count from the probe
        // engine's ledger and the `cleanupMode` from the recorded context — an effect-not-
        // reference check the verbatim comparison below cannot be weakened to a constant
        // without the guard-the-guard noticing.
        //
        // Deleting the drive removes the line from the probe's output entirely, so the
        // comparison fails against nil rather than quietly covering less.
        XCTAssertEqual(
            try XCTUnwrap(conversePayload(of: observation)),
            Self.expectedConverseLifecycle,
            """
            The probe did not report driving the converse loop's fallback default work.
              expected: \(Self.expectedConverseLifecycle)
              observed: \(conversePayload(of: observation) ?? "no report at all")
            Either VoccaNetworkProbe.exerciseConverseLoop() was not called on the \
            default-configuration path — in which case the converse loop's default work is \
            outside this invariant — or the converse driver no longer behaves as written. Both \
            matter: the report covers the two commits, the two replies, the single barge-in, \
            the gated echo frame, the two ASR transcriptions under `.conversing` and the idle \
            end state — the shape of a complete converse turn with a barge-in and the \
            conversing cleanup mode. Do not fix this by deleting the call, and do not fix it \
            by pasting in whatever the probe now prints — see \
            testTheAssertedConversePostConditionStillDescribesATurnWithAConversingCleanup.
            \(observation.diagnosticSummary)
            """)

        // The context composition's post-condition. The eleventh effect-not-reference check,
        // and the one that pins the C12 composed **default work** (M11, D6): the wiring
        // recipe over the shipped `NullContext` — reads nothing — and the real consent store
        // over a fresh empty temporary directory, so no consents answer and the provider is
        // never reached (the never-read doctrine, M5), the badge fold lands unlit, and the
        // drive made its two resolutions without throwing the kill (the kill is a user
        // action, asserted headlessly). The report's `reads` comes from the drive's own
        // provider double's ledger and `consents` from the store's own answer — effect-not-
        // reference checks the verbatim comparison below cannot be weakened to a constant
        // without the guard-the-guard noticing.
        //
        // Deleting the drive removes the line from the probe's output entirely, so the
        // comparison fails against nil rather than quietly covering less.
        XCTAssertEqual(
            try XCTUnwrap(contextPayload(of: observation)),
            Self.expectedContextLifecycle,
            """
            The probe did not report driving the context composition's composed default work.
              expected: \(Self.expectedContextLifecycle)
              observed: \(contextPayload(of: observation) ?? "no report at all")
            Either VoccaNetworkProbe.exerciseContext() was not called on the \
            default-configuration path — in which case the context composition's default work \
            is outside this invariant — or the composed default no longer behaves as written. \
            Both matter: the report covers the NullContext provider, the zero reads under no \
            consent, the store's own empty answer, the unlit fold, the two resolutions and \
            the unthrown kill — the shape of the composed default work (M11). Do not fix this \
            by deleting the call, and do not fix it by pasting in whatever the probe now \
            prints — see testTheAssertedContextPostConditionStillDescribesTheNullContextDefault.
            \(observation.diagnosticSummary)
            """)

        // The audit log's post-condition. The twelfth effect-not-reference check, and the one
        // that pins the `VoccaActions` module's **file I/O** rather than its existence: the real
        // store over a fresh temporary directory, driven through the composed action recipe —
        // the real `AuditActionProvider` armed, the mismatch re-prompted, the real clear run,
        // and the clear's own record read back by a second store. Every field is a fact the
        // drive can only produce by writing and reading real bytes — `reloaded`, `ordinals` and
        // `decisions` come from the second store's own answer, so a drive that constructed a
        // store and discarded it cannot report them.
        //
        // Deleting the drive removes the line from the probe's output entirely, so the
        // comparison fails against nil rather than quietly covering less.
        XCTAssertEqual(
            try XCTUnwrap(actionAuditPayload(of: observation)),
            Self.expectedActionAuditLifecycle,
            """
            The probe did not report driving the action audit log's composed default work.
              expected: \(Self.expectedActionAuditLifecycle)
              observed: \(actionAuditPayload(of: observation) ?? "no report at all")
            Either VoccaNetworkProbe.exerciseActionAudit() was not called on the \
            default-configuration path — in which case VoccaActions' file I/O is outside this \
            invariant, and a module that writes files is exactly what this invariant exists to \
            watch — or the composed recipe no longer behaves as written. Do not fix this by \
            deleting the call, and do not fix it by pasting in whatever the probe now prints — \
            see testTheAssertedActionAuditPostConditionStillDescribesARoundTripThroughRealBytes.
            \(observation.diagnosticSummary)
            """)

        // The MCP protocol layer's post-condition. The thirteenth effect-not-reference check, and
        // the second one aimed at `VoccaActions` — deliberately, because the module coverage entry
        // is already satisfied by the audit drive and therefore says nothing about this half of
        // the module. Every field is an effect of a conversation that ran: `methods` is read off
        // the transport's own record of what left, `tools` and `readOnlyTools` off what the parser
        // made of the peer's frames, and `called` off the text the tool answered with — none of
        // which a drive that constructed a session and discarded it could report.
        //
        // `unannotatedIsReadOnly=false` is the fail-safe default observed in a live process: the
        // scripted peer offers a tool with no annotations, and absent means unsafe.
        XCTAssertEqual(
            try XCTUnwrap(mcpPayload(of: observation)),
            Self.expectedMCPLifecycle,
            """
            The probe did not report driving a whole MCP conversation.
              expected: \(Self.expectedMCPLifecycle)
              observed: \(mcpPayload(of: observation) ?? "no report at all")
            Either VoccaNetworkProbe.exerciseMCPSession() was not called on the \
            default-configuration path — in which case the MCP protocol layer is outside this \
            invariant — or the layer no longer behaves as written. Do not fix this by deleting \
            the call, and do not fix it by pasting in whatever the probe now prints — see \
            testTheAssertedMCPPostConditionStillDescribesANegotiatedConversation. Note what this \
            line does NOT cover: a stdio transport is deviation D2 and is invisible to this \
            interposer, which is why ActionTransportProhibitionTests exists.
            \(observation.diagnosticSummary)
            """)

        // The intent voice round trip's post-condition. The fourteenth effect-not-reference
        // check, and the one that pins the voice path's round trip — the `intent-layer` slice's
        // own half of the invariant: the composed intent recipe over real temp-directory stores
        // and a call-logged probe provider, utterance → resolve → gate → card → the existing
        // confirm closure → the provider's `invoke` counted exactly once → the audit row
        // reconstructing. Every field is a fact the drive can only produce by running the round
        // trip: `invoked` is the provider's own call log, `decisions` and `ordinals` come from
        // the second store's own answer, and `binding` compares the confirmed entry's summary
        // with the card's shown sentence.
        //
        // Deleting the drive removes the line from the probe's output entirely, so the
        // comparison fails against nil rather than quietly covering less.
        XCTAssertEqual(
            try XCTUnwrap(intentPayload(of: observation)),
            Self.expectedIntentLifecycle,
            """
            The probe did not report driving the intent voice round trip.
              expected: \(Self.expectedIntentLifecycle)
              observed: \(intentPayload(of: observation) ?? "no report at all")
            Either VoccaNetworkProbe.exerciseIntent() was not called on the \
            default-configuration path — in which case the intent voice path is outside this \
            invariant — or the composed recipe no longer behaves as written. Do not fix this by \
            deleting the call, and do not fix it by pasting in whatever the probe now prints — \
            see testTheAssertedIntentPostConditionStillDescribesAVoiceRoundTripThroughTheRecipe.
            \(observation.diagnosticSummary)
            """)

        // The composed default's intent facts. The fifteenth effect-not-reference check, and the
        // one that pins the R7 unwired posture as an effect rather than a comment: the composed
        // root's resolver is the shipped `NullIntentResolver` (derived from the slot's own
        // dynamic type), one resolution through the composed wiring resolves nothing
        // (`intentResolved=0`, sitting next to the counted `resolves=1` so the zero is an
        // effect, not an absence), and the composed intent wiring declares `spawnsSubprocess=false`
        // — the D2 narrowed promise extended to the voice leg.
        XCTAssertEqual(
            try XCTUnwrap(intentDefaultPayload(of: observation)),
            Self.expectedIntentDefaultLifecycle,
            """
            The probe did not report the composed intent default's facts.
              expected: \(Self.expectedIntentDefaultLifecycle)
              observed: \(intentDefaultPayload(of: observation) ?? "no report at all")
            Either VoccaNetworkProbe.exerciseIntent() was not called on the \
            default-configuration path — in which case the composed intent wiring is outside \
            this invariant — or the composed default no longer resolves nothing and spawns \
            nothing. Do not fix this by deleting the call, and do not fix it by pasting in \
            whatever the probe now prints — see \
            testTheAssertedIntentDefaultPostConditionStillDescribesTheComposedDefault.
            \(observation.diagnosticSummary)
            """)

        // The composed shell drive's post-condition. The sixteenth effect-not-reference check,
        // and the one that pins the `shell-provider` slice's own half of the invariant: the
        // composed default's facts (`commands=0`, `spawnsSubprocess=false` — read off a wiring
        // composed over an absent registry) and the seeded round trip over a benign real
        // `/bin/echo` child — arm → the argv-derived card sentence → confirm → the real engine
        // runs → the audit reconstructs off the disk (the arm's refused stop, the confirmed run,
        // the dry-run row that never invoked). Every field is a fact the drive can only produce
        // by running the round trip: `invoked` is the engine's own call log, `decisions` and
        // `ordinals` come from the second store's own answer, and `binding` compares the
        // confirmed entry's summary with the card's shown sentence.
        //
        // Deleting the drive removes the line from the probe's output entirely, so the
        // comparison fails against nil rather than quietly covering less.
        XCTAssertEqual(
            try XCTUnwrap(shellPayload(of: observation)),
            Self.expectedShellLifecycle,
            """
            The probe did not report driving the composed shell configuration.
              expected: \(Self.expectedShellLifecycle)
              observed: \(shellPayload(of: observation) ?? "no report at all")
            Either VoccaNetworkProbe.exerciseShell() was not called on the \
            default-configuration path — in which case the shell composition's round trip is \
            outside this invariant, and the slice's one route to a real child is exactly what \
            this invariant exists to watch — or the composed default no longer reads zero \
            commands and declares no spawn, or the seeded round trip no longer reconstructs. Do \
            not fix this by deleting the call, and do not fix it by pasting in whatever the \
            probe now prints — see \
            testTheAssertedShellPostConditionStillDescribesTheComposedDefaultAndARoundTripThroughRealBytes. \
            Note what this line does NOT cover: the spawned child itself is invisible to this \
            interposer (D2) — the line proves the default cannot spawn, never that an enabled \
            command cannot egress.
            \(observation.diagnosticSummary)
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

    // MARK: - Test B2: the streaming invariant

    /// Asserts the widget-streaming wiring makes zero network calls too.
    ///
    /// The streaming route is the same default-configuration story told one level further:
    /// `routeStreaming` adds no network name (the `CoreBoundaryTests` rule — no
    /// Foundation/Dispatch/Darwin in `VoccaCore`), and the fold the partials land in is the
    /// widget store's own, so a probe that drives the streaming cycle end to end must observe
    /// exactly what the batch cycle does: nothing.
    ///
    /// It shares the batch cycle's ``runProbe`` machinery — same binary, same interposer — and
    /// asserts the same two zeroes plus the streaming post-condition, so the invariant now
    /// covers both routes through the composed root.
    func testStreamingCycleDeliversPartialsToTheWidgetStoreWithZeroNetworkCalls() throws {
        let observation = try runProbe(mode: .streamingCycle)

        XCTAssertEqual(
            observation.networkConnectionCount, 0,
            """
            The widget-streaming wiring must make zero network calls. The probe contacted:
            \(observation.networkConnectionDescriptions.joined(separator: "\n"))
            Fix the code. Do not weaken this test.
            \(observation.diagnosticSummary)
            """)

        XCTAssertEqual(
            observation.nameResolutionCount, 0,
            """
            The widget-streaming wiring must resolve no hostnames. The probe resolved:
            \(observation.nameResolutionDescriptions.joined(separator: "\n"))
            \(observation.diagnosticSummary)
            """)

        // The streaming-cycle post-condition. The sixth effect-not-reference check: the
        // `widget-streaming` wiring stopped being a promise and became a probe-driven fact —
        // the partial sink folded into the widget store, exercised end to end. Deleting the
        // drive removes this line from the output entirely, so the comparison fails against
        // `nil` rather than quietly covering less.
        XCTAssertEqual(
            observation.reportedStreamingCycle, Self.expectedStreamingCycleLifecycle,
            """
            The probe did not report driving a streaming dictation cycle through the composed \
            root.
              expected: \(Self.expectedStreamingCycleLifecycle)
              observed: \(observation.reportedStreamingCycle ?? "no report at all")
            Either VoccaNetworkProbe.exerciseStreamingCycle() was not called in the \
            streaming-cycle mode — in which case the sink→store wiring is outside this \
            invariant — or the streaming route no longer behaves as written. Both matter, and \
            the second more: the fields cover the widget-store fold (partials reached the \
            store and the store carries the newest), the injection (the cleaned final through \
            a real rung), and the surfaces that must stay quiet (never prepared, never \
            transcribed through the batch call, no download, no hold, exactly one record).
            Do not fix this by deleting the call, and do not fix it by pasting in whatever the \
            probe now prints — see \
            testTheAssertedStreamingCyclePostConditionStillDescribesAStreamingCycle.
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

        // The strategy memory was consulted and had nothing — the fresh-install path. A
        // constant that dropped this field would stop witnessing that the shipped ladder is the
        // memory-backed one at all, and one that claimed a *loaded* memory would mean the probe
        // is reading a strategies file from somewhere: on a developer's machine, plausibly the
        // founder's own.
        XCTAssertEqual(
            try value("strategy"), "absent",
            "The asserted full-cycle post-condition no longer runs the strategy memory over an "
            + "absent file — the default configuration is a fresh install, which has no "
            + "strategies.json, and a probe that found one is reading a file it does not own.")
    }

    // MARK: - Test F: the streaming post-condition is still worth asserting

    /// **Guards the guard.** ``expectedStreamingCycleLifecycle`` must keep describing a
    /// streaming dictation cycle — partials folded into the widget store, the cleaned final
    /// delivered through a real rung, the stream consumed rather than the batch call, and every
    /// quiet surface quiet — the same protection the other guard-the-guard tests give their
    /// constants, for the same reason: a constant that appears in a failing diff gets
    /// regenerated, and regenerating `expectedStreamingCycleLifecycle` to whatever the probe
    /// now prints is the realistic way this gate rots.
    ///
    /// It costs no probe run: the constant is what is under test, not the process.
    func testTheAssertedStreamingCyclePostConditionStillDescribesAStreamingCycle() throws {
        let fields = try Self.parseFields(of: Self.expectedStreamingCycleLifecycle)

        func value(_ key: String) throws -> String {
            guard let found = fields[key] else {
                throw ZeroNetworkTestError.postConditionMissingField(
                    key: key, present: fields.keys.sorted())
            }
            return found
        }

        // The route delivered and came to rest: `.idle` is the delivered final's answer — the
        // DELIVERED fold is the projection's, and a `reasonOnly` or `transcriptHeld` here would
        // be a cycle that never delivered through a rung.
        XCTAssertEqual(
            try value("surface"), "idle",
            "The asserted streaming post-condition no longer ends the route idle.")

        // Partials reached the store — both halves: the count witnesses that each partial
        // reached the wiring, and the carried text witnesses the fold itself. A `partials=0` or
        // an empty `partial.last` would be a sink that never folded, wearing a green suite.
        let partialCount = Int(try value("partials")) ?? 0
        XCTAssertGreaterThanOrEqual(
            partialCount, 1,
            "The asserted streaming post-condition never presents a partial to the sink.")
        let lastPartial = try value("partial.last")
        XCTAssertFalse(
            lastPartial.isEmpty || lastPartial == "none",
            "The asserted streaming post-condition carries no partial text in the widget store.")

        // The final reached the injector through a real rung, with the trace to match —
        // `widgetFailsafe` here would mean the drive's one claimed delivery never happened.
        let injected = try value("injected")
        XCTAssertFalse(
            injected.isEmpty,
            "The asserted streaming post-condition's cleaned final never reached the injector.")
        let rung = try value("rung")
        XCTAssertNotEqual(
            rung, "widgetFailsafe",
            "The asserted streaming post-condition's cycle never delivered — it ended in the "
                + "widget failsafe, so the happy path is not being asserted at all.")
        XCTAssertTrue(
            try value("attempted").split(separator: ",").contains(Substring(rung)),
            "The asserted streaming post-condition did not record the rung it claims won in its "
                + "attempted trace.")

        // The streaming engine's ledgers: never prepared — preparation is the launch path's job
        // (the warm-start aspect's pin) — and never asked to transcribe, which is the fact that
        // the route consumed `stream()`. A non-zero `transcribes` would be a drive that fell
        // back to the batch call, asserting nothing about the streaming route.
        XCTAssertEqual(
            try value("engine.prepares"), "0",
            "The asserted streaming post-condition tolerates a prepare on the streaming path — "
                + "preparation is the launch path's job, and the engine's prepareCount must stay "
                + "observable at zero.")
        XCTAssertEqual(
            try value("engine.transcribes"), "0",
            "The asserted streaming post-condition tolerates the batch transcribe call on the "
                + "streaming path — the route must consume stream(), not fall back.")

        // The quiet surfaces: nothing held and no download started — each a separate way the
        // constant could stop describing the happy path while still looking like one.
        XCTAssertEqual(
            try value("holds"), "0",
            "The asserted streaming post-condition tolerates a held transcript on the happy path.")
        XCTAssertEqual(
            try value("download.starts"), "0",
            "The asserted streaming post-condition tolerates a model download starting during "
                + "the probe run.")

        // The latency ledger closed exactly one record: the streaming route's own finalize row.
        XCTAssertEqual(
            try value("records"), "1",
            "The asserted streaming post-condition does not close exactly one latency record.")
    }

    // MARK: - Test G: the usage post-condition is still worth asserting

    /// **Guards the guard.** ``expectedUsageLedgerLifecycle`` must keep describing a real
    /// launch-shaped round trip — a first-run load, a fold that touched no file, a termination
    /// write and a reload of the committed bytes — and must keep pinning the directory the drive
    /// wrote to.
    ///
    /// The same protection the other guard-the-guard tests give their constants, and here it
    /// defends two separate things. The first is the usual one: a constant that appears in a
    /// failing diff gets regenerated, and regenerating this one to whatever the probe now prints
    /// is the realistic way the discharged debt quietly comes back. The second is the founder's
    /// own machine — a drive that stopped writing to a temporary directory would fold every probe
    /// run into a real install's `~/Library/Application Support/Vocca/usage.json`, and the only
    /// thing standing between that and a green suite is the pair of location fields below.
    ///
    /// It costs no probe run: the constant is what is under test, not the process.
    func testTheAssertedUsagePostConditionStillDescribesALoadAndARoundTrip() throws {
        let fields = try Self.parseFields(of: Self.expectedUsageLedgerLifecycle)

        func value(_ key: String) throws -> String {
            guard let found = fields[key] else {
                throw ZeroNetworkTestError.postConditionMissingField(
                    key: key, present: fields.keys.sorted())
            }
            return found
        }

        // Where the drive wrote. Both halves, because either alone can be satisfied by a mistake:
        // "temporary" alone would pass for a default location that happened to be reported wrong,
        // and "not the default" alone would pass for any directory anywhere on the disk.
        XCTAssertEqual(
            try value("store.location"), "temporary",
            "The asserted usage post-condition no longer requires the probe's store to live under "
                + "the temporary directory — which is the only thing keeping a probe run out of a "
                + "real install's usage history.")
        XCTAssertEqual(
            try value("store.isDefaultLocation"), "false",
            "The asserted usage post-condition tolerates a drive built over "
                + "PersistentUsageStore()'s default location — the founder's own "
                + "~/Library/Application Support/Vocca. Do not relax this field.")

        // The first-run load: no file, and the empty window the store answers for one. A
        // `file.beforeLoad=present` would mean the drive is reading somebody else's bytes, and a
        // non-zero `load.days` would mean the load it claims to exercise was never a first run.
        XCTAssertEqual(
            try value("file.beforeLoad"), "absent",
            "The asserted usage post-condition starts against an existing file, so the load it "
                + "claims to exercise is not a first run.")
        XCTAssertEqual(
            try value("load.days"), "0",
            "The asserted usage post-condition's first-run load does not answer the empty window.")

        // The seam the composition installs: the ledger finalized, and its sink delivered. A
        // `finalized=false` is a refused finalize, which delivers nothing and folds nothing.
        XCTAssertEqual(
            try value("finalized"), "true",
            "The asserted usage post-condition's record was never finalized, so the sink it "
                + "claims to exercise carried nothing.")
        XCTAssertGreaterThanOrEqual(
            Int(try value("sink.records")) ?? 0, 1,
            "The asserted usage post-condition never has the LatencyLedger sink deliver a record.")

        // The fold, and the silence that must come with it — the probe's own echo of D3. A
        // `file.afterFold=present` would be a write inside the dictation path, which is the one
        // thing the write cadence exists to prevent.
        XCTAssertGreaterThanOrEqual(
            Int(try value("fold.sessions")) ?? 0, 1,
            "The asserted usage post-condition's record never reached a day aggregate.")
        XCTAssertEqual(
            try value("file.afterFold"), "absent",
            "The asserted usage post-condition tolerates a file appearing on the fold. Folding is "
                + "in-memory and O(1); a write there is on the dictation path the P2 latency gate "
                + "reads.")

        // Termination wrote, and the bytes came back. Without both, the "real load" this drive
        // exists to perform is a load of nothing.
        XCTAssertEqual(
            try value("file.afterFlush"), "present",
            "The asserted usage post-condition never commits the window, so the reload below "
                + "reads no bytes the drive wrote.")
        XCTAssertEqual(
            try value("reload.days"), "1",
            "The asserted usage post-condition's second store loads no day back.")
        XCTAssertEqual(
            try value("reload.sessions"), "1",
            "The asserted usage post-condition's round trip loses the session it wrote.")
        XCTAssertEqual(
            try value("reload.delivered"), "1",
            "The asserted usage post-condition's round trip loses the outcome class it wrote.")
        XCTAssertEqual(
            try value("reload.clipboardPaste"), "1",
            "The asserted usage post-condition's round trip loses the delivering rung it wrote.")
        XCTAssertEqual(
            try value("reload.dayMatchesProvider"), "true",
            "The asserted usage post-condition tolerates a session filed under a day the calendar "
                + "provider did not name.")
    }

    /// **Guards the guard.** ``expectedTurnLoopLifecycle`` must keep describing a turn with a
    /// barge-in: ≥1 commit, ≥1 barge-in, ≥1 gated echo frame, and an idle end state. A
    /// weakened constant (say, `turnCommits=0 bargeIns=0 gated=0`) that still satisfies the
    /// verbatim comparison above would read green while the loop's default work says nothing
    /// — the same protection the other guard-the-guard tests give their constants.
    func testTheAssertedTurnPostConditionStillDescribesATurnAndABargeIn() throws {
        let fields = try Self.parseFields(of: Self.expectedTurnLoopLifecycle)

        func value(_ key: String) throws -> String {
            guard let found = fields[key] else {
                throw ZeroNetworkTestError.postConditionMissingField(
                    key: key, present: fields.keys.sorted())
            }
            return found
        }

        XCTAssertGreaterThanOrEqual(
            Int(try value("turnCommits")) ?? 0, 1,
            "The asserted turn post-condition no longer requires a committed turn — the loop "
                + "could be reporting a session that never committed.")
        XCTAssertGreaterThanOrEqual(
            Int(try value("bargeIns")) ?? 0, 1,
            "The asserted turn post-condition no longer requires a barge-in — the loop could be "
                + "reporting a session with no interruption, which is not the default work the "
                + "probe exists to pin.")
        XCTAssertGreaterThanOrEqual(
            Int(try value("gated")) ?? 0, 1,
            "The asserted turn post-condition no longer requires the echo gate to discard a "
                + "frame — the loop could be reporting a session where the reply never fed the "
                + "reference back.")
        XCTAssertEqual(
            try value("state"), "idle",
            "The asserted turn post-condition does not end idle — the loop's default work must "
                + "leave the machine stopped.")
        XCTAssertGreaterThanOrEqual(
            Int(try value("fed")) ?? 0, 1,
            "The asserted turn post-condition fed nothing — a session with no frames proves "
                + "nothing about the loop.")
    }

    /// **Guards the guard.** ``expectedConverseLifecycle`` must keep describing a converse turn
    /// with a barge-in and the conversing cleanup mode: ≥1 commit, ≥1 barge-in, ≥1 gated echo
    /// frame, `cleanupMode == conversing`, ≥1 ASR transcription, and an idle end state. A
    /// weakened constant (say, `turnCommits=0 bargeIns=0 cleanupMode=dictation`) that still
    /// satisfies the verbatim comparison above would read green while the converse loop's
    /// default work says nothing — the same protection the other guard-the-guard tests give
    /// their constants.
    func testTheAssertedConversePostConditionStillDescribesATurnWithAConversingCleanup() throws {
        let fields = try Self.parseFields(of: Self.expectedConverseLifecycle)

        func value(_ key: String) throws -> String {
            guard let found = fields[key] else {
                throw ZeroNetworkTestError.postConditionMissingField(
                    key: key, present: fields.keys.sorted())
            }
            return found
        }

        XCTAssertGreaterThanOrEqual(
            Int(try value("turnCommits")) ?? 0, 1,
            "The asserted converse post-condition no longer requires a committed turn — the "
                + "converse loop could be reporting a session that never committed.")
        XCTAssertGreaterThanOrEqual(
            Int(try value("bargeIns")) ?? 0, 1,
            "The asserted converse post-condition no longer requires a barge-in — the converse "
                + "loop could be reporting a session with no interruption, which is not the "
                + "default work the probe exists to pin.")
        XCTAssertGreaterThanOrEqual(
            Int(try value("gated")) ?? 0, 1,
            "The asserted converse post-condition no longer requires the echo gate to discard "
                + "a frame — the converse loop could be reporting a session where the reply "
                + "never fed the reference back.")
        XCTAssertEqual(
            try value("cleanupMode"), "conversing",
            "The asserted converse post-condition no longer cleans under `.conversing` — the "
                + "converse path could be reaching the dictation cleanup.")
        XCTAssertGreaterThanOrEqual(
            Int(try value("asrTranscribes")) ?? 0, 1,
            "The asserted converse post-condition transcribed nothing — a conversation with no "
                + "ASR proves nothing about the converse loop.")
        XCTAssertEqual(
            try value("state"), "idle",
            "The asserted converse post-condition does not end idle — the converse loop's "
                + "default work must leave the machine stopped.")
        XCTAssertEqual(
            try value("started"), "1",
            "The asserted converse post-condition no longer reports exactly one start — the "
                + "converse loop must begin its session once.")
    }

    /// **Guards the guard.** ``expectedContextLifecycle`` must keep describing the composed
    /// context **default work**: the shipped `AccessibilityContext` provider (never any other
    /// — the wiring-close pin; the type name is the one thing the report's `provider` field
    /// derives from, so a reverted `NullContext` composition flips it), zero provider reads
    /// under no consent (M5's never-read doctrine), the store's own zero consents, ≥1
    /// resolution (a drive that resolved nothing proves nothing), and the unthrown kill (a
    /// revoke would explain away the zero reads). A weakened constant (say, `reads=0`
    /// dropped, or `provider=other`) that still satisfies the verbatim comparison above would
    /// read green while the composed default said nothing — the same protection the other
    /// guard-the-guard tests give their constants.
    func testTheAssertedContextPostConditionStillDescribesTheShippedAccessibilityContextDefault() throws {
        let fields = try Self.parseFields(of: Self.expectedContextLifecycle)

        func value(_ key: String) throws -> String {
            guard let found = fields[key] else {
                throw ZeroNetworkTestError.postConditionMissingField(
                    key: key, present: fields.keys.sorted())
            }
            return found
        }

        XCTAssertEqual(
            try value("provider"), "real",
            "The asserted context post-condition no longer names the shipped AccessibilityContext "
                + "composed default — the wiring-close pin could be describing any provider, "
                + "including the reads-nothing NullContext the close removed.")
        XCTAssertEqual(
            Int(try value("reads")) ?? -1, 0,
            "The asserted context post-condition no longer requires zero provider reads under "
                + "no consent — the never-read doctrine (M5) could be silently dropped.")
        XCTAssertEqual(
            Int(try value("consents")) ?? -1, 0,
            "The asserted context post-condition no longer requires the store's empty answer — "
                + "the drive could be reporting a store it seeded.")
        XCTAssertGreaterThanOrEqual(
            Int(try value("resolves")) ?? 0, 1,
            "The asserted context post-condition resolved nothing — a drive that never "
                + "composed a default answer proves nothing about the wiring.")
        XCTAssertEqual(
            try value("revoke"), "no",
            "The asserted context post-condition no longer requires the unthrown kill — the "
                + "default work could be reporting reads that stopped because of a revoke.")
    }

    /// **Guards the guard.** ``expectedActionAuditLifecycle`` must keep describing **the composed
    /// recipe's round trip through real bytes**: the real store (not some in-memory stand-in),
    /// the composed default's facts (`servers=0`, `spawnsSubprocess=false` — the D2 narrowed
    /// promise as a reported line), the binding-mismatch re-prompt observed rather than assumed,
    /// the confirmed entry reconstructing off the disk, and the directory left clear.
    ///
    /// The wiring aspect re-derived this guard because the round trip's shape changed: the drive
    /// now runs the composed recipe, and the real `audit.clear` **removes** the entries it runs
    /// over — so the old `reloaded == recorded` equality is gone on purpose (the peak `recorded`
    /// is what the clear ran over; the survivor is the clear's own record). The weight moved to
    /// the fields that cannot weaken:
    ///
    /// - `reloaded` — exactly one entry must reconstruct: the clear's own record, the R8
    ///   reconstruct. A constant with `reloaded=0` would still satisfy the verbatim comparison
    ///   while proving the store can be called, never that real bytes reached a real directory.
    /// - `decisions` — exactly `confirmed`: the invoked action survives the file with the R8
    ///   distinction intact. A constant that read `refused,confirmed` would mean the clear never
    ///   ran over the earlier decisions, or that the mismatch leg never happened.
    /// - `mismatch` — `reprompted`: the binding actually refused once, and the wiring re-prompted
    ///   rather than dead-ending. A constant that dropped it would pass while the N2 binding's
    ///   refusal path was gone.
    /// - `binding` — `matched`: the final confirm carried the re-prompted card's shown sentence
    ///   and reached the provider. A drive that granted without the shown sentence — the N2
    ///   binding absent from the one path that proves it reaches no network name — would lose
    ///   this field and keep every other.
    /// - `servers` / `spawnsSubprocess` — the composed default's facts. A constant weakened to
    ///   `servers=1` or `spawnsSubprocess=true` would pass the verbatim comparison while the D2
    ///   narrowed promise — the thing the zero-network line exists to prove about the default —
    ///   was gone.
    func testTheAssertedActionAuditPostConditionStillDescribesARoundTripThroughRealBytes() throws {
        let fields = try Self.parseFields(of: Self.expectedActionAuditLifecycle)

        func value(_ key: String) throws -> String {
            guard let found = fields[key] else {
                throw ZeroNetworkTestError.postConditionMissingField(
                    key: key, present: fields.keys.sorted())
            }
            return found
        }

        XCTAssertEqual(
            try value("store"), "real",
            "The asserted audit post-condition no longer names the real store — the drive could "
                + "be reporting a test double, which would put none of VoccaActions inside this "
                + "invariant.")
        let recorded = Int(try value("recorded")) ?? 0
        XCTAssertGreaterThanOrEqual(
            recorded, 1,
            "The asserted audit post-condition recorded nothing — a store that wrote no entry "
                + "proves nothing about the module's file I/O.")
        XCTAssertEqual(
            Int(try value("reloaded")) ?? -1, 1,
            "The asserted audit post-condition no longer requires exactly one entry to "
                + "reconstruct — the clear's own record. More than one means the real clear never "
                + "ran over the earlier decisions; zero means the round trip covered nothing.")
        XCTAssertEqual(
            try value("ordinals"), "1-1",
            "The asserted audit post-condition no longer carries the rebuilt ordinals — the "
                + "single surviving entry, read off the directory rather than off any counter.")
        XCTAssertEqual(
            try value("decisions"), "confirmed",
            "The asserted audit post-condition no longer requires exactly the confirmed decision "
                + "to survive the file. The refused and declined decisions were what the real "
                + "clear ran over — a constant that kept them means the clear never ran.")
        XCTAssertEqual(
            try value("binding"), "matched",
            "The asserted audit post-condition no longer carries the wiring's matched binding. "
                + "The drive could be granting without the shown sentence — the N2 binding absent "
                + "from the one path that proves it reaches no network name — and this line would "
                + "not notice.")
        XCTAssertEqual(
            try value("mismatch"), "reprompted",
            "The asserted audit post-condition no longer requires the observed re-prompt — a "
                + "constant that dropped the mismatch leg would pass while the binding's refusal "
                + "path was gone, and the refusal is the N2 narrowing working in a live process.")
        XCTAssertEqual(
            try value("servers"), "0",
            "The asserted audit post-condition no longer requires the composed default's zero "
                + "servers — the D2 narrowed promise could silently gain a configured server "
                + "while this line watched nothing.")
        XCTAssertEqual(
            try value("spawnsSubprocess"), "false",
            "The asserted audit post-condition no longer requires the composed default's "
                + "no-spawn fact — a composition that wired a transport would declare it here, "
                + "and the zero-network line would still be green if nothing read the fact.")
        XCTAssertEqual(
            Int(try value("cleared")) ?? -1, 0,
            "The asserted audit post-condition no longer requires the cleared directory — the "
                + "drive would be leaving its entries on the machine that ran it.")
        XCTAssertEqual(
            try value("store.location"), "temporary",
            "The asserted audit post-condition no longer requires the temporary directory — a "
                + "probe run must never write an audit entry where a real install keeps its own.")
        XCTAssertEqual(
            try value("store.isDefaultLocation"), "false",
            "The asserted audit post-condition no longer refuses the shipped location. Without "
                + "this the drive could point at ~/Library/Application Support/Vocca/actions and "
                + "fold probe entries into the founder's real audit log.")
    }

    /// **Guards the guard.** ``expectedMCPLifecycle`` must keep describing a **whole negotiated
    /// conversation**: the shipped in-memory transport (not some other stand-in), a successful
    /// negotiation, all three methods actually sent in order, at least two tools discovered, at
    /// least one of them claiming read-only, and the call answered.
    ///
    /// Two fields carry the weight, for different reasons.
    ///
    /// `methods` is the effect field: it is read off the transport's own record of what left, so
    /// a constant that dropped it — or that kept only `initialize` — would still satisfy the
    /// verbatim comparison above while the drive proved that a session can be constructed. The
    /// three names in order are the conversation.
    ///
    /// `unannotatedIsReadOnly` is the **fail-safe default**, and the assertion is deliberately
    /// three-sided: it must be present, it must not be the `none` the drive reports when the
    /// scripted peer stopped offering an unannotated tool (which would leave the field watching
    /// nothing), and it must be `false`. A constant weakened to `true` here would mean a tool
    /// that claimed nothing was being treated as safe — absent read as a claim, which is the
    /// cheapest way to defeat the action safety spine, and the one thing this line exists to
    /// notice in a live process.
    func testTheAssertedMCPPostConditionStillDescribesANegotiatedConversation() throws {
        let fields = try Self.parseFields(of: Self.expectedMCPLifecycle)

        func value(_ key: String) throws -> String {
            guard let found = fields[key] else {
                throw ZeroNetworkTestError.postConditionMissingField(
                    key: key, present: fields.keys.sorted())
            }
            return found
        }

        XCTAssertEqual(
            try value("transport"), "in-memory",
            "The asserted MCP post-condition no longer names the shipped InMemoryMCPTransport — "
                + "the drive could be reporting some other stand-in, which would put none of the "
                + "shipped transport inside this invariant.")
        XCTAssertEqual(
            try value("negotiated"), "yes",
            "The asserted MCP post-condition no longer requires a successful negotiation. A "
                + "refused one would make every later field empty by design, and the drive would "
                + "be reporting the fail-safe rather than the protocol layer.")
        XCTAssertEqual(
            try value("methods"), "initialize,tools/list,tools/call",
            """
            The asserted MCP post-condition no longer requires all three methods, in order. That \
            field is read off the transport's own record of what left, so without it the drive \
            proves a session can be constructed, never that a conversation happened.
            """)
        XCTAssertGreaterThanOrEqual(
            Int(try value("requests")) ?? 0, 3,
            "The asserted MCP post-condition sent fewer than three requests — the three methods "
                + "above cannot all have left.")
        XCTAssertGreaterThanOrEqual(
            Int(try value("tools")) ?? 0, 2,
            "The asserted MCP post-condition discovered fewer than two tools. Two is the minimum "
                + "that can carry both an annotated tool and an unannotated one, and without both "
                + "the read-only fields below watch nothing.")
        XCTAssertEqual(
            Int(try value("readOnlyTools")) ?? -1, 1,
            "The asserted MCP post-condition no longer finds exactly one read-only tool — either "
                + "the honoured claim was lost, or the unannotated tool has started being treated "
                + "as read-only, and the two failures must not be able to cancel out.")
        let unannotated = try value("unannotatedIsReadOnly")
        XCTAssertNotEqual(
            unannotated, "none",
            "The asserted MCP post-condition no longer observes a tool that claimed nothing — the "
                + "scripted peer must keep offering one, or this field watches nothing.")
        XCTAssertEqual(
            unannotated, "false",
            """
            The asserted MCP post-condition no longer requires that a tool with NO readOnlyHint \
            is treated as NOT read-only. Absent means unsafe: reading a server's silence as a \
            read-only claim is a de-escalation performed by omission, and it costs a hostile \
            server nothing to omit a field. This is the live-process half of that acceptance.
            """)
        XCTAssertEqual(
            try value("called"), "ok",
            "The asserted MCP post-condition no longer carries the tool's own answer — without it "
                + "the call is known to have been attempted, never to have completed.")
    }

    /// **Guards the guard.** ``expectedIntentLifecycle`` must keep describing **a voice round
    /// trip through the composed intent recipe**: the real store, the resolution's first leg,
    /// the card the gate asked for, the provider's `invoke` counted exactly once, and the audit
    /// row reconstructing off the disk with the N2 binding matched.
    ///
    /// The fields that cannot weaken:
    ///
    /// - `invoked` — exactly `1`: the counted "confirm → invoke exactly once". A constant with
    ///   `invoked=0` would still satisfy the verbatim comparison while the voice path proved the
    ///   gate can be reached, never that a human yes ever ran anything.
    /// - `decisions` — exactly `refused,confirmed`: the withheld stop reconstructs first, the
    ///   confirmed invoke second. A constant that read `refused` alone means the confirm never
    ///   reached the provider; one that read `confirmed` alone means the stop — the recorded
    ///   refusal the round trip is built on — vanished.
    /// - `binding` — `matched`: the confirmed entry's summary is the card's shown sentence, the
    ///   N2 binding live in the one path that proves the voice leg reaches no network name.
    /// - `resolved` — at least `1`: a drive that composed the wiring and confirmed without ever
    ///   resolving an utterance proves nothing about the voice path's first leg.
    func testTheAssertedIntentPostConditionStillDescribesAVoiceRoundTripThroughTheRecipe() throws {
        let fields = try Self.parseFields(of: Self.expectedIntentLifecycle)

        func value(_ key: String) throws -> String {
            guard let found = fields[key] else {
                throw ZeroNetworkTestError.postConditionMissingField(
                    key: key, present: fields.keys.sorted())
            }
            return found
        }

        XCTAssertEqual(
            try value("store"), "real",
            "The asserted intent post-condition no longer names the real store — the drive could "
                + "be reporting a test double, which would put none of the voice path's file I/O "
                + "inside this invariant.")
        XCTAssertEqual(
            Int(try value("resolved")) ?? -1, 1,
            "The asserted intent post-condition no longer requires the resolution's first leg — a "
                + "drive that composed the wiring and confirmed without resolving proves nothing "
                + "about the voice path.")
        XCTAssertEqual(
            try value("card"), "yes",
            "The asserted intent post-condition no longer requires the card — without it the "
                + "drive could be confirming a card that was never presented, and the gate's ask "
                + "leg would be watching nothing.")
        XCTAssertEqual(
            Int(try value("invoked")) ?? -1, 1,
            "The asserted intent post-condition no longer requires the provider's invoke to be "
                + "counted exactly once — a constant with invoked=0 would pass the verbatim "
                + "comparison while no human yes ever ran anything.")
        XCTAssertEqual(
            try value("decisions"), "refused,confirmed",
            "The asserted intent post-condition no longer reconstructs the withheld stop and the "
                + "confirmed invoke, in ordinal order — the refused entry is the round trip's "
                + "recorded foundation, and the confirmed entry is its proof.")
        XCTAssertEqual(
            try value("ordinals"), "1-2",
            "The asserted intent post-condition no longer carries the rebuilt ordinals — read off "
                + "the directory, not off any counter.")
        XCTAssertEqual(
            try value("binding"), "matched",
            "The asserted intent post-condition no longer carries the matched binding — the drive "
                + "could be confirming without the shown sentence, and the N2 binding would be "
                + "absent from the one path that proves it reaches no network name.")
        XCTAssertEqual(
            try value("store.location"), "temporary",
            "The asserted intent post-condition no longer requires the temporary directory — a "
                + "probe run must never write an audit entry where a real install keeps its own.")
        XCTAssertEqual(
            try value("store.isDefaultLocation"), "false",
            "The asserted intent post-condition no longer refuses the shipped location — without "
                + "this the drive could fold probe entries into the founder's real audit log.")
    }

    /// **Guards the guard.** ``expectedIntentDefaultLifecycle`` must keep describing **the
    /// composed default** — the R7 unwired posture as an effect of the composed root, never a
    /// comment and never an absence.
    ///
    /// The fields that cannot weaken:
    ///
    /// - `intentResolved` — must be `0` **and** must sit next to a counted `resolves` of at
    ///   least `1`: a constant that dropped `resolves` would be indistinguishable from a drive
    ///   that never ran, which is exactly the vacuous green this field exists to refuse. A
    ///   composition that wired a resolver (N1's flip) flips `intentResolved` to `1` and the
    ///   guard refuses the flip as a reviewed edit.
    /// - `resolver` — `NullIntentResolver`, derived from the composed root's own slot: a
    ///   composition that wired anything else flips it to `other`/`none`.
    /// - `spawnsSubprocess` — `false`: the D2 narrowed promise extended to the voice leg — a
    ///   composition that declared a spawn would say so here.
    func testTheAssertedIntentDefaultPostConditionStillDescribesTheComposedDefault() throws {
        let fields = try Self.parseFields(of: Self.expectedIntentDefaultLifecycle)

        func value(_ key: String) throws -> String {
            guard let found = fields[key] else {
                throw ZeroNetworkTestError.postConditionMissingField(
                    key: key, present: fields.keys.sorted())
            }
            return found
        }

        XCTAssertEqual(
            try value("resolver"), "NullIntentResolver",
            "The asserted intent default post-condition no longer requires the composed root's "
                + "Null resolver — a composition that wired any other resolver would still pass "
                + "a constant that watched nothing.")
        XCTAssertGreaterThanOrEqual(
            Int(try value("resolves")) ?? 0, 1,
            "The asserted intent default post-condition resolved nothing — intentResolved=0 must "
                + "be distinguishable from 'the drive didn't run', and the counted resolution is "
                + "what distinguishes them.")
        XCTAssertEqual(
            Int(try value("intentResolved")) ?? -1, 0,
            "The asserted intent default post-condition no longer requires the composed default "
                + "to resolve nothing — the R7 unwired posture could be silently flipped (N1) "
                + "while this line watched nothing.")
        XCTAssertEqual(
            try value("spawnsSubprocess"), "false",
            "The asserted intent default post-condition no longer requires the composed intent "
                + "wiring's no-spawn fact — a composition that wired a spawn would declare it "
                + "here, and the zero-network line would still be green if nothing read the fact.")
        XCTAssertEqual(
            Int(try value("intentShellRows")) ?? -1, 0,
            "The asserted intent default post-condition no longer requires the resolver "
                + "catalog to name zero dev.vocca.shell rows — the arm-surface-only decision "
                + "(shell is never composed into the intent seam) could be silently flipped "
                + "while this line watched nothing.")
    }

    /// **Guards the guard.** ``expectedShellLifecycle`` must keep describing **the composed
    /// default and a round trip through real bytes**: the real store, the composed default's
    /// facts (`commands=0`, `spawnsSubprocess=false` — the D2 narrowed promise as a reported
    /// line), the seeded registry, the card the gate asked for, the engine's counted run, and
    /// the audit reconstructing off the disk with the dry-run row and the N2 binding matched.
    ///
    /// The fields that cannot weaken:
    ///
    /// - `commands` — must be `0`: the composed default's fact, read off a wiring composed
    ///   over an absent registry. A constant weakened to `commands=1` would pass the verbatim
    ///   comparison while the D2 narrowed promise — the thing this line exists to prove about
    ///   the default — was gone.
    /// - `spawnsSubprocess` — must be `false`: the wiring's declared fact. A composition that
    ///   wired commands by default would declare it here, and the zero-network line would
    ///   still be green if nothing read the fact.
    /// - `invoked` — exactly `1`: the engine's own call log — the confirm ran the child
    ///   exactly once, and the dry-run row reached it zero times. A constant with `invoked=0`
    ///   would still satisfy the verbatim comparison while no human yes ever ran anything.
    /// - `decisions` — exactly `refused,confirmed,dryRun`: the arm's withheld stop, the
    ///   confirmed run and the dry-run row, in ordinal order. A constant that dropped the
    ///   dry-run row means the rehearsal half of the seam was never driven; one that dropped
    ///   the refused stop means the arm never stopped for want of a yes.
    /// - `binding` — `matched`: the confirmed entry's summary is the card's shown sentence,
    ///   the N2 binding live in the one path that proves the shell leg reaches no network
    ///   name while a real child runs.
    /// - `seeded` — at least `1`: the round trip had a command to arm; a constant that read
    ///   `seeded=0` would be a round trip over an empty registry, which arms nothing.
    func testTheAssertedShellPostConditionStillDescribesTheComposedDefaultAndARoundTripThroughRealBytes()
        throws
    {
        let fields = try Self.parseFields(of: Self.expectedShellLifecycle)

        func value(_ key: String) throws -> String {
            guard let found = fields[key] else {
                throw ZeroNetworkTestError.postConditionMissingField(
                    key: key, present: fields.keys.sorted())
            }
            return found
        }

        XCTAssertEqual(
            try value("store"), "real",
            "The asserted shell post-condition no longer names the real store — the drive could "
                + "be reporting a test double, which would put none of the shell leg's file I/O "
                + "inside this invariant.")
        XCTAssertEqual(
            try value("commands"), "0",
            "The asserted shell post-condition no longer requires the composed default's zero "
                + "commands — an absent registry is the empty registry, and the D2 narrowed "
                + "promise could silently gain a configured command while this line watched "
                + "nothing.")
        XCTAssertEqual(
            try value("spawnsSubprocess"), "false",
            "The asserted shell post-condition no longer requires the composed default's "
                + "no-spawn fact — a composition that wired a spawn would declare it here, "
                + "and the zero-network line would still be green if nothing read the fact.")
        XCTAssertGreaterThanOrEqual(
            Int(try value("seeded")) ?? 0, 1,
            "The asserted shell post-condition seeded nothing — a round trip over an empty "
                + "registry arms nothing, and the drive would prove only that the wiring can be "
                + "constructed.")
        XCTAssertEqual(
            try value("card"), "yes",
            "The asserted shell post-condition no longer requires the card — without it the "
                + "drive could be confirming a card that was never presented, and the gate's ask "
                + "leg would be watching nothing.")
        XCTAssertEqual(
            Int(try value("invoked")) ?? -1, 1,
            "The asserted shell post-condition no longer requires the engine to be reached "
                + "exactly once — a constant with invoked=0 would pass the verbatim comparison "
                + "while no human yes ever ran a child, and one with invoked=2 would mean the "
                + "dry run had invoked.")
        XCTAssertEqual(
            try value("decisions"), "refused,confirmed,dryRun",
            "The asserted shell post-condition no longer reconstructs the arm's stop, the "
                + "confirmed run and the dry-run row, in ordinal order — the refused entry is "
                + "the round trip's recorded foundation, the confirmed entry is its proof, and "
                + "the dry-run row is the rehearsal that never invoked.")
        XCTAssertEqual(
            try value("ordinals"), "1-3",
            "The asserted shell post-condition no longer carries the rebuilt ordinals — read "
                + "off the directory, not off any counter.")
        XCTAssertEqual(
            try value("binding"), "matched",
            "The asserted shell post-condition no longer carries the matched binding — the "
                + "drive could be confirming without the shown sentence, and the N2 binding "
                + "would be absent from the one path that proves the shell leg reaches no "
                + "network name while a real child runs.")
        XCTAssertEqual(
            try value("store.location"), "temporary",
            "The asserted shell post-condition no longer requires the temporary directory — a "
                + "probe run must never write an audit entry where a real install keeps its own.")
        XCTAssertEqual(
            try value("store.isDefaultLocation"), "false",
            "The asserted shell post-condition no longer refuses the shipped location — without "
                + "this the drive could fold probe entries into the founder's real audit log.")
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

    /// The `PROBE-VAD` line's payload — the voice-detection drive's construct report — or `nil`
    /// when the probe never reported one.
    ///
    /// The `PROBE-LATENCY` parser shape: the line exists only when `exerciseVoiceDetection()`
    /// ran on the default-configuration path, so its absence is a missing drive rather than an
    /// empty report. `VoccaASR` is already covered by the cycle's witness, so the module
    /// coverage list alone would not notice a deleted drive — this accessor and its assertion
    /// are the leg's survival guarantee.
    private func vadConstructPayload(of observation: NetworkObservation) -> String? {
        for line in observation.probeStandardOutput.split(separator: "\n")
        where line.hasPrefix("PROBE-VAD\t") {
            return String(line.dropFirst("PROBE-VAD\t".count))
        }
        return nil
    }

    /// The `PROBE-TURN` line's payload — the turn loop drive's fallback-work report — or
    /// `nil` when the probe never reported one.
    ///
    /// The `PROBE-VAD` parser shape: the line exists only when `exerciseTurnLoop()` ran on
    /// the default-configuration path, so its absence is a missing drive rather than an
    /// empty report. `VoccaCore` is already covered by the session's witness, so the module
    /// coverage list alone would not notice a deleted drive — this accessor and its
    /// assertion are the leg's survival guarantee.
    private func turnLoopPayload(of observation: NetworkObservation) -> String? {
        for line in observation.probeStandardOutput.split(separator: "\n")
        where line.hasPrefix("PROBE-TURN\t") {
            return String(line.dropFirst("PROBE-TURN\t".count))
        }
        return nil
    }

    /// The `PROBE-CONVERSE` line's payload — the converse drive's fallback-work report — or
    /// `nil` when the probe never reported one.
    ///
    /// The `PROBE-TURN` parser shape: the line exists only when `exerciseConverseLoop()` ran on
    /// the default-configuration path, so its absence is a missing drive rather than an empty
    /// report. `VoccaBootstrap` is already covered by the driver's witness, so the module
    /// coverage list alone would not notice a deleted drive — this accessor and its assertion
    /// are the leg's survival guarantee.
    private func conversePayload(of observation: NetworkObservation) -> String? {
        for line in observation.probeStandardOutput.split(separator: "\n")
        where line.hasPrefix("PROBE-CONVERSE\t") {
            return String(line.dropFirst("PROBE-CONVERSE\t".count))
        }
        return nil
    }

    /// The `PROBE-CONTEXT` line's payload — the context drive's composed-default-work report
    /// — or `nil` when the probe never reported one.
    ///
    /// The `PROBE-CONVERSE` parser shape: the line exists only when `exerciseContext()` ran on
    /// the default-configuration path, so its absence is a missing drive rather than an empty
    /// report. `VoccaContext` is already covered by the adapter's witness, so the module
    /// coverage list alone would not notice a deleted drive — this accessor and its assertion
    /// are the leg's survival guarantee.
    private func contextPayload(of observation: NetworkObservation) -> String? {
        for line in observation.probeStandardOutput.split(separator: "\n")
        where line.hasPrefix("PROBE-CONTEXT\t") {
            return String(line.dropFirst("PROBE-CONTEXT\t".count))
        }
        return nil
    }

    /// The `PROBE-ACTIONS` line's payload — the audit store's round-trip report — or `nil` when
    /// the probe never reported one.
    ///
    /// The `PROBE-CONTEXT` parser shape: the line exists only when `exerciseActionAudit()` ran on
    /// the default-configuration path, so its absence is a missing drive rather than an empty
    /// report. Unlike its siblings, `VoccaActions` has no other witness at all — the module is
    /// wired into nothing, deliberately — so this accessor and the coverage list are together the
    /// whole of what puts the module inside the invariant.
    private func actionAuditPayload(of observation: NetworkObservation) -> String? {
        for line in observation.probeStandardOutput.split(separator: "\n")
        where line.hasPrefix("PROBE-ACTIONS\t") {
            return String(line.dropFirst("PROBE-ACTIONS\t".count))
        }
        return nil
    }

    /// The `PROBE-MCP` line's payload — the MCP conversation's report — or `nil` when the probe
    /// never reported one.
    ///
    /// The `PROBE-ACTIONS` parser shape, and needed for a sharper reason than its sibling:
    /// `VoccaActions` is covered in the module list by the **audit** drive, so deleting the MCP
    /// drive would leave the coverage cross-check entirely green. This accessor and its assertion
    /// are the whole of what puts the protocol layer inside the invariant.
    private func mcpPayload(of observation: NetworkObservation) -> String? {
        for line in observation.probeStandardOutput.split(separator: "\n")
        where line.hasPrefix("PROBE-MCP\t") {
            return String(line.dropFirst("PROBE-MCP\t".count))
        }
        return nil
    }

    /// The `PROBE-INTENT` line's payload — the intent voice round trip's report — or `nil` when
    /// the probe never reported one.
    ///
    /// The `PROBE-MCP` parser shape: the line exists only when `exerciseIntent()` ran on the
    /// default-configuration path, so its absence is a missing drive rather than an empty
    /// report. `VoccaBootstrap` is already covered by the converse driver's witness, so the
    /// module coverage list alone would not notice a deleted drive — this accessor and its
    /// assertion are the voice round trip's survival guarantee.
    private func intentPayload(of observation: NetworkObservation) -> String? {
        for line in observation.probeStandardOutput.split(separator: "\n")
        where line.hasPrefix("PROBE-INTENT\t") {
            return String(line.dropFirst("PROBE-INTENT\t".count))
        }
        return nil
    }

    /// The `PROBE-INTENT-DEFAULT` line's payload — the composed default's intent facts — or
    /// `nil` when the probe never reported one.
    ///
    /// The `PROBE-INTENT` parser shape, on the sibling line the same drive emits. The prefix is
    /// deliberately longer than `PROBE-INTENT\t`, so the two accessors cannot confuse each
    /// other's lines.
    private func intentDefaultPayload(of observation: NetworkObservation) -> String? {
        for line in observation.probeStandardOutput.split(separator: "\n")
        where line.hasPrefix("PROBE-INTENT-DEFAULT\t") {
            return String(line.dropFirst("PROBE-INTENT-DEFAULT\t".count))
        }
        return nil
    }

    /// The `PROBE-SHELL` line's payload — the composed shell drive's report — or `nil` when
    /// the probe never reported one.
    ///
    /// The `PROBE-INTENT-DEFAULT` parser shape: the line exists only when `exerciseShell()` ran
    /// on the default-configuration path, so its absence is a missing drive rather than an
    /// empty report. `VoccaActions` is already covered by the audit drive's witness, so the
    /// module coverage list alone would not notice a deleted drive — this accessor and its
    /// assertion are the shell leg's survival guarantee.
    private func shellPayload(of observation: NetworkObservation) -> String? {
        for line in observation.probeStandardOutput.split(separator: "\n")
        where line.hasPrefix("PROBE-SHELL\t") {
            return String(line.dropFirst("PROBE-SHELL\t".count))
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
