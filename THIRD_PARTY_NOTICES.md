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

# Third-Party Notices

Vocca is licensed under Apache-2.0 (see `LICENSE`). This file records the third-party
artifacts that ship with it, their licences, and why each is here. Every entry is a
distribution obligation: a dependency is not added without one.

## whisper.cpp

- **License:** MIT
- **Upstream:** https://github.com/ggml-org/whisper.cpp
- **Vendored as:** the `WhisperCpp` binary target — the official v1.9.2 XCFramework,
  checksum-pinned in `Package.swift`.
- **What it is and why it ships:** the C inference engine behind Vocca's second ASR
  implementation (Whisper large-v3-turbo), so dictation can run entirely on-device with
  no GPU and no network.

## ggml

- **License:** MIT
- **Upstream:** https://github.com/ggml-org/ggml
- **Vendored as:** embedded inside the same `WhisperCpp` XCFramework (the `ggml*.h`
  headers and linked library).
- **What it is and why it ships:** whisper.cpp's tensor-computation backend — all of the
  engine's inference math runs on it, on CPU or Metal, with nothing leaving the machine.

## whisper GGUF weights (large-v3-turbo, turbo and q5_0 tiers)

- **License:** MIT (pending founder sign-off)
- **Upstream:** https://huggingface.co/ggerganov/whisper.cpp — OpenAI's Whisper models
  converted to ggml format for use with whisper.cpp; the repo's metadata declares
  `License: mit`.
- **Ships as:** the two GGUF weight files named by
  `Sources/VoccaASR/Models/Manifests/whisper-large-v3-turbo.json` and
  `whisper-large-v3-turbo-q5_0.json` — downloaded by the store at runtime, never
  vendored into the repository.
- **What it is and why it ships:** the neural-network weights the whisper.cpp engine
  runs on — the default large-v3-turbo tier and the constrained q5_0 tier.
- **Verification record:** `docs/planning/second-asr-engine/model-lifecycle/license_20260810.md`
