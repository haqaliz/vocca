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

/// The frame boundary of the MCP client (`mcp-protocol` card, Q3): **something that carries
/// frames to a peer and brings frames back.** Nothing more is said, and the omission is the
/// design.
///
/// ## The vocabulary is deliberately about frames, not about a pipe
///
/// There is no file descriptor here, no identifier of a running program, no address and no
/// "connect". The seam names a *peer* and a *frame*, because the half of MCP worth building
/// first is the protocol — framing, negotiation, discovery, annotation handling — and all of it
/// is decidable without knowing how the bytes travel.
///
/// That is not tidiness. The card's Q3 decision split this unit from the one that speaks to a
/// real server precisely so the two could be reviewed apart, and the seam's vocabulary is what
/// holds the split open: if a type here mentioned a spawned program or a socket, the later slice
/// would already have leaked into this one, and the review that slice exists to force would be
/// happening now, by accident, underneath a protocol layer nobody had finished reading.
///
/// The later slice is where the recorded deviation **D2** is the whole conversation: the
/// zero-network interposer counts loopback as network on purpose, and a spawned child escapes the
/// interposer entirely, so the failure mode there is a green suite while a child egresses.
/// Nothing in *this* file can make that better or worse — which is exactly why it says nothing
/// about it.
///
/// ## Both directions report failure as a value
///
/// Following ``ActionProvider``'s posture: failure is returned, never thrown. A caller cannot
/// drop a returned failure by omitting a `catch`, and every failure here is a fact about an
/// untrusted peer that the layer above has to decide something about.
///
/// The asymmetry between the two operations is real rather than stylistic. Sending either
/// happened or did not, so it answers with an optional failure; receiving produces a frame or a
/// failure, so it answers with a `Result`.
///
/// ## Receiving is frame-at-a-time, and correlation is the caller's job
///
/// ``receive()`` hands back the next frame the peer produced — not the answer to any particular
/// request. JSON-RPC peers may answer out of order and may interleave frames of their own, so
/// matching a response to its request is done by **id**, above this seam, by
/// ``JSONRPCResponse/answers(_:)``. A seam that promised "the reply to this request" would be
/// promising something no real peer guarantees.
///
/// ## The one thing the seam does say about the machine: ``spawnsSubprocess``
///
/// The vocabulary rule above has exactly one exception, and it is deliberate. A conformer that
/// starts a child process starts it **on the user's machine**, and D2 says plainly that nothing in
/// this process can see what that child then does. A composition root has to be able to fold that
/// fact — into a badge, into a refusal, into a sentence shown before anything runs — and a fact it
/// can only learn by starting the child arrives too late to decide anything with.
///
/// So the declaration is a **value**, defaulting to `false`, exactly as
/// ``CleanupProvider/requiresNetwork`` is (`CleanupProvider.swift:29-33`): a conformer that starts
/// nothing stays silent and is quiet by construction, and a conformer that starts something has to
/// say so in code rather than in a comment somebody must remember to read. Note what this is
/// *not*: it is not a guarantee about the child's behaviour, because no such guarantee is
/// obtainable. It is a declaration that a child exists at all.
public protocol MCPTransport: Sendable {

    /// Whether using this transport starts a child process on the user's machine.
    ///
    /// `false` by default (see the extension). A conformer that spawns declares `true`, and the
    /// composition root folds it — the ``CleanupProvider/requiresNetwork`` shape, for the same
    /// reason: the user is owed the fact at the point of use.
    ///
    /// Readable without starting anything, and **nonisolated** so that an actor conformer answers
    /// it without a suspension. A declaration a caller must `await` is a declaration a caller will
    /// route around.
    var spawnsSubprocess: Bool { get }

    /// Hands one frame to the peer.
    ///
    /// - Parameter frame: The encoded JSON-RPC request.
    /// - Returns: `nil` when the frame left, or the reason it did not.
    func send(_ frame: Data) async -> MCPTransportFailure?

    /// Takes the next frame the peer produced, if there is one.
    ///
    /// - Returns: The frame's bytes — **unvalidated**; everything about their shape is decided
    ///   above this seam — or the reason there is nothing to take.
    func receive() async -> Result<Data, MCPTransportFailure>
}

extension MCPTransport {

    /// The quiet default: a transport that does not declare ``spawnsSubprocess`` starts nothing.
    ///
    /// The same construction as ``CleanupProvider/requiresNetwork``'s offline default, and it
    /// carries the same weight. ``InMemoryMCPTransport`` stays silent here on purpose: it appends
    /// to an array and removes from one, so its `false` is a structural fact rather than a
    /// promise, and the default is where a structural fact belongs.
    public var spawnsSubprocess: Bool { false }
}

/// What a transport cannot do.
///
/// Two cases, and they mean different things to the layer above: a peer that is not there at all
/// fails every future operation too, while an exhausted frame supply is a peer that simply has
/// not answered yet — or never will, which ``MCPSession`` bounds rather than waits on.
public enum MCPTransportFailure: Error, Equatable, Sendable {

    /// The peer cannot be reached in either direction. Nothing was sent and nothing was read.
    case peerUnavailable

    /// The peer is reachable and has produced no further frame.
    case noFrameAvailable
}
