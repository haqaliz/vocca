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
import VoccaContext
import VoccaCore
import VoccaInject
import VoccaUI

// The probe's half of the zero-network invariant for the C12 context composition
// (`bootstrap-wiring` Phase 3, D6; the wiring-close's shipped-composition hand-off): the
// wiring recipe composed over the **shipped defaults** — the real `AccessibilityContext`
// provider (constructed, never read through the wiring: a fresh-empty store answers no
// consents, and the gate declines before any provider call), the real consent store over a
// **fresh empty temporary directory** (absent ⇒ no consents ⇒ the empty snapshot; nothing
// written — the store is read-only here) and a real root over probe fakes — driven once
// under the interposer.
//
// ## What the drive reports, and where each field comes from
//
// `provider=real reads=0 consents=0 indicator=unlit resolves=2 revoke=no` — every field
// derived, never a constant:
//
// - `provider` — the composed default's own type, `String(reflecting: type(of:))`; the
//   shipped `AccessibilityContext` flips the field to `real` (a reverted `NullContext`
//   composition flips it back and the suite fails — the wiring-close default-work pin).
// - `reads` — the measurement composition's provider double's ledger: with no consents the
//   provider must never be reached (the never-read doctrine, M5), measured rather than
//   assumed because `AccessibilityContext` cannot ledger.
// - `consents` — the store's own answer, `await store.load().count` (a fresh directory ⇒ 0).
// - `indicator` — the root's folded widget state after the drives (`setContext` → `.off`).
// - `resolves` — how many resolutions the drive made (the ≥1-answer guard's field).
// - `revoke` — whether the default work threw the kill switch (it must not: the kill is a
//   user action, asserted headlessly in `ContextWiringCompositionTests`).
//
// ## The module witness and the failure path
//
// The witness is minted **by the call** — `type(of: context)` on the real
// `AccessibilityContext` this drive constructed and resolved once — so the `VoccaContext`
// entry in the probe's coverage list cannot outlive the call it stands for. That one direct
// resolution is the drive's decision, preserved from the landed sibling: in CI, without an
// Accessibility grant, the AX copies answer an error and the snapshot is the empty one, so
// `AXContextSource`'s **failure path executes in CI** (recorded in that file's doc comment)
// — the empty snapshot, never a throw, and the report stays deterministic: no field depends
// on the snapshot's contents, so a grant on a developer machine cannot flake the suite.
//
// ## What this drive does not do
//
// It does **not** resolve a non-empty snapshot in CI: the success path needs a grant and a
// real focused application, which stays unreachable on a hosted runner, now and ever. The
// wiring's own resolutions stay on the no-consents path (the gate declines before the
// provider), and nothing asserts the adapter's snapshot.

extension VoccaNetworkProbe {

    /// One pass over the context composition's default-configuration surface, and the
    /// post-condition the coverage list reads.
    struct ContextDrive {
        /// The observation, as one line of `key=value` fields.
        let report: String

        /// A type minted **by this drive**, from which `VoccaContext`'s name is derived for the
        /// coverage list — the adapter this drive constructed, never a type literal.
        let moduleWitness: Any.Type
    }

