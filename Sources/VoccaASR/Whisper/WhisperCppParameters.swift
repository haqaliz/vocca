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
import VoccaCore

/// The engine's transcription parameters — the pure, headless value the bridge (Phase 2) will
/// translate into the C API's `whisper_full_params`, with no C name in sight.
///
/// ``threads`` defaults to the thread-count rule ``defaultThreads(cpuCount:)`` applied to the
/// machine's live core count; ``language`` is `nil` for auto-detect (whisper picks the language
/// from the audio); ``tier`` selects the model artifact — the full fp16 `turbo` or the
/// 5-bit-quantized `turboQ5`, which the bridge maps to the C API's model file name. The tier is
/// part of the value so that equality — and later settings persistence — cannot conflate the two
/// engines.
public struct WhisperCppParameters: Sendable, Equatable {

    /// The model artifact tier. The set is exactly `{turbo, turboQ5}` — the two whisper.cpp
    /// `whisper-turbo` builds the bridge knows how to name; a third tier is a contract change.
    public enum Tier: Sendable, Equatable {
        /// The full fp16 turbo model (`whisper-turbo`).
        case turbo
        /// The 5-bit quantized turbo model (`whisper-turbo-q5_0`) — the smaller, faster artifact.
        case turboQ5
    }

    /// The thread-count rule (`plan_20260810.md` Phase 1): at most 8, leaving two cores for the
    /// system — a pure function so the formula is testable without the machine's core count.
    public static func defaultThreads(cpuCount: Int) -> Int {
        min(8, cpuCount - 2)
    }

    /// How many threads whisper runs with. Defaults from the live core count via
    /// ``defaultThreads(cpuCount:)``.
    public var threads: Int

    /// The language, or `nil` for auto-detect — the `language` C param's `"auto"` sentinel.
    public var language: String?

    /// Which model artifact to load. Defaults to the full fp16 ``Tier/turbo``.
    public var tier: Tier

    public init(
        threads: Int = Self.defaultThreads(cpuCount: ProcessInfo.processInfo.activeProcessorCount),
        language: String? = nil,
        tier: Tier = .turbo
    ) {
        self.threads = threads
        self.language = language
        self.tier = tier
    }
}
