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

/// The epoch-minted handoff record: everything one activation produced, carried out inside
/// `.stopped`.
///
/// D5: the machine owns the mode-scoped session record — the three slots the reset acceptance
/// names (`buffer`, `transcript`, `target`) — minted fresh at every `.start`, filled by the
/// owner through the machine's `fill*` methods, handed out inside `.stopped`, and cleared with
/// `currentMode` at the stop. There is exactly one `session` field on the machine, replaced at
/// every start: **carryover is unrepresentable inside the machine**, and the reset tests drive
/// full cycles in both directions to prove it.
///
/// The record is the *typed carrier* at the machine's own boundary. The machine does not reach
/// into driver-owned state (the dictate ring, the router's resolution) — duplicating it would be
/// the two-copies-of-one-fact desync the house bans (`SessionMachine.swift:103-105`).
///
/// The `target` slot stays `nil` in a converse cycle by construction: a converse driver never
/// calls `fill(target:)` — never a target in converse (`PRODUCT_SPEC.md:200`).
public struct ModeSession<Audio: CapturedAudio>: Sendable {
    /// The mode this activation ran under.
    public let mode: SessionMode

    /// The machine's activation counter at the mint — distinct for every activation, even a
    /// same-mode restart, and untouched by refusals and session-control presses.
    public let epoch: UInt64

    /// The captured audio, filled by the owner at the dictate terminal (or the converse
    /// utterance).
    public var buffer: Audio?

    /// The transcript / cleaned text, filled by the owner when the driver produces it.
    public var transcript: String?

    /// The resolved injection target; filled only in a dictate cycle, and structurally `nil` in
    /// a converse one.
    public var target: TargetContext?

    /// The constructor. Production code constructs a record only at a `.start` — the machine's
    /// mint, the only `ModeSession(` site in `VoccaCore` (the seam lint pins it) — and tests
    /// build expectations by hand; the slot defaults keep the mint and the expectations free of
    /// invented `nil`s.
    public init(
        mode: SessionMode, epoch: UInt64, buffer: Audio? = nil, transcript: String? = nil,
        target: TargetContext? = nil
    ) {
        self.mode = mode
        self.epoch = epoch
        self.buffer = buffer
        self.transcript = transcript
        self.target = target
    }
}

extension ModeSession: Equatable where Audio: Equatable {}