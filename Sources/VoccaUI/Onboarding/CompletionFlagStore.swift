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

/// **The completion flag's persistence seam — the one file in `Sources/` permitted to name
/// `UserDefaults`** (the UserDefaults family's entry in `InjectionSeamBoundaryTests`' seam
/// table). A second `UserDefaults`-naming file in the tree would be a persisted-state decision
/// that escaped the headless suite forever.
///
/// ## Deliberate divergence from the house persistence idiom
///
/// The dictionary and cleanup-config stores are JSON behind one-file FileManager seams — the
/// atomic temp-write-then-rename idiom. This store deliberately diverges: the `main()` show
/// decision needs a **synchronous** read (window-server rule: `main()` shows, `configure` never
/// constructs a window — `AppBootstrap.swift:388-430`), and UserDefaults is synchronous by
/// nature. The flag is a scalar Boolean, not a hand-editable document, so nothing the FileManager
/// idiom buys — hand-editable files, version control — is lost by giving it up. The seam family
/// is new precisely because the idiom is, and the lint table amendment ships in the same commit
/// (`plan_20260827.md` §2, step 3).
///
/// ## Read contract
///
/// ``isComplete()`` answers `false` when the flag is absent — a fresh install has never run
/// TRY IT, so the window re-shows at launch until completion (prd.md M4; the "re-shows until
/// done" decision). The read never throws and never writes.
///
/// ## Write contract
///
/// ``markComplete()`` is idempotent and **never throws**: a best-effort write, because a failed
/// write fails in the safe direction — the window re-shows next launch, and the only cost of a
/// lost flag is one more run of the five-step flow. There is no throwing form, and there must
/// never be one: TRY IT success is the only writer (prd.md R4), and a write the caller must
/// handle would be a code path where the user can be told the wrong thing about their onboarding.
public struct CompletionFlagStore {
    /// The frozen key the flag lives under — pinned by `CompletionFlagStoreTests` so the
    /// `main()` show decision, the root composition and any future surface read the same key.
    public static let key = "onboarding.complete"

    private let defaults: UserDefaults
    private let key: String

    /// A store over `defaults` — `.standard` in the app, a scoped suite in tests (never
    /// `UserDefaults.standard` from the test suite, so the user's real defaults are untouchable).
    public init(
        defaults: UserDefaults = .standard,
        key: String = CompletionFlagStore.key
    ) {
        self.defaults = defaults
        self.key = key
    }

    /// Whether onboarding has been completed: `false` until ``markComplete()`` has been
    /// persisted. Synchronous — the property the `main()` decision is built on.
    public func isComplete() -> Bool {
        defaults.bool(forKey: key)
    }

    /// Persist "onboarding complete". Idempotent, best-effort, never throws: a failed write
    /// means the window re-shows next launch — the safe direction, and the only cost of a lost
    /// flag is one more run of the flow.
    public func markComplete() {
        defaults.set(true, forKey: key)
    }
}