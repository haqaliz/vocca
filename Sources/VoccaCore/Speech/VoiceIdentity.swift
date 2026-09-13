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

/// Which synthesizer and voice produced speech chunks.
///
/// The machine key is ``engineID`` — the stable identifier of the engine (`"kokoro-82m"`,
/// `"system"`). ``voiceName`` is the named voice within the engine when it has one
/// (`"af_heart"`), and `nil` when it does not: the optionality lives in the vocabulary, not in
/// a sentinel, so a caller can tell "an engine with no named voices" from "a voice nobody
/// named". Two synthesizers may share a voice name across engines and must still be different
/// values — ``identity`` is the speech twin of ``EngineIdentity``, and downstream attribution
/// matches on the whole value.
public struct VoiceIdentity: Sendable, Hashable {
    /// The stable engine key: `"kokoro-82m"`, `"system"`, a hosted provider's id later.
    public let engineID: String

    /// The named voice within the engine, when it has one; `nil` when it does not.
    public let voiceName: String?

    public init(engineID: String, voiceName: String?) {
        self.engineID = engineID
        self.voiceName = voiceName
    }
}