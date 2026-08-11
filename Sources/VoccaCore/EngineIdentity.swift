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

/// Which engine produced a transcript or failed to.
///
/// The machine's key is ``id`` — the stable identifier the model store keys its directory by (C8)
/// and persisted settings decode back (C14). ``displayName`` is for humans and may collide; two
/// engines may share a display name and must still be different values, because ``Transcript``
/// carries the identity and downstream code matches on it.
///
/// ``isLocal`` is the egress-badge flag (`ARCHITECTURE.md:152-156`): `false` means the audio or
/// text left the machine, and the UI must badge the point of use. It is part of the identity —
/// the same model hosted and on-device are not the same engine, and a hosted identity must not
/// compare equal to the local one, or the badge could be skipped by a lookup that found the
/// "same" engine.
public struct EngineIdentity: Sendable, Hashable, Codable {
    /// The stable machine key: `"parakeet-tdt-0.6b-v3"`, `"whisper-large-v3-turbo"`.
    public let id: String

    /// The human-readable name, for logs and settings.
    public let displayName: String

    /// `false` ⇒ this engine sends audio or text off the device, and an egress badge is mandatory.
    public let isLocal: Bool

    public init(id: String, displayName: String, isLocal: Bool) {
        self.id = id
        self.displayName = displayName
        self.isLocal = isLocal
    }
}
