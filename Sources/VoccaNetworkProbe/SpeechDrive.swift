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

import Dispatch
import Foundation
import VoccaCore
import VoccaSpeech

// The probe's half of the zero-network invariant for `VoccaSpeech`, and the retirement of the
// module's placeholder witness.
//
// The placeholder era ended with the system synthesizer: `VoccaSpeech` ships a real adapter now,
// and its default-configuration surface is **constructing `SystemSynthesizer` and speaking**.
// This drive runs that surface — construct, `speak("")` to completion (the seam's empty-text
// policy: nothing to say is an answer, never an error, and an empty render touches no renderer
// path that could reach out), then `cancel()` (the barge-in contract's other half: safe with
// nothing in flight). The report is what stands in for `SystemSynthesizer.self` in the probe's
// module list — a witness minted *by* the call, so the entry cannot outlive the call it stands
// for, exactly as the other drives' witnesses work.
//
// ## What this drive does not do
//
// It does **not** render speech. An empty utterance renders nothing — that is the point of the
// empty-text policy — so the drive needs no voices and no renderer, and the zero-network
// observation stays deterministic on every machine, CI included. Real rendering is the
// env-gated suite's job (`SpeechSystemSuiteTests`), which the founder's machine runs and records.

extension VoccaNetworkProbe {

    /// One pass over the module's default-configuration surface, and the post-condition the
    /// coverage list reads.
    struct SpeechDrive {
        /// The observation, as one line of `key=value` fields.
        let report: String

        /// A type minted **by this drive**, from which `VoccaSpeech`'s name is derived for the
        /// coverage list.
        ///
        /// This is the line that replaces `SystemSynthesizer.self`. That literal satisfied the
        /// coverage guard whether or not a single line of `VoccaSpeech` ever ran; a witness taken
        /// from the synthesizer this drive constructed and spoke through cannot be kept while the
        /// call is deleted.
        let moduleWitness: Any.Type
    }

    /// **Drives the speech module's default-configuration surface, and reports what happened.**
    ///
    /// Nothing here asserts. The probe reports and the suite asserts, for the reason every other
    /// drive gives: an assertion living in the observed process can be deleted by the same edit
    /// that breaks what it observes, and its failure would arrive as an exit status rather than
    /// as a named expectation.
    static func exerciseSpeech() -> SpeechDrive {
        // The same run-loop-pumped bridge the other drives use: `main()` is the process entry
        // point and is already on the main thread, so the async work is handed to a Task and the
        // loop is pumped until it lands — inside the observation window rather than after it.
        let semaphore = DispatchSemaphore(value: 0)
        let box = SpeechDriveBox()
        Task {
            box.value = await runSpeechRoundTrip()
            semaphore.signal()
        }
        while semaphore.wait(timeout: .now()) == .timedOut {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return box.value!
    }

    /// Stores the drive's result across the `@Sendable` boundary — the `CycleDriveBox` shape, and
    /// honest for the same reason: written once by the Task and read once after the semaphore.
    private final class SpeechDriveBox: @unchecked Sendable {
        var value: SpeechDrive?
    }

    /// The round trip itself.
    private static func runSpeechRoundTrip() async -> SpeechDrive {
        let synth = SystemSynthesizer(voiceIdentifier: nil)

        // `speak("")` yields nothing and never throws — the seam's empty-text policy, and the
        // module's cheapest real surface: an empty render touches no renderer path at all. A
        // throw here would be a seam violation, so it is reported rather than swallowed.
        var chunks = 0
        var errorNote: String?
        do {
            for try await _ in synth.speak("") {
                chunks += 1
            }
        } catch {
            errorNote = "\(error)"
        }

        // `cancel()` with nothing in flight — the barge-in contract's safe-when-idle half.
        await synth.cancel()

        return SpeechDrive(
            report: [
                "identity=\(synth.identity.engineID)",
                "voiceName=\(synth.identity.voiceName ?? "nil")",
                "emptySpeak.chunks=\(chunks)",
                "emptySpeak.error=\(errorNote ?? "none")",
                "cancel.afterEmptySpeak=true",
            ].joined(separator: " "),
            moduleWitness: type(of: synth))
    }
}