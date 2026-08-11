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

/// The download window's state, driven by the session's events — a pure reducer, so the whole
/// UI decision table runs headlessly (`DownloadStateReducerTests`); the window itself is thin
/// glue over this type.
public enum DownloadState: Equatable, Sendable {
    case idle
    case downloading(Double)
    case committed
    case failed(String)
    case skipped
}

/// The transition table: every event × state rule the window obeys.
///
/// - Progress is clamped into 0...1 and never regresses (the store's own aggregate is
///   monotonic by construction; the reducer defends the bar against anything else).
/// - `.committed`, `.failed` and `.cancelled` are **terminal**: a session that has ended must
///   not be moved by straggler events.
/// - `.cancelled` reads as ``DownloadState/skipped`` — the user chose to stop.
public enum DownloadStateReducer {

    public static func reduce(_ state: DownloadState, event: ModelDownloadEvent) -> DownloadState {
        switch (state, event) {
        case (.committed, _), (.failed, _), (.skipped, _):
            return state
        case (.idle, .progress(let fraction)), (.downloading, .progress(let fraction)):
            return .downloading(min(1, max(0, fraction)))
        case (_, .committed):
            return .committed
        case (_, .failed(let reason)):
            return .failed(reason)
        case (_, .cancelled):
            return .skipped
        }
    }
}
