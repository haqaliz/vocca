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
import VoccaASR
@testable import VoccaBootstrap
import VoccaContext
import VoccaCore
import VoccaHotkey
@testable import VoccaInject
import VoccaText
import VoccaUI
import XCTest

/// **The C12 composition's contract** (`bootstrap-wiring` Phase 1): the wiring recipe the
/// composition root calls, driven over scripted doubles — the consent store consulted
/// **before** the provider (the decline-before-any-read doctrine, M5), never-read on no
/// consent (M5's structural half), the absent-store degradation (edge case 3), the dictation
/// cycle's independence (D2 — nothing on that path calls the slot), the Secure Input refusal
/// (M5b — a password field is never asked, and the badge never lights), the indicator fold
/// riding the composition (D3 — the shipped `setContext` surface, never a reducer edit), the
/// one-action kill with mid-turn discard (M9), and the shipped `NullContext` default (G12).
///
/// Every test composes the recipe exactly as `configure` will — the call itself is the
/// compile pin over the parameter list (`requireWiring` pins the returned surface) — and
/// attaches the root slots the way the composition root attaches them.
@MainActor
final class ContextWiringCompositionTests: XCTestCase {

    /// The all-absent snapshot — the seam's one failure vocabulary and the empty answer.
    private static let allAbsent = ContextSnapshot(bundleID: nil, windowTitle: nil, selectedText: nil)

    /// A real resolved snapshot for the consented-app turns.
    private static let editorSnapshot = ContextSnapshot(
        bundleID: "com.acme.Editor", windowTitle: "Draft", selectedText: "selected text")

    /// The consented app of the scripted tables.
    private static let editorBundleID = "com.acme.Editor"

    // MARK: - The compile pin

    /// The compile pin over the recipe's surface: the wiring's three members, consumed here
    /// so a renamed, reordered or removed surface fails to compile.
    private func requireWiring(_ wiring: ContextWiring) {
        _ = wiring.resolve
        _ = wiring.foldIndicator
        _ = wiring.killSwitch
    }

    // MARK: - Per-turn, consent-gated resolution

    /// **Two turns against two focused bundle IDs**: the resolver answers the stub's snapshot
    /// for the consented app and the empty snapshot for the unconsented one, and the consent
    /// store is consulted **before** the provider — the consults ledger precedes the read
    /// ledger, one consult per turn, one read only for the consented turn.
    func testTheCompositionResolvesPerTurnForTheFocusedApp() async {
        let store = ScriptedConsentStore(consented: [Self.editorBundleID])
        let provider = ScriptedContextProvider(script: [Self.editorSnapshot, Self.editorSnapshot])
        let harness = Harness(provider: provider, store: store)

        let first = await harness.wiring.resolve(Self.editorBundleID)
        XCTAssertEqual(first, Self.editorSnapshot, "the consented app's turn answers the snapshot")

        let second = await harness.wiring.resolve("com.other.Terminal")
        XCTAssertEqual(second, Self.allAbsent, "an unconsented app answers the empty snapshot")

        let consults = await store.consults
        XCTAssertEqual(
            consults, 2,
            "consent is consulted per turn — once for each resolution")
        XCTAssertEqual(
            provider.readCalls, 1,
            "the provider is reached only for the consented app — the consent consult "
                + "precedes the read (M5)")
    }

    /// **The consented app revoked**: the resolver answers the empty snapshot and
    /// `readCalls == 0` — not read-then-discard, never read.
    func testNoConsentMeansNeverRead() async {
        let provider = ScriptedContextProvider(script: [Self.editorSnapshot])
        let harness = Harness(
            provider: provider,
            store: ScriptedConsentStore(consented: []))

        let answer = await harness.wiring.resolve(Self.editorBundleID)
        XCTAssertEqual(answer, Self.allAbsent, "revoked consent answers the empty snapshot")
        XCTAssertEqual(
            provider.readCalls, 0,
            "a revoked app is never read — the gate declines before the provider (M5)")
    }

    /// **An absent consent store degrades to the no-consents path**: the real store over a
    /// directory with no consent file answers no consents — the empty snapshot, the provider
    /// never invoked, no throw, and nothing written (the silent-empty-memory precedent).
    func testAnAbsentConsentStoreDegradesToTheNullContextPath() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocca-context-wiring-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = ScriptedContextProvider(script: [Self.editorSnapshot])
        let harness = Harness(
            provider: provider,
            store: PersistentConsentStore(directory: directory))

