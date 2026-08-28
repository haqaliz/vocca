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

/// **The Cleanup tab's copy** — every user-visible string, lifted from `PRODUCT_SPEC.md:263-274`
/// verbatim (the ``BadgeCopy``/``EnginePickerCopy`` rule: pure constants and pure functions, no
/// AppKit, so the contract test runs every string against the spec headlessly).
///
/// This is the surface `ROADMAP.md` principle 2 says must survive an audit of the actual code
/// paths, so its wording is the product's own rather than a paraphrase — in particular the
/// ⚠️ line, which is what a user reads before their text leaves the machine.
///
/// Character fidelity: the warning glyph is the spec's own U+26A0 + U+FE0F (the *emoji*
/// presentation — a bare U+26A0 renders as a thin monochrome outline that reads as decoration),
/// the ellipsis is U+2026, and the radio glyphs are not restated at all — ``EnginePickerCopy``
/// already pins the same two characters from the Speech mock, and a second pair of literals is how
/// one of them drifts.
public enum CleanupTabCopy {

    // MARK: - The three rungs (`PRODUCT_SPEC.md:266-268`)

    /// The selected row's radio glyph — the Speech tab's pin, reused rather than restated.
    public static var radioSelected: String { EnginePickerCopy.radioSelected }

    /// The unselected row's radio glyph — likewise.
    public static var radioUnselected: String { EnginePickerCopy.radioUnselected }

    /// The rung's name, `PRODUCT_SPEC.md:266-268` verbatim.
    ///
    /// Deliberately **not** the provider's ``ProviderIdentity/displayName``. The identity names
    /// the implementation ("Deterministic rules", "Ollama", "BYOK") and is what the "Using" line
    /// reports about what is actually running; these are what a person picking a rung reads. The
    /// two are allowed to differ and the tab shows both, because the file's choice and the
    /// resolved provider are two facts.
    public static func rungName(_ kind: CleanupProviderKind) -> String {
        switch kind {
        case .rules: return "Basic"
        case .ollama: return "Local AI"
        case .byok: return "Cloud (BYOK)"
        }
    }

    /// What the rung does, `PRODUCT_SPEC.md:266-268` verbatim.
    public static func rungDetail(_ kind: CleanupProviderKind) -> String {
        switch kind {
        case .rules: return "Removes fillers, adds punctuation."
        case .ollama: return "Better rewriting. Needs Ollama."
        case .byok: return "Your own API key."
        }
    }

    /// **Where the text goes** — the spec's third column, and the reason it is a column of its own.
    ///
    /// Every rung states it, including the two that keep the text on the machine: a page where
    /// only the dangerous row carries a note is a page where the absence of a note means nothing.
    public static func rungEgressNote(_ kind: CleanupProviderKind) -> String {
        switch kind {
        case .rules: return "Instant, on-device."
        case .ollama: return "On-device."
        case .byok: return "\(cloudWarningGlyph) Text leaves your Mac."
        }
    }

    /// The warning sign the cloud rung leads with (`PRODUCT_SPEC.md:268`): U+26A0 WARNING SIGN +
    /// U+FE0F VARIATION SELECTOR-16, byte-pinned in `CleanupTabCopyTests`.
    public static let cloudWarningGlyph = "⚠️"

    /// The dictionary affordance, `PRODUCT_SPEC.md:270` verbatim — the ellipsis is U+2026.
    public static let customDictionaryButton = "Custom dictionary…"

    /// The hint beside it, `PRODUCT_SPEC.md:270` verbatim.
    public static let customDictionaryHint = "names, jargon, replacements"

    // MARK: - What Vocca is using now

    /// The heading of the line reporting the resolved provider.
    public static let usingLabel = "Using"

    /// The local answer — the sentence this whole tab exists to be able to say truthfully.
    public static let runsOnThisMac = "Runs on this Mac. Nothing is sent anywhere."

    /// The network answer, naming where the text goes. The endpoint, never the key.
    public static func textIsSentTo(_ endpoint: String) -> String {
        "Text is sent to \(endpoint)."
    }

