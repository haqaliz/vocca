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

import VoccaCore

/// The recovery journal's persisted entry — what ``HeldTranscript`` becomes when the failsafe
/// hand-off is made durable.
///
/// The entry carries everything the held transcript carries — text, reason, target app name,
/// and the monotonic captured-at instant (`PRODUCT_SPEC.md:117`'s "captured at" note survives
/// the relaunch because it is persisted here) — plus the **write ordinal** the store needs for
/// eviction ordering: a monotonically increasing integer assigned by ``RecoveryJournal``, so
/// "oldest first" is a comparison of ordinals and nothing else. The ordinal is deterministic:
/// it is the journal's own counter, rebuilt from the entries already on disk after a relaunch.
///
/// The `capturedAt` instant is persisted as its two `Duration` components rather than as a wall
/// clock — the module's convention, for the same reason every other time value carries it: a
/// wall-clock reading would lie across an NTP step or a daylight-saving change. The components
/// are exact: `Duration.components` and `Duration(secondsComponent:attosecondsComponent:)`
/// round-trip without loss.
public struct JournalEntry: Codable, Equatable, Sendable {
    /// The write ordinal — monotonically increasing, assigned by the journal, the eviction key.
    public let id: Int
    /// The undelivered text, exactly as the ladder received it — never rewritten.
    public let text: String
    /// Why the ladder gave up — the window's copy-table key.
    public let reason: FailsafeReason
    /// The focused application's name when the ladder ran, or `nil` when it could not be
    /// resolved.
    public let targetAppName: String?
    /// The monotonic instant the transcript was captured, as its seconds component.
    public let capturedAtSeconds: UInt64
    /// The monotonic instant the transcript was captured, as its attoseconds component.
    public let capturedAtAttoseconds: UInt64

    private enum CodingKeys: String, CodingKey {
        case id, text, reason, targetAppName, capturedAtSeconds, capturedAtAttoseconds
    }

    /// An entry as the journal writes it: the transcript plus the ordinal the journal assigned.
    public init(id: Int, transcript: HeldTranscript) {
        self.id = id
        self.text = transcript.text
        self.reason = transcript.reason
        self.targetAppName = transcript.targetAppName
        let components = transcript.capturedAt.components
        self.capturedAtSeconds = UInt64(components.seconds)
        self.capturedAtAttoseconds = UInt64(components.attoseconds)
    }

    /// The transcript the entry holds, whole — the round trip a relaunch depends on.
    ///
    /// Non-failable because every construction path validates the reason: the memberwise
    /// initializer receives a `FailsafeReason` that is valid by construction, and the decoder
    /// throws before this type can exist for a reason it cannot name.
    public var transcript: HeldTranscript {
        HeldTranscript(
            text: text,
            reason: reason,
            targetAppName: targetAppName,
            capturedAt: Duration(
                secondsComponent: Int64(capturedAtSeconds),
                attosecondsComponent: Int64(capturedAtAttoseconds)))
    }

    /// Decodes an entry, refusing one whose reason no longer decodes.
    ///
    /// A `FailsafeReason` is an enum, and an entry whose persisted reason names no case is a
    /// schema drift or a corruption — it must land in the store's skip path with every other
    /// undecodable file, not surface as a transcript the window cannot render.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(Int.self, forKey: .id)
        self.text = try container.decode(String.self, forKey: .text)
        let reasonRawValue = try container.decode(String.self, forKey: .reason)
        guard let reason = FailsafeReason(rawValue: reasonRawValue) else {
            throw JournalStoreError.unknownReason(reasonRawValue)
        }
        self.reason = reason
        self.targetAppName = try container.decodeIfPresent(String.self, forKey: .targetAppName)
        self.capturedAtSeconds = try container.decode(UInt64.self, forKey: .capturedAtSeconds)
        self.capturedAtAttoseconds = try container.decode(
            UInt64.self, forKey: .capturedAtAttoseconds)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(text, forKey: .text)
        try container.encode(reason.rawValue, forKey: .reason)
        try container.encodeIfPresent(targetAppName, forKey: .targetAppName)
        try container.encode(capturedAtSeconds, forKey: .capturedAtSeconds)
        try container.encode(capturedAtAttoseconds, forKey: .capturedAtAttoseconds)
    }
}

/// The file-system seam the recovery journal's logic is tested over — the adapter-aspect shape:
/// ``FileSystemJournalStore`` is the one file in `VoccaInject` permitted to name `FileManager`
/// (the journal seam's entry in `InjectionSeamBoundaryTests`' per-seam table), and everything
/// in this file and in ``RecoveryJournal`` decides and names none of it.
///
/// The seam is the boundary the durability contract crosses: ``RecoveryJournal/init(store:capacity:)``
/// loads on launch, ``RecoveryJournal/hold(_:)`` awaits a save that must not return before the
/// entry is safe against process death, and ``RecoveryJournal/release()`` purges. The
/// ``RecordingJournalStore`` double (`JournalTestDoubles.swift`) records the atomic
/// temp-write/rename pair, so the protocol's shape is asserted rather than assumed.
public protocol JournalStore: Sendable {
    /// Durably commits `entry`. Must not return before the entry survives process death — for
    /// the file adapter, after the temp write has been renamed into place.
    func save(_ entry: JournalEntry) async throws

    /// Every readable committed entry, oldest first (ascending write ordinal). Unreadable or
    /// undecodable entries are skipped, never fatal — a journal must never block on one bad
    /// file, and never lose the rest because of it.
    func load() async throws -> [JournalEntry]

    /// The write ordinals of every committed entry, ascending — the eviction ordering
    /// ``RecoveryJournal`` relies on.
    func list() async throws -> [Int]

    /// Removes the committed entry with `id`. Removing an entry that does not exist is a no-op.
    func remove(id: Int) async throws
}

/// What a journal store cannot do.
///
/// The specific error is the store's business; the contract's is that a store that cannot
/// commit must throw, and that the journal must surface the throw from `hold` rather than
/// answer as if the transcript were safe.
public enum JournalStoreError: Error, Equatable {
    /// A persisted entry named a `FailsafeReason` no case of the enum covers — schema drift or
    /// corruption, routed into the skip path with every other undecodable entry.
    case unknownReason(String)
}
