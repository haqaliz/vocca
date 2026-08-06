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
        // list left this suite 2/2 green. Module granularity is enough for the eight placeholder
        // modules, which have no work yet; VoccaBootstrap is the one module where the work *is* the
        // deliverable, because it is the app's real start-up path and the only code in this package
        // that runs before the run loop.
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
