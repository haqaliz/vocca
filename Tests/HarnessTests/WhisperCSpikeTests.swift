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

import whisper
import XCTest

/// The C-ABI line of the second ASR engine (C3), proven on any machine: the
/// checksum-pinned whisper.cpp XCFramework resolves, builds, links, and exposes its C
/// surface to Swift. Nothing here touches a model file, a GPU, or a network — it is the
/// cheapest possible proof that the binary target in `Package.swift` is real, and it is
/// the first thing a clean checkout exercises.
///
/// The Parakeet adapter precedent applies: everything meaningful about the C API lives
/// above this seam, tested where it lives; these two tests only pin that the seam itself
/// exists and carries the constants and types the engine will build on.
final class WhisperCSpikeTests: XCTestCase {

    /// The constant the engine's sample-rate contract hangs on: whisper.cpp resamples
    /// everything to 16 kHz mono, and `VoccaCore.AudioBuffer` speaks that rate.
    func testWhisperSampleRateIsSixteenKilohertz() {
        XCTAssertEqual(WHISPER_SAMPLE_RATE, 16000)
    }

    /// `whisper_context_default_params()` returns the params struct by value — readable
    /// without a model file, without a context, without a GPU. Reading `use_gpu` proves
    /// the C struct imports with its field names intact.
    func testDefaultContextParamsReadUseGpuWithoutAModel() {
        let params = whisper_context_default_params()
        XCTAssertTrue(
            params.use_gpu,
            "the v1.9.2 default is use_gpu = true; a false default would mean the C ABI "
                + "read failed silently or the pinned artifact differs from upstream")
    }
}
