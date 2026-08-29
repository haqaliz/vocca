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
import VoccaUI
import XCTest

/// **The Speech tab's words** — the half of the surface CI can read, since the page itself needs a
/// window server (`AppsTabCopyTests`/`BadgeCopyTests` precedent).
///
/// Two jobs. The first is the ordinary pin: `PRODUCT_SPEC.md:254-262` is authoritative on what
/// this tab says, and every string reaching a user is either ``EnginePickerCopy``'s spec-verbatim
/// constant or derived from one here. The second is **R7**, which is not a wording preference but
/// a claim about the product: Whisper has never transcribed anything. `SMOKE_CHECKLIST.md` step 19
/// is unexecuted, and its WER tolerances were seeded from Parakeet's table rather than measured on
/// whisper's own output (`tolerances_20260810.md`). A tab that drew the two engines as two equal
/// choices would be making a claim nobody has earned, in the one place a user goes to choose
/// between them.
final class SpeechTabCopyTests: XCTestCase {

    // MARK: - The management controls, derived rather than restated

    /// **The management controls are derived from the spec's own sentence, not typed twice.**
    ///
    /// `PRODUCT_SPEC.md:260` writes the three affordances in prose — "Model management: disk used,
    /// remove, re-download." — and a button label carries a leading capital, which is the only
    /// difference. Restating them as three fresh literals is how a copy change lands in the
    /// sentence and not on the buttons; deriving them means the spec line is still the one source,
    /// and this test fails if the sentence and the buttons ever stop being the same words.
    func testTheManagementControlsAreDerivedFromTheSpecSentence() {
        XCTAssertEqual(
            SpeechTabCopy.managementControls,
            ["Disk used", "Remove", "Re-download"],
            "the three controls the spec's management line names, sentence-cased")

        // ...and they really are that sentence's words, not a coincidence that matches today.
        let spelledInTheSpecLine = EnginePickerCopy.modelManagementLine
            .drop { $0 != ":" }.dropFirst()
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ".", with: "") }
        XCTAssertEqual(
            SpeechTabCopy.managementControls.map { $0.lowercased() },
            spelledInTheSpecLine,
            """
            the control labels must be the spec sentence's own phrases. If the spec renames one, \
            this fails until the sentence and the buttons agree again.
            """)
    }

    /// The removal confirmation names the model and says what is lost — the spec's cleanup-tab
    /// rule ("a dialog the user has to read") applied to the one irreversible action on this tab.
    func testTheRemovalConfirmationNamesTheModelAndTheConsequence() {
        let prompt = SpeechTabCopy.removalConfirmation(for: .whisperTurbo)
        XCTAssertTrue(
            prompt.contains(EnginePickerCopy.whisperName),
            "the prompt names the engine being removed, not 'this model'")
        XCTAssertTrue(
            prompt.contains("download"),
            "and says the way back — the bytes are recoverable, which is the whole reason this is "
                + "a confirmation rather than a warning")
    }

    /// Removal while a session is in flight is refused, and the refusal says *why* and *what to
    /// do* — `setActiveMode`'s shape, in words rather than a disabled control with no explanation.
    func testTheIdleRefusalSaysWhyAndWhatToDo() {
        XCTAssertEqual(
            SpeechTabCopy.removalRefusedWhileDictating,
            "Finish the dictation first. Vocca won't remove a model while it's listening.")
    }

    // MARK: - R7: the two engines are not equally exercised

    /// **R7.** The Whisper row carries the honest status, and the Parakeet row does not carry the
    /// same one — a marker on both, or on neither, would present them as equally exercised, which
    /// is the thing R7 forbids.
    ///
    /// The wording claims nothing in either direction. It does not say Whisper is worse; it says
    /// it has not been run, which is a fact about this repository (`SMOKE_CHECKLIST.md` step 19,
    /// unexecuted) rather than an opinion about the model.
    func testWhisperCarriesTheUnmeasuredStatusAndParakeetDoesNot() {
        XCTAssertEqual(
            SpeechTabCopy.engineStatus(for: .whisperTurbo),
            "Not yet measured. Vocca has never transcribed with this engine, so nothing here is a "
                + "claim about how well it works.")
        XCTAssertEqual(
            SpeechTabCopy.engineStatus(for: .parakeetV3),
            "Measured. Vocca's accuracy checks have been run against this engine.")
        XCTAssertNotEqual(
            SpeechTabCopy.engineStatus(for: .whisperTurbo),
            SpeechTabCopy.engineStatus(for: .parakeetV3),
            """
            the two engines must not read as equally exercised. Whisper has never transcribed \
            anything — step 19 is unexecuted and its tolerances were seeded from Parakeet's table \
            rather than measured — and this tab is where a user chooses between them.
            """)
    }

    /// And the status invents no number, in either direction. The taglines are the only place a
    /// comparison is made, and those are the spec's own words (the S1 posture `EnginePickerCopy`
    /// already holds).
    func testTheEngineStatusesInventNoNumbers() {
        for engine in EngineCandidate.allCases {
            let status = SpeechTabCopy.engineStatus(for: engine)
            XCTAssertFalse(
                status.contains(where: \.isNumber),
                """
                \(engine.displayName)'s status contains a figure: "\(status)". No WER, latency or \
                accuracy number for either engine exists — Parakeet's are provisional and \
                whisper's were never measured at all.
                """)
        }
    }
}
