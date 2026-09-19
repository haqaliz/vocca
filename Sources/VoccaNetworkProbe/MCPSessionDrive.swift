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
import VoccaActions

// The probe's half of the zero-network invariant for the MCP protocol layer
// (`protocol-core` Phase 4), alongside `ActionAuditDrive.swift`'s half for the audit store.
//
// ## Why a second `VoccaActions` drive
//
// The module coverage list is satisfied already — `ActionAuditDrive` mints a `VoccaActions`
// witness — so nothing about module granularity requires this file. What requires it is the same
// thing that required the audit drive: a module entry says a module was *reached*, never that a
// particular piece of its work *ran*. The audit store's round trip says nothing whatever about
// the protocol layer, and the protocol layer is the half of this module that will one day be
// asked to talk to something. So it is driven end to end — `initialize` → `tools/list` →
// `tools/call` — inside the interposer, and the witness this drive mints is produced *by* that
// run, so the coverage entry cannot outlive the calls it stands for.
//
// ## ⚠️ WHAT A GREEN `PROBE-MCP` PROVES, AND WHAT IT DOES NOT
//
// **It proves:** this protocol layer — the JSON-RPC encoder, the frame parser, the negotiation,
// the discovery, the annotation reading and the call — reaches no network name. Not one of the
// interposer's eight libSystem entry points is touched while a whole MCP conversation runs. That
// is a real claim about real code, and it is only available because the card's Q3 decision put an
// **in-memory** transport behind the seam: `InMemoryMCPTransport` appends to an array and removes
// from another, so there is nothing here that could open anything.
//
// **It proves nothing about a stdio transport**, which is a later slice and is deviation **D2**.
// D2 was measured, not assumed: `DYLD_INSERT_LIBRARIES` is stripped *and purged* from the
// environment of a restricted child, so an MCP server spawned as a subprocess is invisible to
// this interposer for its whole descendant tree — `/usr/bin/env node server.js`, any shell
// wrapper, any Apple platform binary. The failure mode there is a **green suite while a child
// egresses**, and no amount of green on this line moves it. `transport-prohibition` is what keeps
// that a reviewed edit rather than an accident; this drive is not a substitute for it and must
// never be cited as one.
//
// ## The report, and where each field comes from
//
// `transport=in-memory negotiated=yes requests=3 methods=initialize,tools/list,tools/call
// tools=2 readOnlyTools=1 unannotatedIsReadOnly=false called=ok` — every field an effect of the
// run:
//
// - `transport` — the shipped transport's own type name, so a swapped-in double flips it.
// - `negotiated` — whether `initialize` succeeded. A drive whose negotiation failed would find
//   every later operation refused, which is the fail-safe working rather than the drive.
// - `requests` / `methods` — read off the **transport's own record** of what was sent, in order,
//   never off anything the session claims about itself.
// - `tools` / `readOnlyTools` — what discovery parsed.
// - `unannotatedIsReadOnly` — **the fail-safe default, observed in a live process.** The scripted
//   server offers one tool with no annotations at all, and this field is that tool's answer to
//   "may I be treated as read-only". It must read `false`. Absent means unsafe, and here that is
//   a fact about a running process rather than only about a unit test.
// - `called` — the text the tool answered with, so the call is known to have completed rather
//   than merely to have been attempted.
extension VoccaNetworkProbe {

    /// One end-to-end MCP conversation, as the post-condition coverage list reads it.
    struct MCPSessionDrive {
        /// The observation, as one line of `key=value` fields.
        let report: String

        /// A type minted **by this drive**, from the session it actually ran. The witness rule
        /// every sibling drive follows: the entry cannot be kept while the call is deleted.
        let moduleWitness: Any.Type
    }

