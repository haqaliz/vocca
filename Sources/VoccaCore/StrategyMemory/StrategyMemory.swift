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

/// The one named table of the core-memory aspect's provisional target
/// (`core-memory/plan_20260827.md`; the ``WarmStartTargets`` single-source precedent).
///
/// The window is **provisional by design**: it is R4's decay schedule (`prd.md` — a demoted rung
/// is re-included once after ~7 days), recorded not proven. It lives in exactly this file — the
/// single-source scan in ``StrategyMemoryProjectionTests`` pins the literal here — and a
/// re-baseline from the founder's real matrix run lands here, in exactly one place.
public enum StrategyMemoryTargets {
    /// How long a demoted rung stays demoted before it may be re-probed once. Inclusive: at
    /// exactly `now == window` the rung is eligible again. PROVISIONAL — the `matrix-smoke` run
    /// re-baselines it in exactly this place.
    public static let reprobeWindowSeconds: UInt64 = 604_800
}