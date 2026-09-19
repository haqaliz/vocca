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

/// A peer that lives entirely in memory: a scripted list of frames it will produce, and a record
/// of every frame it was handed.
///
/// ## This is a shipped implementation, not a test double
///
/// It is the only ``MCPTransport`` in the tree, by the card's Q3 decision, and the reason it can
/// be is that **the substance of MCP is not the pipe**. Negotiation, discovery, annotation
/// handling and error mapping are all decided above the seam, and all of them can be driven
/// against a peer whose answers are string literals — which is a *better* adversary than a real
/// server, because a real server cannot easily be asked to send a truncated frame, an id nobody
/// asked for, or a `readOnlyHint` of `1`.
///
/// It also makes **zero syscalls**. Sending appends to an array and receiving removes from one.
/// That is what lets the whole protocol layer run inside the zero-network interposer and report
/// honestly (`PROBE-MCP`): there is nothing here that *could* open anything, so a green probe run
/// is a statement about the protocol layer rather than about this object's restraint.
///
/// ## The script is consumed, never replayed
///
/// Frames are delivered in order and each is delivered once. A transport that repeated its last
/// frame would let a session that asked twice be answered once and never notice — the scripted
/// equivalent of a peer that says nothing while looking like it said something.
///
/// ## The record is of what left
///
/// ``sentFrames`` holds every frame that was actually handed over, in order, and a refused send
/// is not recorded. That is what lets a test assert what a session *asked* rather than what it
/// returned — the distinction the unusable-session acceptance rests on, where "tools/list was
/// refused" and "tools/list was sent and its answer discarded" are the same return value and very
/// different behaviours.
public actor InMemoryMCPTransport: MCPTransport {

    /// Every frame handed over, oldest first.
    public private(set) var sentFrames: [Data] = []

    /// What the peer has left to say, in delivery order.
    private var replies: [Data]

    /// Whether the peer is there at all. `false` fails both directions.
    private let isAvailable: Bool

    /// A peer that will answer with `replies`, in order.
    ///
    /// - Parameters:
    ///   - replies: The frames the peer produces, one per ``receive()``.
    ///   - isAvailable: `false` for a peer that is not there — every operation fails with
    ///     ``MCPTransportFailure/peerUnavailable`` and the script is never delivered, because the
    ///     script is what the peer *would* have said rather than what it did.
    public init(replies: [Data], isAvailable: Bool = true) {
        self.replies = replies
        self.isAvailable = isAvailable
    }

    public func send(_ frame: Data) async -> MCPTransportFailure? {
        guard isAvailable else { return .peerUnavailable }
        sentFrames.append(frame)
        return nil
    }

    public func receive() async -> Result<Data, MCPTransportFailure> {
        guard isAvailable else { return .failure(.peerUnavailable) }
        // `removeFirst()` traps on an empty array, so the emptiness is a guard rather than an
        // assumption — the same discipline the frame parser follows about indexing.
        guard !replies.isEmpty else { return .failure(.noFrameAvailable) }
        return .success(replies.removeFirst())
    }

    /// The method named by each recorded frame, in order.
    ///
    /// Derived from the recorded bytes rather than from anything the session said about itself:
    /// a frame that was never sent has no method here, which is the whole point.
    public var sentMethods: [String] {
        sentFrames.compactMap { frame in
            guard
                let value = try? JSONSerialization.jsonObject(with: frame),
                let object = value as? [String: Any]
            else {
                return nil
            }
            return object["method"] as? String
        }
    }
}
