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
import VoccaBootstrap
import VoccaCore
import VoccaInject
import VoccaUI
import XCTest

/// **The three surfaces never disagree** (`spec.md` R6, PRD M11) — the Speech tab, the menu bar
/// icon and the pill, asserted **together**, out of one composed root.
///
/// ## Why together, and why out of the root
///
/// This repository's dominant bug class is a state that looks like working. Vocca is
/// `LSUIElement`, so for months a dead launch and a live one were the same picture; every defect
/// found in the design pass was silent for that one reason. The same shape recurs wherever a fact
/// has more than one renderer — and after this aspect the engine's condition has three.
///
/// Three separate tests, one per surface, cannot catch it: each would pass while the surfaces said
/// different things about the same instant. So each window below drives **one root** into that
/// state and asserts all three answers in one place. The inputs are not hand-built per surface;
/// they are read off the root that a real launch would produce.
///
/// The pill is included as *what the next press does*, because the pill has no engine state of its
/// own — it renders sessions. "The Speech tab says the model is gone, the menu bar says all is
/// well, and the press silently does nothing" is precisely the window this exists to make
/// impossible.
@MainActor
final class EngineStateAgreementTests: XCTestCase {

    static let configuration = HotkeyConfiguration(
        keyCode: 49, modifiers: [.option], activation: .holdToTalk)
    private static let whisper = EngineSelection(tier: .whisperTurbo)

    // MARK: - Window (a): the model was removed, the selection unchanged

    /// **Window (a).** The user removed the selected engine's model from the Speech tab. Nothing is
    /// downloading, nothing is warming up, and waiting will not help.
    ///
    /// The menu bar case this needs did not exist before this aspect: an unprepared engine read as
    /// ``MenuBarState/downloadingModel``, whose copy is *"Downloading the speech model. Dictation
    /// works as soon as it finishes."* — a promise of a wait that never ends. That reading is
    /// still correct for an engine that never prepared (`MenuBarStateTests` argues it, and that
    /// test is untouched and still passes): there the remedy really is to wait. It is wrong for a
    /// model a user deleted thirty seconds ago, where the remedy is to download it again.
    func testAllThreeSurfacesAgreeAfterTheSelectedModelIsRemoved() async {
        let harness = AgreementHarness()
        harness.root.startEnginePreparation()
        await harness.drain(
            until: { harness.root.menuBarConditions.isEnginePrepared },
            "the launch preload must complete")

        harness.root.engineModelRemoved(tier: .parakeetV3)

        var tab = SpeechTabReducer.reduce(
            .initial, .snapshotLoaded([.init(tier: .parakeetV3, isPresent: false, bytesOnDisk: 0)]))
        tab = SpeechTabReducer.reduce(tab, .engineStatusChanged(harness.root.engineReadinessState))

        harness.press()
        await harness.settle()
        XCTAssertEqual(
            AgreementReport(harness: harness, tab: tab),
            AgreementReport(
                speechTab: .unavailable,
                speechTabBadge: .absent,
                menuBar: .modelMissing,
                // IDLE, not a notice: the FAILSAFE panel already states the honest cause
                // (`.modelUnavailable`), and the widget's own notice reads "The microphone didn't
                // open — try again", which is wrong twice over for a missing model. What the pill
                // must not do is stay in OPENING, which is what it did before this test existed:
                // the widget reducer has no time-based transition in it at all, so a press that
                // was refused left the pill claiming a microphone was opening, for ever.
                pill: .state(.idle),
                microphoneOpened: false),
            """
            the three surfaces disagreed about a model the user just removed. The failure to \
            look for first is a menu bar reporting `downloadingModel` — "works as soon as it \
            finishes" — for a model that nothing is fetching and that will never arrive.
            """)
    }

    // MARK: - Window (b): the selection changed and the new engine is warming

