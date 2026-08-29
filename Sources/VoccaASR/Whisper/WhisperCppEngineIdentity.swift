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

/// The identity this engine reports on every transcript. The `id` must not drift from
/// `"whisper-large-v3-turbo"` because it is the machine key `EngineIdentity.swift:28`'s doc names
/// and the value every whisper transcript is attributed to.
///
/// It is **not** the model store's directory key, though this comment said it was until
/// 2026-08-28. One identity signs both whisper tiers — turbo and its q5_0 quantisation are the
/// same engine — so keying storage by it gave two different artifacts one directory and one
/// verified marker. Storage is keyed by tier (``EngineTier/storageID``); attribution is keyed by
/// engine, which is this. Both tiers' transcripts still carry this identity, and that is correct.
///
/// `isLocal == true` means no egress badge is ever drawn for this engine (`ARCHITECTURE.md:152-156`)
/// — and it is a fact about the implementation, not a claim: transcription runs entirely on
/// device, and the engine's only contact with the outside world is the injected model store.
public enum WhisperCppEngineIdentity {
    public static let whisper = EngineIdentity(
        id: "whisper-large-v3-turbo",
        displayName: "Whisper turbo",
        isLocal: true)
}
