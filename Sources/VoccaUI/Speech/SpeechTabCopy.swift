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

/// The Speech tab's strings — the ones ``EnginePickerCopy`` does not already hold.
///
/// ``EnginePickerCopy`` is the spec's own surface (`PRODUCT_SPEC.md:254-262`: the radio glyphs,
/// the two engine names, the two taglines, the two affordances and the model-management line) and
/// is reused here verbatim rather than restated. This enum holds what the spec's mock does not
/// draw: the model-management controls it names in prose, and the sentences a running page needs
/// that a mock never has to.
public enum SpeechTabCopy {

    /// A removal the store refused, in the store's own words — the ``AppsTabCopy/saveError``
    /// shape, for the same reason: a model management action that silently fails is one the user
    /// tries again next launch, having been told it worked.
    public static func removalFailed(_ message: String) -> String {
        "Couldn't remove the model: \(message)"
    }
}