    /// **Drives a whole MCP conversation over the in-memory transport, and reports what
    /// happened.**
    ///
    /// Nothing here asserts. The probe reports and the suite asserts, for the reason every other
    /// drive gives: an assertion living in the observed process can be deleted by the same edit
    /// that breaks what it observes.
    static func exerciseMCPSession() -> MCPSessionDrive {
        // The `exerciseActionAudit()` bridge: `main()` is the process entry point and is already
        // on the main thread, so the async work is handed to a Task and the run loop is pumped
        // until it lands — inside the observation window rather than after it.
        let semaphore = DispatchSemaphore(value: 0)
        let box = MCPSessionDriveBox()
        Task {
            box.value = await runMCPConversation()
            semaphore.signal()
        }
        while semaphore.wait(timeout: .now()) == .timedOut {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return box.value!
    }

    /// Stores the drive's result across the `@Sendable` boundary — the `ActionAuditDriveBox`
    /// shape, and honest for the same reason: written once by the Task and read once after the
    /// semaphore.
    private final class MCPSessionDriveBox: @unchecked Sendable {
        var value: MCPSessionDrive?
    }

    /// What the scripted peer says, in delivery order.
    ///
    /// Written as literal frames rather than built with the encoder, deliberately: a peer's bytes
    /// are not ours, and a script generated by the code under test would be agreeing with itself.
    /// The second tool carries **no annotations at all**, which is what makes
    /// `unannotatedIsReadOnly` a live observation of the fail-safe default rather than a constant.
    private static var scriptedPeerFrames: [Data] {
        [
            """
            {"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"\(MCPSession.protocolVersion)",\
            "capabilities":{"tools":{}},\
            "serverInfo":{"name":"vocca-probe-peer","version":"1.0"}}}
            """,
            """
            {"jsonrpc":"2.0","id":2,"result":{"tools":[\
            {"name":"probe-read","description":"Reads nothing.",\
            "annotations":{"readOnlyHint":true}},\
            {"name":"probe-unannotated","description":"Says nothing about itself."}]}}
            """,
            """
            {"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"ok"}],\
            "isError":false}}
            """,
        ].map { Data($0.utf8) }
    }

    /// The conversation itself: negotiate, discover, call.
    private static func runMCPConversation() async -> MCPSessionDrive {
        let transport = InMemoryMCPTransport(replies: scriptedPeerFrames)
        let session = MCPSession(transport: transport)

        let negotiated: Bool
        if case .success = await session.initialize() {
            negotiated = true
        } else {
            negotiated = false
        }

        let tools = (try? (await session.listTools()).get()) ?? []
        let readOnlyTools = tools.filter(\.annotations.isReadOnly).count
        // The tool the scripted peer declared nothing about. `first(where:)` rather than an index,
        // because everything here came through a parser fed by a peer.
        let unannotated = tools.first { $0.annotations.declaredReadOnly == nil }

        let called: String
        if let result = try? (await session.callTool("probe-read", arguments: ["quiet": .bool(true)]))
            .get()
        {
            called = result.textContent.joined(separator: "|")
        } else {
            called = "none"
        }

        let sentMethods = await transport.sentMethods
        let requests = await transport.sentFrames.count
        let transportName = String(reflecting: type(of: transport))

        return MCPSessionDrive(
            report: [
                "transport=\(transportName.contains("InMemoryMCPTransport") ? "in-memory" : "other")",
                "negotiated=\(negotiated ? "yes" : "no")",
                "requests=\(requests)",
                "methods=\(sentMethods.joined(separator: ","))",
                "tools=\(tools.count)",
                "readOnlyTools=\(readOnlyTools)",
                // The fail-safe default, read off a tool that made no claim. `none` would mean the
                // scripted peer stopped offering an unannotated tool, which would leave this field
                // watching nothing — so it is distinguishable from `false`.
                "unannotatedIsReadOnly=\(unannotated.map { "\($0.annotations.isReadOnly)" } ?? "none")",
                "called=\(called.isEmpty ? "empty" : called)",
            ].joined(separator: " "),
            moduleWitness: type(of: session))
    }
}