        let answer = await harness.wiring.resolve(Self.editorBundleID)
        XCTAssertEqual(answer, Self.allAbsent, "a missing consent file is the empty consent")
        XCTAssertEqual(
            provider.readCalls, 0,
            "no consents means the provider is never invoked")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("context-consent.json").path),
            "the resolution wrote nothing — the safe direction by construction")
    }

    // MARK: - The dictation path never depends on context

    /// **A provider that fails on every call**: the composed dictation cycle through the
    /// composition root still completes byte-for-byte, and the resolver answers the empty
    /// snapshot — the loop never consulted context (D2's asserted half; the pinned files are
    /// the structural half). The seam is non-throwing by contract
    /// (`ContextProvider.swift:25-27`), so the failure mode answers the all-absent snapshot —
    /// the only failure vocabulary the seam has.
    func testContextResolutionFailureDoesNotBreakDictation() async {
        let provider = ScriptedContextProvider(script: [])
        provider.failEveryCall = true
        let store = ScriptedConsentStore(consented: ["com.apple.Notes"])
        let harness = DictationHarness()

        let wiring = AppBootstrap.composeContextWiring(
            provider: provider,
            consentStore: store,
            secureInput: ScriptedSecureInputState(),
            root: harness.root)
        harness.root.contextResolution = wiring.resolve
        harness.root.contextIndicatorFold = wiring.foldIndicator
        harness.root.contextKillSwitch = wiring.killSwitch

        harness.oneCycle()
        await Self.drain { await harness.injector.calls.count == 1 }

        let delivered = await harness.injector.calls.first
        XCTAssertEqual(
            delivered, "1 2 3",
            "the dictation cycle delivered byte-for-byte with a failing context provider "
                + "attached — the loop never depended on context")

        let answer = await wiring.resolve("com.apple.Notes")
        XCTAssertEqual(answer, Self.allAbsent, "a failing provider answers the empty snapshot (R1)")
        XCTAssertEqual(provider.readCalls, 1, "the only provider call is the test's own resolve")
    }

    // MARK: - Secure Input

    /// **The Secure Input refusal routes through the composition**: the resolver answers the
    /// empty snapshot, the provider is never invoked — a password field is never asked (M5b)
    /// — and the indicator fold stays unlit.
    func testSecureInputAnswersEmptyAndNeverLights() async {
        let provider = ScriptedContextProvider(script: [Self.editorSnapshot])
        let harness = Harness(
            provider: provider,
            store: ScriptedConsentStore(consented: [Self.editorBundleID]))
        harness.secureInput.active = true

        let answer = await harness.wiring.resolve(Self.editorBundleID)
        XCTAssertEqual(answer, Self.allAbsent, "Secure Input answers the empty snapshot")
        XCTAssertEqual(
            provider.readCalls, 0,
            "a Secure Input field is never asked — the refusal orders before any provider call")
        XCTAssertEqual(
            harness.root.widgetStore.state.context, .off,
            "the badge never lights for a Secure Input field (M5b/M8)")
        XCTAssertFalse(
            harness.root.menuBarConditions.isContextReading,
            "the menu's context fact stays off")
    }

    // MARK: - The indicator fold

    /// **The indicator fold rides the composition** (D3): the fold surface delivers the badge
    /// value into the widget store through the widget-indicator aspect's shipped fold case —
    /// `setContext` → `.reading` — and the revoked signal folds unlit; the resolution path
    /// folds through the same surface.
    func testTheIndicatorFoldRidesTheComposition() async {
        let harness = Harness(
            provider: ScriptedContextProvider(script: [Self.editorSnapshot]),
            store: ScriptedConsentStore(consented: [Self.editorBundleID]))

        harness.wiring.foldIndicator(
            WidgetContextSignal(consentActive: true, secureInputActive: false, appName: "Editor"))
        XCTAssertEqual(
            harness.root.widgetStore.state.context, .reading(appName: "Editor"),
            "a lit signal folds the badge through the shipped fold case")
        XCTAssertTrue(harness.root.menuBarConditions.isContextReading)

        harness.wiring.foldIndicator(
            WidgetContextSignal(consentActive: false, secureInputActive: false, appName: nil))
        XCTAssertEqual(
            harness.root.widgetStore.state.context, .off,
            "a revoked signal folds unlit in the same shape")
        XCTAssertFalse(harness.root.menuBarConditions.isContextReading)

        let answer = await harness.wiring.resolve(Self.editorBundleID)
        XCTAssertEqual(answer, Self.editorSnapshot)
        XCTAssertEqual(
            harness.root.widgetStore.state.context, .reading(appName: nil),
            "a consented resolution rides the fold — the badge lights through the composition, "
                + "never a reducer edit")
    }

    // MARK: - The one-action kill switch

    /// **A kill mid-turn** (M9): the resolver answers empty from then on, the provider is not
    /// called again, the in-flight snapshot is discarded — a resolution suspended in the
    /// consent read when the kill lands answers the empty snapshot and never reaches the
    /// provider — and the indicator fold clears in the same call. Nothing is persisted, so
    /// the discard is total.
    func testTheKillSwitchRevokesGloballyInOneActionWithMidTurnDiscard() async {
        let store = ScriptedConsentStore(consented: [Self.editorBundleID])
        let provider = ScriptedContextProvider(script: [Self.editorSnapshot, Self.editorSnapshot])
        let harness = Harness(provider: provider, store: store)

        let first = await harness.wiring.resolve(Self.editorBundleID)
        XCTAssertEqual(first, Self.editorSnapshot, "the wiring is live before the kill")
        XCTAssertEqual(harness.root.widgetStore.state.context, .reading(appName: nil))

        // The mid-turn shape: a resolution is in flight — suspended in the consent read —
        // when the kill lands.
        await store.armGate()
        let inFlight = Task { await harness.wiring.resolve(Self.editorBundleID) }
        await Self.drain { await store.consults == 2 }

        harness.wiring.killSwitch()

        XCTAssertEqual(
            harness.root.widgetStore.state.context, .off,
            "the badge clears in the same fold as the kill — no intermediate state")
        XCTAssertFalse(harness.root.menuBarConditions.isContextReading)

        await store.releaseGate()
        let discarded = await inFlight.value
        XCTAssertEqual(
            discarded, Self.allAbsent,
            "the in-flight snapshot is discarded — a resolution that lands after the kill "
                + "answers empty")
        XCTAssertEqual(provider.readCalls, 1, "the in-flight turn never reached the provider")

        let later = await harness.wiring.resolve(Self.editorBundleID)
        XCTAssertEqual(
            later, Self.allAbsent,
            "the resolver answers empty from then on — the revoke is global, one action")
        XCTAssertEqual(
            provider.readCalls, 1,
            "the provider is never called again after the kill")
    }

    // MARK: - The shipped default

    /// **The composed default is the shipped `NullContext`** — the type check pins the
    /// default: the recipe compiles with `NullContext()` as the provider (the shape
    /// `configure` uses), and the honest default reads nothing even for a consented app —
    /// every field nil, never `""`.
    func testTheComposedDefaultIsNullContext() async {
        let harness = Harness(
            provider: NullContext(),
            store: ScriptedConsentStore(consented: [Self.editorBundleID]))

        requireWiring(harness.wiring)

        let answer = await harness.wiring.resolve(Self.editorBundleID)
        XCTAssertEqual(
            answer, Self.allAbsent,
            "NullContext reads nothing even when consent holds — the honest shipped default")
    }

    // MARK: - Harness plumbing

    /// Turns the main actor's queue until `condition` holds — the drain shape of every
    /// composed test in this suite.
    private static func drain(until condition: @escaping @Sendable () async -> Bool) async {
        var attempts = 0
        while !(await condition()) && attempts < 1_000 {
            await Task.yield()
            attempts += 1
        }
    }
}

