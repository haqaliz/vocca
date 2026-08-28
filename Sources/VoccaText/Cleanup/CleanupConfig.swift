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

/// Which cleanup provider the user opted into — the `cleanup-config.json` `provider` field,
/// hand-edited until the Cleanup tab ships (`prd.md` M7).
///
/// `rules` is the zero-network default. `ollama` and `byok` are opt-in LLM rungs: the raw
/// strings are the file's contract (`rules`, `ollama`, `byok` — pinned byte-for-byte, so a
/// future settings surface writes exactly these).
public enum CleanupProviderKind: String, Codable, Sendable, Equatable {
    /// The deterministic rules engine — the default, zero network.
    case rules = "rules"
    /// A local LLM via Ollama (`ollama-provider`).
    case ollama = "ollama"
    /// The user's own cloud endpoint (`byok-provider`).
    case byok = "byok"
}

/// The Ollama block of `cleanup-config.json`: `{endpoint, model}`.
public struct OllamaCleanupConfig: Sendable, Equatable {
    /// The base Ollama endpoint, e.g. `http://localhost:11434`.
    public let endpoint: String
    /// The model to run, e.g. `llama3.1`.
    public let model: String

    public init(endpoint: String, model: String) {
        self.endpoint = endpoint
        self.model = model
    }
}

/// The BYOK block of `cleanup-config.json`: `{endpoint, model?}`.
public struct ByokCleanupConfig: Sendable, Equatable {
    /// The chat-completions endpoint — the v1 contract (`byok-provider`).
    public let endpoint: String
    /// The model to request, or `nil` to omit the field (some endpoints default their own).
    public let model: String?

    public init(endpoint: String, model: String?) {
        self.endpoint = endpoint
        self.model = model
    }
}

/// The hand-edited `cleanup-config.json` (`prd.md` M7): which provider runs, plus the Ollama and
/// BYOK blocks the LLM rungs need.
///
/// Both LLM rungs are opt-in, off by default, and never silently re-enabled (`ROADMAP.md:131`);
/// the absent file is the default configuration (rules, zero network) and the zero-network probe
/// runs exactly that path.
///
/// ## Tolerant decode
///
/// ``tolerantDecode(_:log:)`` reads the file without throwing — the `FileSystemDictionaryStore`
/// precedent. Unknown keys are ignored by construction; the blocks decode best-effort and mirror
/// the file (a `provider: ollama` file may still carry a valid `byok` block the future settings
/// surface round-trips). The one hard rule: an invalid **selected** block — `ollama` without a
/// model, `byok` without a dialable endpoint, a wrong-typed field, an endpoint with no
/// scheme/host — and an unknown `provider` kind each degrade the whole config to `.rules` with
/// exactly one loud log: a user who hand-edits badly must be told, never silently reset
/// (`spec.md:51-55`).
public struct CleanupConfig: Sendable, Equatable {

    /// The selected provider — the resolver's decision input.
    public let provider: CleanupProviderKind

    /// The Ollama block, when the file carries a valid one.
    public let ollama: OllamaCleanupConfig?

    /// The BYOK block, when the file carries a valid one.
    public let byok: ByokCleanupConfig?

    /// The shipped Ollama endpoint — the default when the file omits the field (`prd.md` Data
    /// Model).
    public static let defaultOllamaEndpoint = "http://localhost:11434"

    /// The default configuration: rules, zero network.
    public static let defaultConfig = CleanupConfig(provider: .rules, ollama: nil, byok: nil)

    /// Whether `string` is a dialable HTTP(S) endpoint — the check both providers' transports
    /// speak. `URL(string:)` alone is too permissive: it percent-encodes a scheme-less relative
    /// string like `"not a url"` into a URL, which is exactly the hand-edit mistake an endpoint
    /// field must reject.
    public static func isDialableEndpoint(_ string: String) -> Bool {
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased() else {
            return false
        }
        return (scheme == "http" || scheme == "https") && url.host != nil
    }

    public init(
        provider: CleanupProviderKind,
        ollama: OllamaCleanupConfig?,
        byok: ByokCleanupConfig?
    ) {
        self.provider = provider
        self.ollama = ollama
        self.byok = byok
    }

