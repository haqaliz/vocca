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

/// The one named table of the cleanup eval harness's **provisional** targets
/// (`eval-harness/plan_20260815.md` Phase 8; the `ProvisionalTolerances` precedent in
/// `LatencyBenchmarkTests`).
///
/// Both figures are **provisional by design**: they are the P1 gate's instruments
/// (`ROADMAP.md:137` — ≥ 80% blind pairwise preference; `ARCHITECTURE.md:310` — 10 ms rules-path
/// budget), recorded not proven. CI asserts the *mechanism* over stand-in pairs and never
/// produces a product number; the founder's first F2 run (`docs/SMOKE_CHECKLIST.md` step 73)
/// re-baselines the numbers via the measure → margin → founder-signed procedure in
/// `docs/planning/deterministic-cleanup/eval-harness/tolerances_20260815.md`. They live in
/// exactly this file — the B6 scan pins the `0.80` sighting to this file and its pinning test —
/// and a re-baseline lands here, in exactly one place.
enum ProvisionalCleanupTargets {
    /// The P1 gate's blind pairwise preference minimum: cleaned-over-raw ≥ 80% on the held-out
    /// set (`ROADMAP.md:137`).
    static let preferenceMinimum = 0.80

    /// The rules-path p50 budget (`ARCHITECTURE.md:310` — "cleanup gets 10 ms and not 200").
    static let rulesPathP50 = Duration.milliseconds(10)
}
