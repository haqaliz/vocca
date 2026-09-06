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

/// The daily-use ledger on disk — `<directory>/usage.json` — and **the one file in `VoccaUsage`
/// permitted to name `FileManager`** (the `usage` row in `InjectionSeamBoundaryTests`' per-seam
/// FileManager table, beside the journal, dictionary, config and strategy seams' adapters).
///
/// It is the `PersistentInjectionStrategyStore` shape, deliberately: a ``UsageStore`` over a
/// directory, with the decisions — version tolerance, per-row corruption skips, the bucket-bounds
/// check — belonging above the file system where a headless suite can drive them, and nothing but
/// path resolution and raw I/O below.
///
/// ## This is a stub, and only the module and the path are real yet
///
/// The persisted format — the versioned, `.sortedKeys` JSON, the per-row decode, the three
/// tolerance gates and the atomic temp-write→`replaceItemAt` commit — **lands in the next slice**
/// (`plan_20260907.md` Phase 3). Until it does, ``load()`` answers the empty window and
/// ``save(_:)`` persists nothing. That is a deliberately visible falsehood rather than a hidden
/// one: the very next commit is a failing test that a saved window does not come back.
///
/// The module and its lint rows exist first, alone, because adding a module touches
/// `Package.swift`, the module-boundary table and two seam tables at once — so a red CI has one
/// cause here rather than five later.
public actor PersistentUsageStore: UsageStore {
    /// The directory the ledger lives in. The file is always `<directory>/usage.json`.
    public let directory: URL

    /// The ledger's file name, in one place, because it is the persisted spelling: changing it
    /// orphans every existing install's history rather than migrating it.
    public static let fileName = "usage.json"

    /// The file itself — `<directory>/usage.json`.
    public var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    /// A store over `directory`. The directory is created on the first persist; a store over a
    /// directory that does not exist is an empty history, not an error.
    public init(directory: URL) {
        self.directory = directory
    }

    /// A store over the default location (`ARCHITECTURE.md` §12's Application Support table):
    /// `~/Library/Application Support/Vocca/usage.json`. The fallback keeps the store working
    /// even if the Application Support directory is unavailable to resolve — a defensive default,
    /// not a decision about where the history lives.
    public init() {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
        self.init(directory: base.appendingPathComponent("Vocca"))
    }

    /// The empty window, always, until Phase 3 reads the file. A missing file is already the
    /// empty window silently, so this stub is honest about a first run and dishonest about every
    /// other one — which is exactly what the next commit's failing test says.
    public func load() async -> UsageWindow {
        UsageWindow()
    }

    /// Persists nothing yet. It throws nothing because there is no persist to fail; the atomic
    /// commit and its failure path arrive with the format.
    public func save(_ window: UsageWindow) async throws {}
}