/// **The composed context harness**: a real root over fakes, the wiring composed over scripted
/// doubles exactly as `configure` composes it, and the root slots attached the way the
/// composition root attaches them — so the shipped wiring shape is what the tests exercise
/// rather than a second, invented copy.
@MainActor
private final class Harness {
    let root: DictationLoopRoot
    let wiring: ContextWiring
    let secureInput: ScriptedSecureInputState

    init(
        provider: any ContextProvider,
        store: any ConsentStore,
        secureInput: ScriptedSecureInputState = ScriptedSecureInputState()
    ) {
        let clock = TestClock()
        let keyboard = Keyboard()
        let holdSource = RecordingAudioSource()
        let toggleSource = RecordingAudioSource()
        let timer = FakeTimer()
        let toggleTimer = FakeTimer()
        let healthTimer = FakeTimer()
        let widgetClock = FakeTimer()
        let tap = FakeHotkeyEventSource()
        let focusedApp = FakeFocusedApp(
            identity: FocusedAppIdentity(
                bundleID: "com.apple.Notes", windowTitle: "The Draft"))
        let secureInputRead = FakeSecureInput()
        let appName = FakeRunningAppName()
        let holder = LedgerHolder()
        let resolver = DictationEngineResolver(selection: .defaultSelection) { _ in
            StubEngine.parakeet()
        }
        let root = DictationLoopRoot(
            configuration: HotkeyConfiguration(
                keyCode: 49, modifiers: [.option], activation: .holdToTalk),
            ceiling: SessionCeiling.default,
            clock: clock,
            audioSource: holdSource,
            keyState: TruthfulKeyState(keyboard),
            watchdogTimer: timer,
            healthTimer: healthTimer,
            deferOpening: { $0() },
            tap: tap,
            secureInput: FakeSecureInputState(),
            resolver: resolver,
            targetResolution: TargetResolution(
                focusedApp: focusedApp, secureInput: secureInputRead,
                frontmost: FakeFrontmostApp()),
            panel: RecordingPanel(holder: holder),
            toggleConfiguration: HotkeyConfiguration(
                keyCode: 49, modifiers: [.option], activation: .toggle),
            toggleSource: toggleSource,
            toggleTimer: toggleTimer,
            runningAppName: appName,
            widgetClock: widgetClock,
            liveLevel: QuietLevelSource(),
            sessionKind: .dictation)
        root.markEnginePrepared()

        let wiring = AppBootstrap.composeContextWiring(
            provider: provider,
            consentStore: store,
            secureInput: secureInput,
            root: root)
        root.contextResolution = wiring.resolve
        root.contextIndicatorFold = wiring.foldIndicator
        root.contextKillSwitch = wiring.killSwitch

        self.root = root
        self.wiring = wiring
        self.secureInput = secureInput
    }
}