    /// The network answer when the resolver could not name a destination.
    ///
    /// A provider that declares `requiresNetwork` and has no endpoint beside it still sends text
    /// somewhere, and the honest line says so rather than falling silent — falling silent here
    /// would render the reassuring local sentence in the one case Vocca knows least about.
    public static let textLeavesThisMac = "Text is sent off this Mac."

    /// **When a change takes effect.**
    ///
    /// The resolver is resolve-once: the provider is built at launch and a mid-session swap is
    /// structurally impossible, which is what makes "a provider cannot change under a dictation"
    /// true. The cost is that a choice made here is not the choice running now, and a page that
    /// implied otherwise would have someone dictate something sensitive through the provider they
    /// believed they had just left.
    public static let appliesAtNextLaunch =
        "A new choice takes effect the next time Vocca restarts. Until then the line above is "
        + "what is actually cleaning your text."

    /// **Where the BYOK key lives** (R4) — and, by saying it, where it does not.
    public static let keychainNote =
        "Vocca reads your API key from the macOS Keychain. It is never written to Vocca's "
        + "settings file."

    // MARK: - The one-time cloud confirmation (`PRODUCT_SPEC.md:273`)

    /// The dialog's title. Asks the question rather than announcing a setting: the user is about
    /// to make the one choice in this app that moves their words off their own machine.
    public static let cloudConfirmationTitle = "Send your text to a cloud service?"

    /// **What gets sent — exactly.**
    ///
    /// The spec asks for a dialog naming exactly what leaves, and this is measured against what
    /// `BYOKCleanupProvider` actually puts on the wire: the transcript text and a fixed
    /// instruction prompt as the two chat messages, the model name, and the key in an
    /// `Authorization` header.
    ///
    /// **The audio sentence is the load-bearing one.** "Cloud cleanup" sounds to most people like
    /// it might mean their voice, and it never does — Vocca transcribes on the machine and only
    /// the resulting text is sent. Saying so is the difference between a dialog that informs a
    /// decision and one that just alarms, and a dialog people dismiss unread is the same as no
    /// dialog at all.
    public static func cloudConfirmationBody(endpoint: String) -> String {
        """
        The text of every dictation will be sent to \(endpoint) to be rewritten, along with your         API key and the name of the model you chose.

        Your audio is never sent. Vocca transcribes on this Mac, and only the resulting text         leaves it. Nothing else — no file names, no other application's contents, no recordings.

        You can switch back to Basic at any time.
        """
    }

    /// The accepting button. Says what it does, so a person skimming the two buttons still learns
    /// the outcome — the ``SpeechTabCopy/keepItButton`` argument, on a dialog where "OK" and
    /// "Cancel" are the two words that tell you least.
    public static let cloudConfirmAccept = "Send my text"

    /// The declining button — and it names what staying means, not merely that nothing happens.
    public static let cloudConfirmDecline = "Keep everything on this Mac"

    // MARK: - Field labels

    /// The endpoint field's label.
    public static let endpointLabel = "Endpoint"

    /// The model field's label.
    public static let modelLabel = "Model"

    /// The note under the BYOK model field: an empty model is a real choice, not an omission.
    public static let modelOptionalNote = "Leave empty to let the endpoint choose its own model."

    // MARK: - Refusals and failures

    /// A rung that cannot be written yet, naming the field that is missing.
    ///
    /// Says what to do rather than only what failed — a control that refuses with nothing beside
    /// it teaches a user the app is broken, which is the argument
    /// ``SettingsCopy/hotkeyNotRebindable`` already makes.
    public static func missingFields(_ kind: CleanupProviderKind) -> String {
        switch kind {
        case .rules:
            // Unreachable: the local default needs no configuration and is never refused. Spelled
            // rather than defaulted so a fourth rung cannot arrive without its own sentence.
            return ""
        case .ollama:
            return "Local AI needs an Ollama endpoint and the name of a model to run."
        case .byok:
            return "Cloud needs the endpoint your API key belongs to."
        }
    }

    /// A write the store refused, in the store's own words — the ``AppsTabCopy/saveError`` shape,
    /// for the same reason: a cleanup choice that silently fails to save is one the user makes
    /// again next launch, having been told it worked. On the cloud rung that is the difference
    /// between believing text stays on the Mac and it not.
    public static func saveFailed(_ message: String) -> String {
        "Couldn't save the cleanup choice: \(message)"
    }
}
