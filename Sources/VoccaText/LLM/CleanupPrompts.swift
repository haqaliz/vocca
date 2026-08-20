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

/// The pinned instruction strings the LLM cleanup providers ship — byte constants under the
/// copy-family discipline (``CleanupPrompts/ollama`` is byte-tested; review adjusts one string,
/// never the logic). Owned here, imported by both `ollama-provider` and `byok-provider`.
public enum CleanupPrompts {

    /// The cleanup-not-creativity instruction the Ollama provider prefixes to the transcript:
    /// rewrite the dictated text into clean, correctly punctuated prose; preserve meaning, names,
    /// code identifiers, numbers, and spelling exactly; remove fillers and stumbles; output only
    /// the cleaned text, no preamble or explanation. The provider appends `\n\nDICTATED TEXT:\n`
    /// and the transcript verbatim.
    public static let ollama =
        "You are a dictation cleanup assistant. Rewrite the dictated text into clean, "
        + "correctly punctuated prose. Preserve the meaning, names, code identifiers, "
        + "numbers, and spelling exactly. Remove fillers and stumbles. Output only the "
        + "cleaned text with no preamble or explanation."

    /// The system-instruction variant for a remote service: the same cleanup core as
    /// ``CleanupPrompts/ollama``, framed as the service's role rather than the assistant's. The
    /// `byok-provider` aspect consumes it as its system instruction.
    public static let byokSystem =
        "You are a dictation cleanup service. Rewrite the dictated text into clean, "
        + "correctly punctuated prose. Preserve the meaning, names, code identifiers, "
        + "numbers, and spelling exactly. Remove fillers and stumbles. Output only the "
        + "cleaned text with no preamble or explanation."
}