/// **The dictation half** of the independence test: a real root over fakes with a real
/// pipeline over a recording injector — the cycle's delivery is asserted against what the
/// injector recorded, never a belief about the root.
@MainActor
private final class DictationHarness {
    let root: DictationLoopRoot
    let injector: RecordingInjector
    private let keyboard: Keyboard

    init() {
        let clock = TestClock()
        let keyboard = Keyboard()
        let source = RecordingAudioSource()
        source.nextSamples = [1, 2, 3]
        let toggleSource = RecordingAudioSource()
        let timer = FakeTimer()
        let toggleTimer = FakeTimer()
        let healthTimer = FakeTimer()
        let widgetClock = FakeTimer()
        let tap = FakeHotkeyEventSource()
        let focusedApp = FakeFocusedApp(
            identity: FocusedAppIdentity(
                bundleID: "com.apple.Notes", windowTitle: "The Draft"))
        let secureInput = FakeSecureInput()
        let appName = FakeRunningAppName()
        let holder = LedgerHolder()
        let engine = StubEngine.parakeet()
        let injector = RecordingInjector()
        let resolver = DictationEngineResolver(selection: .defaultSelection) { _ in engine }
        let pipeline = DictationPipeline(
            engine: engine, injector: injector, holder: holder,
            recorder: nil, clock: nil,
            sessionKind: .dictation)
        let root = DictationLoopRoot(
            configuration: HotkeyConfiguration(
                keyCode: 49, modifiers: [.option], activation: .holdToTalk),
            ceiling: SessionCeiling.default,
            clock: clock,
            audioSource: source,
            keyState: TruthfulKeyState(keyboard),
            watchdogTimer: timer,
            healthTimer: healthTimer,
            deferOpening: { $0() },
            tap: tap,
            secureInput: FakeSecureInputState(),
            resolver: resolver,
            targetResolution: TargetResolution(
                focusedApp: focusedApp, secureInput: secureInput,
                frontmost: FakeFrontmostApp()),
            panel: RecordingPanel(holder: holder),
            pipeline: pipeline,
            toggleConfiguration: HotkeyConfiguration(
                keyCode: 49, modifiers: [.option], activation: .toggle),
            toggleSource: toggleSource,
            toggleTimer: toggleTimer,
            runningAppName: appName,
            widgetClock: widgetClock,
            liveLevel: QuietLevelSource(),
            sessionKind: .dictation)
        root.markEnginePrepared()

        self.root = root
        self.injector = injector
        self.keyboard = keyboard
    }

