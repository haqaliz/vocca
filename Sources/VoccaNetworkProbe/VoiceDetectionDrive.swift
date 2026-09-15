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
import VoccaCore

// The probe's half of the zero-network invariant for the Silero VAD adapter's construct leg
// (`sdk-adapters/plan_20260915.md` Step 3.3).
//
// The `SpeechDrive` structure, for the module whose ASR witness already covers `VoccaASR`: the
// VAD adapter's default-configuration surface is **constructing it over a fresh, empty temporary
// directory and classifying an empty frame** — the pure init (plain data, nothing touched) and
// the seam's empty-frame short-circuit (no evidence, no model touch). That is the probe contract
// the whole adapter is built around: no model bytes, no download path, no network name
// reachable, and `VadManager` is not even constructed.
//
// ## What this drive does not do
//
// It does not run the model. An empty frame never completes a 4096-sample chunk, so the lazy
// load is never attempted — and because the model directory is a fresh, empty temporary
// directory, even a hypothetical touch would be visible: the memoized load failure would name
// the missing model path, and the report's `modelTouched` field would read `true`. The drive
// reports the observation; the zero-network suite asserts it. Real VAD classification is the
// env-gated suite's job (`SileroVadRealSuiteTests`), which the founder's machine runs.
//
// The `eou=pending` field is the Branch B verdict (recorded in `docs/planning/_card/
// understanding.md`): the EOU SDK surface is ASR-integrated and unusable as a standalone scored
// `TurnDetector`, so `ParakeetEOU` ships pending and `SilenceThresholdDetector` stays the
// shipped implementation.

extension VoccaNetworkProbe {

    /// One pass over the VAD adapter's construct-only surface, and the post-condition the
    /// zero-network suite reads.
    struct VoiceDetectionDrive {
        /// The observation, as one line of `key=value` fields.
        let report: String
    }

    /// **Drives the VAD adapter's default-configuration surface, and reports what happened.**
    ///
    /// Nothing here asserts. The probe reports and the suite asserts, for the reason every other
    /// drive gives: an assertion living in the observed process can be deleted by the same edit
    /// that breaks what it observes.
    ///
    /// The `SpeechDrive` Kokoro-construct-leg shape (`SpeechDrive.swift:112-137`): a fresh,
    /// empty temporary directory created and removed around the call, the adapter constructed
    /// over it (pure — stores plain data), and an empty frame classified (the seam's
    /// short-circuit: `.silence`, no model touch). The report's `modelTouched` is read from the
    /// adapter's own recorded failure surface: nil means no load attempt happened.
    static func exerciseVoiceDetection() -> VoiceDetectionDrive {
        let modelDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "vocca-network-probe-vad-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: modelDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: modelDirectory) }

        let vad = SileroVAD(
            configuration: VADConfiguration(
                onsetRMS: 0.05, offsetRMS: 0.02, minimumSpeech: 0.10, minimumSilence: 0.20),
            modelDirectory: modelDirectory)
        let activity = vad.classify(AudioBuffer(samples: [], sampleRate: 16_000))

        return VoiceDetectionDrive(
            report: [
                "identity=silero-vad",
                "construct=true",
                "emptyFrame=\(activity)",
                "modelTouched=\(vad.loadFailureDescription == nil ? "false" : "true")",
                "eou=pending",
            ].joined(separator: " "))
    }
}