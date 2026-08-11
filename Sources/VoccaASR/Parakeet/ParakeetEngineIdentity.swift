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

/// The identity this engine reports on every transcript — and the directory key the model store
/// uses (`ARCHITECTURE.md:489-490`), which is why the `id` must never drift from
/// `"parakeet-tdt-0.6b-v3"`: the manifest's `engineID` and the SDK's repo folder name both live
/// on it.
///
/// `isLocal == true` means no egress badge is ever drawn for this engine (`ARCHITECTURE.md:152-156`)
/// — and it is a fact about the implementation, not a claim: transcription runs entirely on
/// device, and `ModelHub.offlineMode` makes the SDK's own network path throw.
public enum ParakeetEngineIdentity {
    public static let parakeet = EngineIdentity(
        id: "parakeet-tdt-0.6b-v3",
        displayName: "Parakeet TDT 0.6B v3",
        isLocal: true)
}