    /// The file's bytes for this config — the encode half of ``tolerantDecode(_:log:)``, and the
    /// only thing that ever writes `cleanup-config.json`.
    ///
    /// Untyped JSON (`JSONSerialization`) rather than a synthesized `Codable` conformance, for the
    /// same reason the decode is: this file is a **hand-edited** surface, and the shape is the
    /// contract — the three raw provider strings, an `ollama` block with `endpoint` and `model`,
    /// a `byok` block with `endpoint` and an optional `model`. A synthesized encoder would emit
    /// whatever the Swift type happens to look like next year.
    ///
    /// **Both blocks are written whenever they exist**, not just the selected one: switching to
    /// the rules rung must not cost the user the endpoint they typed on the cloud one, which is
    /// exactly what ``tolerantDecode(_:log:)`` already promises a round trip preserves.
    ///
    /// **A `nil` model is an absent key, not a null.** The decode reads a missing `model` as "the
    /// endpoint defaults its own", and `null` is a wrong-typed field a hand-edit would have to
    /// puzzle over.
    ///
    /// The formatting is the hand-editability contract: `.sortedKeys` so two saves of the same
    /// config produce the same bytes, `.prettyPrinted` so a person can read it, and
    /// `.withoutEscapingSlashes` so an endpoint reads as an endpoint rather than as
    /// `http:\/\/localhost:11434`.
    ///
    /// **No key material is representable here.** The BYOK key lives in the Keychain behind the
    /// `KeyProvider` seam; ``ByokCleanupConfig`` has no field for one, and
    /// `CleanupConfigStoreTests` asserts the written document carries none.
    public func encoded() throws -> Data {
        var object: [String: Any] = ["provider": provider.rawValue]
        if let ollama {
            object["ollama"] = ["endpoint": ollama.endpoint, "model": ollama.model]
        }
        if let byok {
            var block: [String: Any] = ["endpoint": byok.endpoint]
            if let model = byok.model {
                block["model"] = model
            }
            object["byok"] = block
        }
        return try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    /// Decode `data` tolerantly: never throws, unknown keys ignored, and every invalid selected
    /// block degrades to the rules default with exactly one `log` call.
    ///
    /// The decode reads untyped JSON (`JSONSerialization`) rather than a synthesized `Codable`
    /// conformance, because the file is hand-edited and its failure modes are *content* failures
    /// — an unknown kind string, a missing required field, a wrong-typed field — that a strict
    /// decoder would turn into a throw. Every one of them is a policy decision, made here where
    /// the log is available, not in a throwing decoder with no access to the logger.
    public static func tolerantDecode(
        _ data: Data,
        log: @escaping @Sendable (String) -> Void
    ) -> CleanupConfig {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            log("cleanup-config: the file's top level is not a JSON object; using the rules provider")
            return .defaultConfig
        }

        let kind: CleanupProviderKind
        var kindIssue: String?
        switch object["provider"] {
        case nil:
            kind = .rules
        case let raw as String:
            switch raw {
            case CleanupProviderKind.rules.rawValue:
                kind = .rules
            case CleanupProviderKind.ollama.rawValue:
                kind = .ollama
            case CleanupProviderKind.byok.rawValue:
                kind = .byok
            default:
                kind = .rules
                kindIssue = "unknown provider kind '\(raw)'"
            }
        default:
            kind = .rules
            kindIssue = "provider is not a string"
        }

        let ollama = Self.decodeOllamaBlock(object["ollama"])
        let byok = Self.decodeByokBlock(object["byok"])

        switch kind {
        case .rules:
            if let kindIssue {
                log("cleanup-config: \(kindIssue); using the rules provider")
            }
            return CleanupConfig(provider: .rules, ollama: ollama, byok: byok)
        case .ollama:
            guard let ollama else {
                log("cleanup-config: the ollama block is invalid (a model is required); using the rules provider")
                return .defaultConfig
            }
            return CleanupConfig(provider: .ollama, ollama: ollama, byok: byok)
        case .byok:
            guard let byok else {
                log("cleanup-config: the byok block is invalid (a dialable endpoint is required); using the rules provider")
                return .defaultConfig
            }
            return CleanupConfig(provider: .byok, ollama: ollama, byok: byok)
        }
    }

    /// The Ollama block, or `nil` when it is missing or invalid (no model, or an endpoint that
    /// is not dialable).
    private static func decodeOllamaBlock(_ raw: Any?) -> OllamaCleanupConfig? {
        guard let block = raw as? [String: Any],
            let model = block["model"] as? String, !model.isEmpty
        else {
            return nil
        }
        let endpoint: String
        if let rawEndpoint = block["endpoint"] {
            guard let string = rawEndpoint as? String, !string.isEmpty,
                Self.isDialableEndpoint(string)
            else {
                return nil
            }
            endpoint = string
        } else {
            endpoint = Self.defaultOllamaEndpoint
        }
        return OllamaCleanupConfig(endpoint: endpoint, model: model)
    }

    /// The BYOK block, or `nil` when it is missing or invalid (no dialable endpoint).
    private static func decodeByokBlock(_ raw: Any?) -> ByokCleanupConfig? {
        guard let block = raw as? [String: Any],
            let endpoint = block["endpoint"] as? String, !endpoint.isEmpty,
            Self.isDialableEndpoint(endpoint)
        else {
            return nil
        }
        return ByokCleanupConfig(endpoint: endpoint, model: block["model"] as? String)
    }
}
