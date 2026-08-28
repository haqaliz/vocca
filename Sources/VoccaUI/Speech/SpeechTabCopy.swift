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

/// The Speech tab's strings — the ones ``EnginePickerCopy`` does not already hold.
///
/// ``EnginePickerCopy`` is the spec's own surface (`PRODUCT_SPEC.md:254-262`: the radio glyphs,
/// the two engine names, the two taglines, the two affordances and the model-management line) and
/// is reused here verbatim rather than restated. This enum holds what the spec's mock does not
/// draw: the model-management controls it names in prose, and the sentences a running page needs
/// that a mock never has to.
public enum SpeechTabCopy {

    // MARK: - Model management (`PRODUCT_SPEC.md:260`)

    /// The three management controls, **derived from the spec's own sentence** rather than typed
    /// out a second time.
    ///
    /// `PRODUCT_SPEC.md:260` names them in prose — "Model management: disk used, remove,
    /// re-download." — and a button label differs from that prose only by a leading capital.
    /// Restating them as three fresh literals is how a copy change lands in the sentence and never
    /// on the buttons, so the sentence stays the one source and the labels are read out of it.
    ///
    /// Order is the spec's, and is the order the row renders them in.
    public static var managementControls: [String] {
        EnginePickerCopy.modelManagementLine
            .drop { $0 != ":" }
            .dropFirst()
            .split(separator: ",")
            .map { phrase in
                let trimmed = phrase
                    .trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: ".", with: "")
                return trimmed.prefix(1).uppercased() + trimmed.dropFirst()
            }
    }

    /// The disk-used label — the first of the spec's three.
    public static var diskUsedLabel: String { managementControls[0] }

    /// The [Remove] button — the second.
    public static var removeButton: String { managementControls[1] }

    /// The [Re-download] button — the third.
    public static var redownloadButton: String { managementControls[2] }

    /// The [Download] button for a tier that has never been fetched. Not a management control:
    /// the spec's own affordance (`EnginePickerCopy.downloadAffordance`) is the badge, and this is
    /// the button beside it.
    public static let downloadButton = "Download"

    /// The button that stops a transfer. Not "Cancel", which in a settings window reads as
    /// "close this without doing anything".
    public static let stopDownloadButton = "Stop"

    // MARK: - Removal

    /// The removal confirmation. Names the engine rather than saying "this model", and says the
    /// way back in the same breath — the bytes are recoverable, which is exactly why this is a
    /// confirmation rather than a warning.
    ///
    /// The spec asks for a dialog a user has to read before text leaves their machine
    /// (`PRODUCT_SPEC.md:266`); this is the same posture applied to the one irreversible-looking
    /// action on this tab.
    public static func removalConfirmation(for tier: EngineTier) -> String {
        """
        Remove \(name(for: tier))? \
        Dictation with it stops working until you download it again.
        """
    }

    /// Removal refused because a dictation is in flight — `setActiveMode`'s guard, in words.
    ///
    /// Says what to do rather than only what failed. A disabled button with no sentence beside it
    /// teaches a user the app is broken, which is the same argument
    /// ``SettingsCopy/hotkeyNotRebindable`` makes for saying so plainly.
    public static let removalRefusedWhileDictating =
        "Finish the dictation first. Vocca won't remove a model while it's listening."

    // MARK: - R7: what has and has not been measured

    /// **What Vocca has actually run this engine through.**
    ///
    /// Whisper has never transcribed anything: `SMOKE_CHECKLIST.md` step 19 is unexecuted, and
    /// `WhisperCppEngineWERTests` skips without `VOCCA_MODEL_DIR` — its provisional tolerances
    /// were seeded from Parakeet's table rather than measured on whisper's output
    /// (`tolerances_20260810.md`). Parakeet's env-gated real-engine WER run passed on the first
    /// real run (C2).
    ///
    /// So the two rows must not read as two equally exercised choices. This says which one has
    /// been run and which has not, and **claims nothing about quality in either direction** — not
    /// that Whisper is worse, not that it is better, and no figure anywhere, because there is no
    /// measured figure to give. The honest tradeoff between them is the spec's own taglines, which
    /// ``EnginePickerCopy`` already holds.
    public static func engineStatus(for engine: EngineCandidate) -> String {
        switch engine {
        case .parakeetV3:
            return "Measured. Vocca's accuracy checks have been run against this engine."
        case .whisperTurbo:
            return "Not yet measured. Vocca has never transcribed with this engine, so nothing "
                + "here is a claim about how well it works."
        }
    }

    /// The tier row's own label — the engine's name for its default tier, and the quantisation
    /// name for the others. ``EnginePickerCopy/tierLabel(for:)`` is the source; this only says
    /// which of the two a row heading needs.
    public static func name(for tier: EngineTier) -> String {
        tier == tier.engine.defaultTier
            ? tier.engine.displayName
            : "\(tier.engine.displayName) (\(EnginePickerCopy.tierLabel(for: tier)))"
    }

    /// A removal the store refused, in the store's own words — the ``AppsTabCopy/saveError``
    /// shape, for the same reason: a model management action that silently fails is one the user
    /// tries again next launch, having been told it worked.
    public static func removalFailed(_ message: String) -> String {
        "Couldn't remove the model: \(message)"
    }
}