    /// One full hold-to-talk cycle: chord down, chord up.
    func oneCycle() {
        keyboard.hold(DictationHarness.configuration)
        _ = root.holdToTalk.scheduledWatchdog.receive(
            Self.event(.keyDown, DictationHarness.configuration.keyCode, [.option]))
        _ = root.holdToTalk.scheduledWatchdog.receive(
            Self.event(.keyUp, DictationHarness.configuration.keyCode, [.option]))
        keyboard.release(DictationHarness.configuration.keyCode)
    }

    private static let configuration = HotkeyConfiguration(
        keyCode: 49, modifiers: [.option], activation: .holdToTalk)

    private static func event(
        _ kind: RawKeyEvent.Kind, _ keyCode: UInt16, _ modifiers: ModifierSet
    ) -> RawKeyEvent {
        RawKeyEvent(
            kind: kind, keyCode: keyCode, modifiers: modifiers, isAutorepeat: false,
            timestamp: .zero)
    }
}

/// The seam's scripted implementation: one answer per call from the script, a read ledger,
/// and a per-call failure mode. The seam is **non-throwing by contract**
/// (`ContextProvider.swift:25-27` — a failure resolves to an empty snapshot, expressed in
/// the type system), so the failure mode answers the all-absent snapshot — the only failure
/// vocabulary the seam has.
private final class ScriptedContextProvider: ContextProvider, @unchecked Sendable {
    private var script: [ContextSnapshot]
    private(set) var readCalls = 0
    var failEveryCall = false

    init(script: [ContextSnapshot]) {
        self.script = script
    }

    func resolveCurrent() -> ContextSnapshot {
        readCalls += 1
        if failEveryCall {
            return ContextSnapshot(bundleID: nil, windowTitle: nil, selectedText: nil)
        }
        return script.isEmpty
            ? ContextSnapshot(bundleID: nil, windowTitle: nil, selectedText: nil)
            : script.removeFirst()
    }
}

/// The consent store's scripted implementation: an answer table and a consults ledger. The
/// gated mode suspends one `load()` until released — the mid-turn kill's hook.
private actor ScriptedConsentStore: ConsentStore {
    private(set) var consults = 0
    private let consented: Set<String>
    private var gated = false
    private var gate: CheckedContinuation<Void, Never>?

    init(consented: Set<String>) {
        self.consented = consented
    }

    /// The next `load()` suspends until ``releaseGate()``.
    func armGate() {
        gated = true
    }

    func releaseGate() {
        gated = false
        gate?.resume()
        gate = nil
    }

    func load() async -> Set<String> {
        consults += 1
        if gated {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                gate = continuation
            }
        }
        return consented
    }

    func set(_ bundleID: String, consented: Bool) async throws -> Bool { true }
    func save(_ ids: Set<String>) async throws {}
}

/// The Secure Input fact's scripted implementation.
private final class ScriptedSecureInputState: SecureInputStateReader, @unchecked Sendable {
    var active = false
    var isSecureInputActive: Bool { active }
}

/// The recording injector: every call's text in order.
private actor RecordingInjector: TextInjector {
    private(set) var calls: [String] = []

    func inject(_ text: String, into target: TargetContext) async -> InjectionResult {
        calls.append(text)
        return InjectionResult(
            rung: .clipboardPaste, attempted: [.clipboardPaste], verified: false, elapsed: .zero)
    }
}

/// A level source that never moves — this suite's `SilentLevelSource` (each file owns its
/// spelling).
private struct QuietLevelSource: LiveLevelSource {
    func latestLevel() -> Float { 0 }
}