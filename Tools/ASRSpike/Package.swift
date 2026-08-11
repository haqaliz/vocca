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

// swift-tools-version: 6.0

import PackageDescription

/// The F1 spike probe — deliberately NOT a package target of the Vocca package (it is the
/// repository's first consumer of FluidAudio, and its whole job is to be thrown away after
/// the numbers are recorded; `docs/planning/local-asr/parakeet-engine/spike_20260809.md` is
/// the deliverable, not this package).
let package = Package(
    name: "ASRSpike",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4"),
    ],
    targets: [
        .executableTarget(
            name: "ASRSpike",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]),
    ]
)
