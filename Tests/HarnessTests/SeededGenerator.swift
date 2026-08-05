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

/// SplitMix64. Seeded and reproducible, because a randomised test that cannot be replayed reports a
/// failure nobody can reproduce — and `SystemRandomNumberGenerator` would make every run a
/// different test.
///
/// Shared rather than copied. Two suites now randomise: `SessionDecisionTests` over `decide`'s whole
/// input space, and `SessionMachineTests` over sequences of machine inputs. `project-skeleton`'s
/// carry-forward is explicit that five near-identical `packageRoot` walkers were five chances to
/// diverge silently, and a second private generator with a different constant would be the same
/// mistake in a place where the *seed* is the only thing making a failure reproducible.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
