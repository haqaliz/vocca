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

/// Which cleanup provider the user opted into — the `cleanup-config.json` `provider` field.
///
/// `rules` is the zero-network default. `ollama` and `byok` are opt-in LLM rungs: the raw strings
/// are the file's contract (`rules`, `ollama`, `byok` — pinned byte-for-byte), and the Cleanup tab
/// writes exactly these.
///
/// ## Why this lives in the core
///
/// It shipped in `VoccaText` beside `CleanupConfig`, which was right while the only reader was the
/// resolver. The Cleanup tab made it wrong: `VoccaUI` may import `VoccaCore` and nothing else
/// (`ModuleBoundaryTests` rule 4), so a settings surface offering these three rungs could either
/// mint a second three-case enum — a parallel dialect, the exact thing that lets a file format and
/// a radio button drift apart — or the vocabulary could move to the module both sides already
/// depend on. It moved. `CleanupConfig` still owns the *file*: the decode, the degrade policy and
/// the blocks. This is only the word for which rung.
///
/// `CaseIterable` so a rung added here reaches every surface that enumerates them — the tab's copy
/// coverage test fails on a rung with no words, rather than the rung rendering as a blank row.
public enum CleanupProviderKind: String, Codable, Sendable, Equatable, CaseIterable {
    /// The deterministic rules engine — the default, zero network.
    case rules = "rules"
    /// A local LLM via Ollama (`ollama-provider`).
    case ollama = "ollama"
    /// The user's own cloud endpoint (`byok-provider`).
    case byok = "byok"

    /// Whether choosing this rung sends text off the device.
    ///
    /// A property of the *choice*, distinct from ``CleanupProvider/requiresNetwork``, which is a
    /// property of a resolved provider. The tab needs the first before anything is resolved — it
    /// is what decides whether picking the rung has to be confirmed — and the two must never be
    /// confused: an `ollama` rung that degraded to rules resolves as local while the choice the
    /// user made was still a local one either way. Ollama is on-device
    /// (`PRODUCT_SPEC.md:267`), so only the cloud rung answers `true`.
    public var sendsTextOffTheMac: Bool {
        switch self {
        case .rules, .ollama: return false
        case .byok: return true
        }
    }
}

/// **The Cleanup tab's view of `cleanup-config.json`** — the fields the surface edits, as plain
/// values.
///
/// A draft rather than a `CleanupConfig`, because `CleanupConfig` owns the file's decode and lives
/// in `VoccaText`, which `VoccaUI` may not import. The composition root translates between the
/// two, in one place, and it is still one file underneath: the tab writes what the resolver reads,
/// never a second copy that can drift from it (`spec.md` R2).
///
/// **Both blocks are always carried**, whichever rung is selected — so switching to the local
/// default and back does not cost a user the endpoint they typed. That is the same round-trip
/// `CleanupConfig.encoded()` preserves on disk.
///
/// **There is no field for a key, and there must never be one.** The BYOK key lives in the
/// Keychain behind the `KeyProvider` seam; `CleanupTabReducerTests` asserts the absence
/// structurally, because a `key` field here would be one edit away from a plain-text file in
/// Application Support.
public struct CleanupConfigDraft: Sendable, Equatable {
    /// The rung the file names.
    public var provider: CleanupProviderKind
    /// The Ollama endpoint, as the user is editing it.
    public var ollamaEndpoint: String
    /// The Ollama model, as the user is editing it.
    public var ollamaModel: String
    /// The BYOK chat-completions endpoint, as the user is editing it.
    public var byokEndpoint: String
    /// The BYOK model, as the user is editing it. Empty means "let the endpoint default its own",
    /// which is what an absent `model` field means in the file.
    public var byokModel: String

    /// The draft a tab opens with before anything has been read: the zero-network default, and no
    /// claim about either block.
    public static let empty = CleanupConfigDraft(provider: .rules)

    public init(
        provider: CleanupProviderKind,
        ollamaEndpoint: String = "",
        ollamaModel: String = "",
        byokEndpoint: String = "",
        byokModel: String = ""
    ) {
        self.provider = provider
        self.ollamaEndpoint = ollamaEndpoint
        self.ollamaModel = ollamaModel
        self.byokEndpoint = byokEndpoint
        self.byokModel = byokModel
    }

    /// Whether `kind` has everything the file needs to decode it.
    ///
    /// Mirrors `CleanupConfig`'s own block rules — an Ollama block needs a model, a BYOK block
    /// needs an endpoint — because a rung written without them degrades the *whole* config to
    /// rules with a loud log, leaving the radio on one provider and Vocca on another.
    ///
    /// **Shape is not checked here, only presence.** Whether an endpoint is dialable is
    /// `CleanupConfig.isDialableEndpoint`'s question and needs `URL`, which this module does not
    /// have; a bad shape therefore surfaces as a save failure from the store, which is the same
    /// message path as any other write that did not land.
    public func isConfigured(_ kind: CleanupProviderKind) -> Bool {
        switch kind {
        case .rules:
            return true
        case .ollama:
            return !ollamaEndpoint.isBlank && !ollamaModel.isBlank
        case .byok:
            return !byokEndpoint.isBlank
        }
    }
}

extension String {
    /// Whether the string is empty or nothing but whitespace. Spelled here rather than with
    /// `trimmingCharacters(in:)`, which is Foundation's and this module has none.
    var isBlank: Bool {
        allSatisfy { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }
    }
}
