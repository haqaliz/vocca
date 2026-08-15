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

/// Which cleanup provider is at work, on the transcript or in a log.
///
/// ``id`` is the stable machine key; ``displayName`` is for humans and may collide — two providers
/// may share a display name and must still be different values, because attribution matches on the
/// identity, not the name.
///
/// This is a **new type, not a rename of ``EngineIdentity``** (`EngineIdentity.swift:27-41`). The
/// ASR family's ``EngineIdentity/isLocal`` is the engine domain's egress flag — part of the
/// identity, because the same model hosted and on-device are not the same engine. The cleanup
/// family's egress flag is the protocol's ``CleanupProvider/requiresNetwork``
/// (`ARCHITECTURE.md:273-277`), not a property of the identity: a provider's offline-ness is the
/// seam's contract with the caller, so it lives on the seam. Sharing ``EngineIdentity`` would
/// import the engine domain's flag into a family whose egress story is different; renaming it
/// would churn C2/C3 attribution for no semantic gain. A future provider that is also an engine
/// carries two identities — accepted; the domains stay separate.
public struct ProviderIdentity: Sendable, Hashable, Codable {
    /// The stable machine key: `"rules-cleanup"`, `"ollama-cleanup"`, `"byok-cleanup"`.
    public let id: String

    /// The human-readable name, for logs and settings.
    public let displayName: String

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}