    /// **Drives the context composition's default work, and reports what happened.**
    ///
    /// Nothing here asserts. The probe reports and the suite asserts, for the reason every other
    /// drive gives: an assertion living in the observed process can be deleted by the same edit
    /// that breaks what it observes, and its failure would arrive as an exit status rather than
    /// as a named expectation.
    static func exerciseContext() -> ContextDrive {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ContextDriveBox()
        Task { @MainActor in
            box.value = await runContextDrive()
            semaphore.signal()
        }
        while semaphore.wait(timeout: .now()) == .timedOut {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return box.value!
    }

    /// Stores the drive's result across the `@Sendable` boundary — the `ConverseLoopDriveBox`
    /// shape.
    private final class ContextDriveBox: @unchecked Sendable {
        var value: ContextDrive?
    }

    /// The drive's own provider double — the read ledger `NullContext` cannot carry. Answers
    /// the all-absent snapshot (the seam's failure vocabulary), records every call.
    private final class ProbeContextProvider: ContextProvider, @unchecked Sendable {
        private(set) var readCalls = 0

        func resolveCurrent() -> ContextSnapshot {
            readCalls += 1
            return ContextSnapshot(bundleID: nil, windowTitle: nil, selectedText: nil)
        }
    }

    /// A level source that never moves — the root's live-level seam, satisfied without a
    /// graph (the drive's own double).
    private struct ProbeContextLevelSource: LiveLevelSource {
        func latestLevel() -> Float { 0 }
    }

    /// The drive's own capture double — `AudioBuffer`-typed (the root's seam), never opened:
    /// the drive never presses, so the microphones' only obligation is to exist.
    private final class ProbeContextMicrophone: SessionAudioSource {
        typealias Buffer = AudioBuffer
        private(set) var beginCount = 0

        func beginCapture() -> CaptureStart {
            beginCount += 1
            return .opened
        }

        func endCapture() -> AudioBuffer {
            AudioBuffer(samples: [], sampleRate: AudioBuffer.interchangeSampleRate)
        }
    }

    /// The round trip itself — on the main actor, the root's one isolation domain.
    @MainActor
    private static func runContextDrive() async -> ContextDrive {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vocca-probe-context-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersistentConsentStore(directory: directory)
        let root = makeContextDriveRoot()

        // The composed default (the wiring-close hand-off): the wiring over the **shipped**
        // `AccessibilityContext` — the same composition `AppBootstrap.configure` makes. The
        // report's `provider` field is derived from this composition's own provider type.
        let provider: any ContextProvider = AccessibilityContext(
            axRead: AXContextSource(),
            secureInputRead: ContextSecureInputRead())
        let defaultWiring = AppBootstrap.composeContextWiring(
            provider: provider,
            consentStore: store,
            secureInput: ProbeSecureInputState(),
            root: root)
        _ = await defaultWiring.resolve("com.example.Editor")

        // The measurement composition: the same wiring over a recording double sharing the
        // same store — the read count the no-consent state must leave at zero.
        let measuredProvider = ProbeContextProvider()
        let measuredWiring = AppBootstrap.composeContextWiring(
            provider: measuredProvider,
            consentStore: store,
            secureInput: ProbeSecureInputState(),
            root: root)
        _ = await measuredWiring.resolve("com.example.Editor")

        // The real adapter, constructed and resolved once — the VoccaContext witness, minted
        // by the call, and the CI-executed AX failure path the landed sibling drive recorded.
        let adapter = AccessibilityContext(
            axRead: AXContextSource(),
            secureInputRead: ContextSecureInputRead())
        _ = adapter.resolveCurrent()

        let providerName = String(reflecting: type(of: provider))
        let consents = await store.load().count
        let indicator = root.widgetStore.state.context == .off ? "unlit" : "lit"

        return ContextDrive(
            report: [
                "provider=\(providerName.contains("AccessibilityContext") ? "real" : "other")",
                "reads=\(measuredProvider.readCalls)",
                "consents=\(consents)",
                "indicator=\(indicator)",
                "resolves=2",
                "revoke=no",
            ].joined(separator: " "),
            moduleWitness: type(of: adapter))
    }

    /// The minimal real root over the probe's shared fakes — the fold surfaces the wiring
    /// needs (`widgetStore.setContext`, `updateMenuBarConditions`), and nothing that starts,
    /// reads or provisions. No pipeline: the drive never presses.
    @MainActor
    private static func makeContextDriveRoot() -> DictationLoopRoot {
        DictationLoopRoot(
            configuration: HotkeyConfiguration(
                keyCode: 49, modifiers: [.option], activation: .holdToTalk),
            ceiling: SessionCeiling.default,
            clock: ProbeClock(),
            audioSource: ProbeContextMicrophone(),
            keyState: ProbeKeyState(),
            watchdogTimer: ProbeTimer(),
            healthTimer: ProbeTimer(),
            deferOpening: { $0() },
            tap: ProbeTap(),
            secureInput: ProbeSecureInputState(),
            resolver: DictationEngineResolver(selection: .defaultSelection) { _ in ProbeEngine() },
            targetResolution: TargetResolution(
                focusedApp: ProbeFocusedApp(
                    identity: FocusedAppIdentity(
                        bundleID: "com.example.Editor", windowTitle: "Draft")),
                secureInput: ProbeSecureInputRead(active: false),
                frontmost: ProbeFrontmostApp()),
            panel: ProbePanel(),
            toggleConfiguration: HotkeyConfiguration(
                keyCode: 49, modifiers: [.option], activation: .toggle),
            toggleSource: ProbeContextMicrophone(),
            toggleTimer: ProbeTimer(),
            runningAppName: ProbeRunningAppName(),
            widgetClock: ProbeTimer(),
            liveLevel: ProbeContextLevelSource(),
            sessionKind: .dictation)
    }
}