    /// **Window (b).** The user picked the other engine. Its model is on disk, its `prepare()` is
    /// running, and the press in that gap is refused — correctly, because the engine cannot
    /// transcribe yet.
    ///
    /// Nothing is wrong here, and that is the whole point: a surface reporting this the way it
    /// reports a missing model would tell the user their switch broke something.
    func testAllThreeSurfacesAgreeWhileTheNewlySelectedEngineIsWarmingUp() async {
        let gate = GateLatch()
        let harness = AgreementHarness(whisper: LatchedEngine(identity: Self.whisperIdentity, gate: gate))
        harness.root.startEnginePreparation()
        await harness.drain(
            until: { harness.root.menuBarConditions.isEnginePrepared },
            "the launch preload must complete")

        harness.root.setEngineSelection(Self.whisper)
        await harness.settle()

        var tab = SpeechTabReducer.reduce(.initial, .selectEngine(.whisperTurbo))
        tab = SpeechTabReducer.reduce(
            tab, .snapshotLoaded([.init(tier: .whisperTurbo, isPresent: true, bytesOnDisk: 1_600)]))
        tab = SpeechTabReducer.reduce(tab, .engineStatusChanged(harness.root.engineReadinessState))

        harness.press()
        await harness.settle()

        XCTAssertEqual(
            AgreementReport(harness: harness, tab: tab),
            AgreementReport(
                speechTab: .preparing,
                speechTabBadge: .installed,
                menuBar: .preparingEngine,
                pill: .state(.idle),
                microphoneOpened: false),
            """
            the three surfaces disagreed during a warm-up. Every one of them must say "a moment" \
            and none of them may say "something is missing": the model is on disk and the switch \
            worked.
            """)

        await gate.open()
        await harness.drain(
            until: { harness.root.engineReadinessState == .ready },
            "and the warm-up ends by itself")
    }

    // MARK: - Window (c): a download is in flight

    /// **Window (c), the selected tier.** A download for the engine the user is dictating with
    /// blocks dictation, and every surface says so — the tab with a bar, the menu with progress to
    /// open, the press with a refusal.
    func testAllThreeSurfacesAgreeWhileTheSelectedTierIsDownloading() async {
        let harness = AgreementHarness()
        harness.root.engineModelRemoved(tier: .parakeetV3)
        harness.root.engineDownloadChanged(tier: .parakeetV3, isRunning: true)

        var tab = SpeechTabReducer.reduce(
            .initial, .snapshotLoaded([.init(tier: .parakeetV3, isPresent: false, bytesOnDisk: 0)]))
        tab = SpeechTabReducer.reduce(tab, .downloadStarted(.parakeetV3))
        tab = SpeechTabReducer.reduce(tab, .downloadProgress(.parakeetV3, 0.25))
        tab = SpeechTabReducer.reduce(tab, .engineStatusChanged(harness.root.engineReadinessState))

        harness.press()
        await harness.settle()

        XCTAssertEqual(
            AgreementReport(harness: harness, tab: tab),
            AgreementReport(
                speechTab: .downloading(0.25),
                speechTabBadge: .downloading(0.25),
                menuBar: .downloadingModel,
                pill: .state(.idle),
                microphoneOpened: false),
            "a download of the engine in use blocks dictation, and all three surfaces say so")
    }

    /// **Window (c), the *other* tier — the half a naive wiring gets wrong.** A user fetching
    /// Whisper in the background while dictating with Parakeet is not blocked, and nothing may
    /// tell them they are.
    ///
    /// The failure this pins is a menu bar that reports any download at all: `isDownloadingModel`
    /// means "the model dictation is waiting on", and a background fetch of an engine nobody
    /// selected is housekeeping. Getting this wrong turns a working Vocca into one that says
    /// "Dictation works as soon as it finishes" for five minutes while dictation works fine.
    func testABackgroundDownloadOfTheOtherTierBlocksNothingAndSaysSo() async {
        let harness = AgreementHarness()
        harness.root.startEnginePreparation()
        await harness.drain(
            until: { harness.root.menuBarConditions.isEnginePrepared },
            "the launch preload must complete")

        harness.root.engineDownloadChanged(tier: .whisperTurbo, isRunning: true)

        var tab = SpeechTabReducer.reduce(
            .initial,
            .snapshotLoaded([
                .init(tier: .parakeetV3, isPresent: true, bytesOnDisk: 470_000),
                .init(tier: .whisperTurbo, isPresent: false, bytesOnDisk: 0),
            ]))
        tab = SpeechTabReducer.reduce(tab, .downloadStarted(.whisperTurbo))
        tab = SpeechTabReducer.reduce(tab, .downloadProgress(.whisperTurbo, 0.5))
        tab = SpeechTabReducer.reduce(tab, .engineStatusChanged(harness.root.engineReadinessState))

        harness.press()
        await harness.settle()

        XCTAssertEqual(
            AgreementReport(harness: harness, tab: tab),
            AgreementReport(
                speechTab: .ready,
                speechTabBadge: .installed,
                menuBar: .ready,
                pill: .state(.recording),
                microphoneOpened: true),
            """
            a background download of an engine nobody selected must block nothing. If the menu bar \
            reported it, a working Vocca would spend five minutes saying dictation is unavailable \
            while dictation worked.
            """)
        XCTAssertEqual(
            tab.row(for: .whisperTurbo)?.install, .downloading(0.5),
            "and the row still shows the transfer — unblocked is not the same as invisible")
    }

