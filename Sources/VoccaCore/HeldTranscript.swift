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

/// A transcript the ladder could not deliver, held for the user — the failsafe's payload and
/// the floor of I1.
///
/// When every rung fails, the text is *durably held and visibly presented*, never dropped. This
/// struct is what the recovery journal persists and what the FAILSAFE window renders; both speak
/// the same vocabulary because both speak this type (the `ModelDownloadSession` pattern: the
/// core owns the contract, adapters and UI implement it).
///
/// `capturedAt` is a reading from the injected ``MonotonicClock``, never a wall clock — the
/// convention this module applies to every time value, for the same reason every other one does:
/// a wall-clock reading would lie across an NTP step or a daylight-saving change, and would read
/// *forward* across the machine sleeping. The FAILSAFE window's "captured at" note
/// (`PRODUCT_SPEC.md:117`, shown after relaunch) must say "this many seconds ago" honestly no
/// matter what the clock did in between — monotonic deltas are the only reading that does.
/// (`Date` is unreachable in this module anyway.)
///
/// `text` is carried verbatim — never rewritten, never truncated. The failsafe is not a cleanup
/// stage; it is custody.
public struct HeldTranscript: Sendable, Equatable {
    /// The undelivered text, exactly as the ladder received it.
    public var text: String
    /// Why the ladder gave up — the window's copy-table key (`PRODUCT_SPEC.md:111-113`).
    public var reason: FailsafeReason
    /// The focused application's name when the ladder ran — the "{app}" in "Couldn't type into
    /// {app}" (`PRODUCT_SPEC.md:112`). `nil` when the name could not be resolved; the window
    /// falls back to a name-less phrasing.
    public var targetAppName: String?
    /// The monotonic instant the transcript was captured, for the "captured at" note.
    public var capturedAt: Duration

    /// A transcript as the failsafe hand-off receives it. Plain memberwise and public — the
    /// journal and the window construct these, and the durability tests assert on them.
    public init(text: String, reason: FailsafeReason, targetAppName: String?, capturedAt: Duration) {
        self.text = text
        self.reason = reason
        self.targetAppName = targetAppName
        self.capturedAt = capturedAt
    }
}