    private static let whisperIdentity = EngineIdentity(
        id: "whisper-large-v3-turbo", displayName: "Whisper turbo", isLocal: true)
}

/// The three surfaces' answers, as one value — so a disagreement fails as one comparison with all
/// three sides printed, rather than as whichever assertion happened to run first.
private struct AgreementReport: Equatable, CustomStringConvertible {
    let speechTab: SpeechTabEngineStatus
    let speechTabBadge: SpeechTabInstall
    let menuBar: MenuBarState
    let pill: WidgetProjectionResult
    let microphoneOpened: Bool

    init(
        speechTab: SpeechTabEngineStatus, speechTabBadge: SpeechTabInstall, menuBar: MenuBarState,
        pill: WidgetProjectionResult, microphoneOpened: Bool
    ) {
        self.speechTab = speechTab
        self.speechTabBadge = speechTabBadge
        self.menuBar = menuBar
        self.pill = pill
        self.microphoneOpened = microphoneOpened
    }

    @MainActor
    init(harness: AgreementHarness, tab: SpeechTabState) {
        self.speechTab = tab.engineStatus
        self.speechTabBadge = tab.row(for: tab.selection.tier)?.install ?? .unknown
        self.menuBar = MenuBarStateReducer.state(for: harness.root.menuBarConditions)
        self.pill = harness.pill
        self.microphoneOpened = harness.source.beginCount > 0
    }

    var description: String {
        """
        Speech tab: \(speechTab) / badge \(speechTabBadge) — menu bar: \(menuBar) — \
        pill: \(pill) — microphone opened: \(microphoneOpened)
        """
    }
}

// MARK: - The composed harness

/// One composed root over fakes — the `EngineSwitchTests.Harness` shape, with the pieces this
/// suite needs to read a surface rather than to drive a switch.
///
/// Composed rather than hand-built because that is the point: the three answers must come from the
/// object a real launch produces, not from three inputs a test invented to agree with each other.
@MainActor
final class AgreementHarness {

    /// The app the ladder is pointed at, so the pill's OPENING name is a fixed, assertable string.
    static let targetAppName = "The Draft"

    let root: DictationLoopRoot
    let source: RecordingAudioSource
    private let keyboard: Keyboard

    init(whisper: (any ASREngine)? = nil) {
        let clock = TestClock()
        let keyboard = Keyboard()
        let source = RecordingAudioSource()
        source.nextSamples = [1, 2, 3]
        let parakeet = StubEngine.parakeet()
        let whisperEngine = whisper ?? StubEngine.whisper()
        let holder = LedgerHolder()

        let makeResolver: @Sendable (EngineSelection) -> DictationEngineResolver = { selection in
            DictationEngineResolver(selection: selection) { selection in
                selection.tier.engine == .parakeetV3 ? parakeet : whisperEngine
            }
        }

        let root = DictationLoopRoot(
            configuration: EngineStateAgreementTests.configuration,
            ceiling: SessionCeiling.default,
            clock: clock,
            audioSource: source,
            keyState: TruthfulKeyState(keyboard),
            watchdogTimer: FakeTimer(),
            healthTimer: FakeTimer(),
            deferOpening: { $0() },
            tap: FakeHotkeyEventSource(),
            secureInput: FakeSecureInputState(),
            resolver: makeResolver(.defaultSelection),
            targetResolution: TargetResolution(
                focusedApp: FakeFocusedApp(
                    identity: FocusedAppIdentity(
                        bundleID: "com.apple.Notes",
                        windowTitle: AgreementHarness.targetAppName)),
                secureInput: FakeSecureInput()),
            panel: RecordingPanel(holder: holder),
            pipelineAssembly: { engine in
                DictationPipeline(
                    engine: engine,
                    injector: LedgerInjector(
                        result: InjectionResult(
                            rung: .clipboardPaste, attempted: [.clipboardPaste], verified: false,
                            elapsed: .zero)),
                    holder: holder)
            },
            makeResolver: makeResolver,
            settings: AgreementSettingsStore(),
            toggleConfiguration: HotkeyConfiguration(
                keyCode: 49, modifiers: [.option], activation: .toggle),
            toggleSource: RecordingAudioSource(),
            toggleTimer: FakeTimer(),
            runningAppName: FakeRunningAppName(),
            widgetClock: FakeTimer(),
            liveLevel: SilentAgreementLevelSource())

        self.root = root
        self.source = source
        self.keyboard = keyboard
    }

    /// Key-down only. The question every window asks is what one press *does*, and a refused press
    /// never reaches a key-up worth sending.
    func press() {
        keyboard.hold(EngineStateAgreementTests.configuration)
        _ = root.holdToTalk.scheduledWatchdog.receive(
            agreementKeyEvent(
                .keyDown, EngineStateAgreementTests.configuration.keyCode, [.option]))
    }

    /// What the pill is showing, as the projection result that produced it — the widget's own
    /// store, read rather than re-derived.
    var pill: WidgetProjectionResult {
        if let notice = root.widgetStore.state.notice { return .notice(notice) }
        return .state(root.widgetStore.state.state)
    }

    /// The `DictationLoopTests` drain.
    func drain(until condition: @escaping () async -> Bool, _ message: String) async {
        var attempts = 0
        while !(await condition()) && attempts < 1_000 {
            await Task.yield()
            attempts += 1
        }
        let held = await condition()
        XCTAssertTrue(held, message)
    }

    /// Yield without asserting — used where the point is that something must *not* have happened.
    func settle() async {
        for _ in 0..<200 { await Task.yield() }
    }
}

/// A settings store that keeps its answers in memory: the persistence is aspects 2–3's business
/// and is tested there.
private final class AgreementSettingsStore: SettingsStore, @unchecked Sendable {
    private var selection = EngineSelection.defaultSelection
    private var activation = HotkeyConfiguration.Activation.holdToTalk
    func engineSelection() -> EngineSelection { selection }
    func setEngineSelection(_ selection: EngineSelection) { self.selection = selection }
    func activationMode() -> HotkeyConfiguration.Activation { activation }
    func setActivationMode(_ activation: HotkeyConfiguration.Activation) {
        self.activation = activation
    }

    // The cloud-cleanup acknowledgement is not what these tests are about, so the double answers
    // the safe direction and remembers a write — `false` means the confirmation is shown, which
    // is never the dangerous answer.
    private var acknowledgedCloud = false

    func hasAcknowledgedCloudCleanup() -> Bool { acknowledgedCloud }

    func setAcknowledgedCloudCleanup(_ acknowledged: Bool) { acknowledgedCloud = acknowledged }

}

/// An engine whose `prepare()` blocks until the test lets it finish — the only way to hold a root
/// inside the warm-up window long enough to read three surfaces out of it.
private actor LatchedEngine: ASREngine {
    nonisolated let identity: EngineIdentity
    nonisolated let supportsStreaming = false
    private let gate: GateLatch

    init(identity: EngineIdentity, gate: GateLatch) {
        self.identity = identity
        self.gate = gate
    }

    func prepare() async throws { await gate.wait() }

    func transcribe(_ buffer: AudioBuffer) async throws -> Transcript {
        Transcript(
            text: "", segments: [], engine: identity, isFinal: true,
            audioDuration: buffer.audioDuration)
    }
}

/// The latch itself: a preparation waits on it until the test opens it.
private actor GateLatch {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }
}

/// A level source that publishes nothing: this suite asserts nothing about the waveform.
private struct SilentAgreementLevelSource: LiveLevelSource {
    func latestLevel() -> Float { 0 }
}

/// A raw key event, at the shape the machine's sink receives them.
private func agreementKeyEvent(
    _ kind: RawKeyEvent.Kind, _ keyCode: UInt16, _ modifiers: ModifierSet
) -> RawKeyEvent {
    RawKeyEvent(
        kind: kind, keyCode: keyCode, modifiers: modifiers, isAutorepeat: false, timestamp: .zero)
}
