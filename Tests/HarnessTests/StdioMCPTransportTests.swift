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
import VoccaCore
import XCTest

/// `StdioMCPTransport` — the second ``MCPTransport``, and the suite that answers **D2**.
///
/// ## Four of the seven acceptances are about a hostile child, on purpose
///
/// ``InMemoryMCPTransport`` is a peer whose worst behaviour is a bad string literal. A spawned
/// child is a peer that can **exit mid-sentence, never answer at all, answer forever, or outlive
/// the object that started it** — four failure modes that do not exist above a pipe and that a
/// caller cannot defend against on its own. A spawned peer is *less* trustworthy than an
/// in-memory one, not more, and the proportion of this suite reflects that: one test for the happy
/// round trip, four for the ways a child misbehaves.
///
/// ## The suite is itself an instance of the fact D2 records
///
/// Every child below is `/bin/cat`, `/bin/sleep` or `/usr/bin/yes` — **Apple platform binaries**,
/// which the hardened runtime launches with `DYLD_*` stripped from their environment. Not one of
/// them can be seen by the zero-network interposer, no matter what it does. That is not a
/// weakness of the fixtures; it *is* D2, demonstrated by the very tests that prove this transport
/// works. See ``StdioMCPTransport`` and ``ActionTransportProhibitionTests`` for the answer.
///
/// `/bin/cat` rather than `/bin/sh -c 'cat'` is deliberate in two ways. A shell adds a hop, and a
/// hop is exactly what launders `DYLD_INSERT_LIBRARIES` for the whole descendant tree — running
/// the fixture through a shell would make the suite quietly demonstrate the *worse* half of D2
/// while claiming to test framing. And a shell's quoting rules would become part of what the test
/// asserts: `cat` echoes stdin to stdout byte for byte, so a frame that does not come back is a
/// framing defect and nothing else.
///
/// ## No test here may leave a child behind
///
/// Every launch goes through ``withChild(_:arguments:readTimeout:pollInterval:maxFrameBytes:clock:sleeper:body:)``,
/// which shuts the transport down on **every** exit path including a thrown assertion. A test that
/// leaks a process is a broken test, and it is broken in the way that matters most here: the whole
/// of acceptance 7 is that this object does not leave children running.
final class StdioMCPTransportTests: XCTestCase {

    // MARK: - Fixtures

    /// A child that echoes stdin to stdout, byte for byte. See the type documentation for why it
    /// is not a shell.
    private static let echoingChild = "/bin/cat"

    /// A child that produces nothing and exits on nobody's schedule but its own.
    private static let silentChild = "/bin/sleep"

    /// A child that writes to stdout forever and never stops.
    private static let floodingChild = "/usr/bin/yes"

    /// A frame exactly as a peer would hand it over: bytes, with no guarantee attached.
    private func frame(_ text: String) -> Data {
        Data(text.utf8)
    }

    /// One realistic JSON-RPC frame. Nothing here parses it — this suite is about the pipe, and
    /// the protocol layer above already has a suite of its own — but a frame with the real shape
    /// is what proves the framing carries braces, quotes and a colon intact.
    private func jsonRPCFrame() -> Data {
        frame(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"x":"y"}}"#)
    }

    /// Runs `body` against a launched transport and shuts it down on every exit path.
    ///
    /// `defer` cannot `await`, so the teardown cannot be written where a reader would look for it.
    /// This helper is where it lives instead, and every test in the file goes through it.
    private func withChild(
        _ executablePath: String,
        arguments: [String] = [],
        readTimeout: Duration = .seconds(5),
        pollInterval: Duration = .milliseconds(1),
        maxFrameBytes: Int = StdioMCPTransport.Configuration.defaultMaxFrameBytes,
        clock: (any MonotonicClock & Sendable)? = nil,
        sleeper: (any StdioPollSleeper)? = nil,
        body: (StdioMCPTransport) async throws -> Void
    ) async throws {
        let configuration = StdioMCPTransport.Configuration(
            executablePath: executablePath,
            arguments: arguments,
            readTimeout: readTimeout,
            pollInterval: pollInterval,
            maxFrameBytes: maxFrameBytes)
        let transport = StdioMCPTransport(
            configuration: configuration,
            clock: clock ?? ContinuousStdioClock(),
            sleeper: sleeper ?? TaskStdioPollSleeper())

        if let failure = await transport.start() {
            await transport.shutdown()
            return XCTFail("the child must launch — \(executablePath): \(failure)")
        }
        do {
            try await body(transport)
        } catch {
            await transport.shutdown()
            throw error
        }
        await transport.shutdown()
    }

    // MARK: - Acceptance 1: the second implementation of the seam

    /// The same body, run against both implementations of ``MCPTransport``.
    ///
    /// A frame handed to a peer comes back from that peer. It is the only claim the seam makes,
    /// and it is the claim that has to survive a real pipe as well as an array — which is the
    /// whole content of "second implementation": the contract was written against one peer and is
    /// now answered by two that share no code.
    private func assertAFrameHandedOverComesBack(
        through transport: any MCPTransport,
        _ payload: Data,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let sent = await transport.send(payload)
        XCTAssertNil(
            sent, "the frame must leave — \(String(describing: sent))", file: file, line: line)

        let received = await transport.receive()
        XCTAssertEqual(
            received, .success(payload),
            """
            the peer's frame must come back byte for byte. Both implementations answer this body: \
            an array that pops what it was handed, and a child that echoes what it was piped.
            """, file: file, line: line)
    }

    /// The in-memory transport, through the shared body.
    func testTheInMemoryTransportSatisfiesTheSharedTransportBody() async {
        let payload = jsonRPCFrame()
        let transport = InMemoryMCPTransport(replies: [payload])
        await assertAFrameHandedOverComesBack(through: transport, payload)
    }

    /// The stdio transport, through the *same* body, over a real child — acceptance 1 and
    /// acceptance 3 in one assertion, because they are one claim.
    func testTheStdioTransportSatisfiesTheSameSharedTransportBodyOverARealChild() async throws {
        let payload = jsonRPCFrame()
        try await withChild(Self.echoingChild) { transport in
            await self.assertAFrameHandedOverComesBack(through: transport, payload)
        }
    }

    // MARK: - Acceptance 2: `spawnsSubprocess` is a value

    /// The declaration is a **value**, readable without starting anything — the analogue of
    /// `CleanupProvider.requiresNetwork`, which a composition root folds into a badge rather than
    /// a comment somebody has to remember.
    ///
    /// Read before ``StdioMCPTransport/start()`` on purpose: a fact a caller can only learn by
    /// spawning the child is a fact that arrives too late to decide anything.
    func testSpawnsSubprocessIsDeclaredAsAValueByBothImplementations() async {
        let inMemory = InMemoryMCPTransport(replies: [])
        XCTAssertFalse(
            inMemory.spawnsSubprocess,
            """
            the in-memory transport starts nothing, and inherits the seam's default rather than \
            declaring it — the same shape as `requiresNetwork`, where silence means offline.
            """)

        let stdio = StdioMCPTransport(
            configuration: .init(executablePath: Self.echoingChild),
            clock: ContinuousStdioClock(),
            sleeper: TaskStdioPollSleeper())
        XCTAssertTrue(
            stdio.spawnsSubprocess,
            """
            the stdio transport must declare what it is, before it is started and whether or not \
            it ever is. A composition root cannot fold a fact it has to run the thing to learn.
            """)
        let pid = await stdio.childProcessIdentifier
        XCTAssertNil(
            pid,
            "reading the declaration must not have started anything — the value is about the "
                + "type, not about a running child")
        await stdio.shutdown()
    }

    // MARK: - The D2 answer's load-bearing claim: the default configuration cannot spawn

    /// **Nothing in the shipped tree constructs this transport.**
    ///
    /// This is the claim the whole D2 answer rests on, and it is asserted rather than asserted
    /// *about*: the answer is not "we watch the child" — nothing can — but "the default
    /// configuration cannot create one". If the composition root ever names this type, the
    /// default configuration acquires a spawn and that sentence becomes false, so the assertion
    /// lives here rather than in a paragraph.
    ///
    /// Comments are stripped first, so a doc comment elsewhere may explain what the stdio
    /// transport is without becoming a construction — the same rule the transport prohibition
    /// itself follows.
    func testNothingOutsideTheTransportFileConstructsTheStdioTransport() throws {
        let sources = try PackageRootLocator.find(from: #filePath)
            .appendingPathComponent("Sources")
        var naming: [String] = []
        let files = SwiftSourceScanner.swiftFiles(under: sources)
        for url in files {
            let source = try String(contentsOf: url, encoding: .utf8)
            let code = SwiftSourceScanner.stripComments(from: source)
            guard code.contains("StdioMCPTransport") else { continue }
            naming.append(String(url.path.dropFirst(sources.path.count + 1)))
        }

        XCTAssertGreaterThan(
            files.count, 0,
            "scanning nothing passes 'nothing constructs it' vacuously — the one way this check "
                + "can lie")
        XCTAssertEqual(
            naming, ["VoccaActions/MCP/StdioMCPTransport.swift"],
            """
            only the transport's own file may name StdioMCPTransport: \(naming.sorted()).
            The D2 answer is that the default configuration cannot create a blind child. The \
            moment the composition root names this type, the default configuration can — and the \
            claim in the lint entry, the doc comment and the docs becomes false. Wiring it is a \
            later slice with its own review, not an import.
            """)
    }

    /// Construction spawns nothing; only ``StdioMCPTransport/start()`` does.
    ///
    /// The split is what makes the claim above enforceable at all. If the initialiser spawned,
    /// "constructed but not configured" would already be a running child, and there would be no
    /// state in which the type exists and the machine is untouched.
    func testConstructionSpawnsNothingUntilStartIsCalled() async {
        let transport = StdioMCPTransport(
            configuration: .init(executablePath: Self.echoingChild),
            clock: ContinuousStdioClock(),
            sleeper: TaskStdioPollSleeper())

        let before = await transport.childProcessIdentifier
        XCTAssertNil(before, "constructing the transport must not spawn")

        let sent = await transport.send(frame("anything"))
        XCTAssertEqual(
            sent, .peerUnavailable,
            "an unstarted transport has no peer — and refusing must not be what starts one")
        let stillNothing = await transport.childProcessIdentifier
        XCTAssertNil(stillNothing, "a refused send must not spawn a child as a side effect")

        await transport.shutdown()
    }

    // MARK: - Acceptance 4: a child that exits mid-exchange

    /// A child killed between two frames yields a **typed failure**, never a hang and never a
    /// trap.
    ///
    /// The kill is delivered from the test to the **real pid**, which is the only way to stage
    /// the case honestly: a child asked politely to stop is a shutdown, while a child that
    /// vanishes is what actually happens when a server segfaults or is killed by the OS.
    ///
    /// Both directions are then asserted, because they fail for different reasons and a
    /// transport can easily get one right and the other wrong: reading finds end-of-file, while
    /// writing finds a pipe with no reader — which, unhandled, does not return an error at all.
    /// It raises `SIGPIPE` and takes Vocca down with it.
    func testAChildThatExitsMidExchangeYieldsATypedFailureRatherThanAHang() async throws {
        try await withChild(Self.echoingChild) { transport in
            let payload = self.frame("{\"id\":1}")
            let sent = await transport.send(payload)
            XCTAssertNil(sent, "the first frame must leave")
            let echoed = await transport.receive()
            XCTAssertEqual(
                echoed, .success(payload),
                "the child must be alive and echoing before it is killed — otherwise this test "
                    + "stages nothing")

            let identifier = await transport.childProcessIdentifier
            let pid = try XCTUnwrap(
                identifier, "a started transport must have a child")
            XCTAssertEqual(kill(pid, SIGKILL), 0, "the fixture child must be killable")

            let afterDeath = await transport.receive()
            XCTAssertEqual(
                afterDeath, .failure(.peerUnavailable),
                """
                end-of-file on a dead child's stdout is a peer that is not there — terminal, and \
                a returned value. A transport that waited for a frame from a dead child would \
                hang for the whole timeout at best and forever at worst.
                """)

            let afterDeathSend = await transport.send(self.frame("{\"id\":2}"))
            XCTAssertEqual(
                afterDeathSend, .peerUnavailable,
                """
                writing to a pipe with no reader must be a returned failure. This is the \
                assertion that would not merely fail but take the test process with it if SIGPIPE \
                were left at its default disposition.
                """)
        }
    }

    // MARK: - Acceptance 5: a bounded timeout, injected

    /// A child that never answers hits the bound — and the suite **does not sleep** to find out.
    ///
    /// The timeout is ten minutes and the test takes milliseconds. That gap is the assertion: the
    /// clock and the poll wait are both injected, following the repo's precedent
    /// (``MonotonicClock``, `SessionWatchdog`), so a test moves time by hand rather than waiting
    /// for it. A wall-clock-hardcoded bound cannot be tested at all — a suite that waited out a
    /// realistic server timeout would be deleted within a week, and the bound would go untested.
    func testAChildThatNeverRespondsHitsTheBoundedTimeoutWithoutTheSuiteSleeping() async throws {
        let clock = SteppingStdioClock(step: .seconds(30))
        let sleeper = InstantStdioPollSleeper()
        let started = ContinuousClock.now

        try await withChild(
            Self.silentChild, arguments: ["300"],
            readTimeout: .seconds(600), clock: clock, sleeper: sleeper
        ) { transport in
            let received = await transport.receive()
            XCTAssertEqual(
                received, .failure(.noFrameAvailable),
                """
                an unresponsive peer must exhaust a bound and say so. `noFrameAvailable` rather \
                than `peerUnavailable`: the child is alive and simply has not spoken, which is a \
                different fact for the layer above than a child that is gone.
                """)
        }

        let elapsed = ContinuousClock.now - started
        XCTAssertLessThan(
            elapsed, .seconds(5),
            """
            a 600 s bound resolved in \(elapsed) — the wait must come from the injected clock, \
            not from the wall. If this ever fails, the bound has been hardcoded somewhere the \
            injection does not reach.
            """)
        let waits = await sleeper.waits
        XCTAssertGreaterThan(
            waits, 0,
            "the poll must actually have waited between reads — a timeout reached by a spin loop "
                + "is a bound that costs a core")
    }

    /// The bound is pinned in **one** place, and the shipped default is that place.
    ///
    /// Named so that a second, disagreeing bound cannot appear quietly beside it: the failure mode
    /// of a timeout is not that it is wrong but that there are two of them.
    func testTheReadTimeoutBoundIsPinnedInOnePlace() {
        XCTAssertEqual(
            StdioMCPTransport.Configuration.defaultReadTimeout, .seconds(10),
            "the shipped bound is the one the composition root gets when it says nothing")
        let silent = StdioMCPTransport.Configuration(executablePath: Self.echoingChild)
        XCTAssertEqual(
            silent.readTimeout, StdioMCPTransport.Configuration.defaultReadTimeout,
            "a configuration that declares no timeout must take the pinned one, not a literal of "
                + "its own")
    }

    // MARK: - Acceptance 6: a flooding child is bounded

    /// A child that writes forever is read in **bounded chunks**, and the buffer never exceeds the
    /// bound.
    ///
    /// `/usr/bin/yes` is the honest version of this case: it is not a large output, it is an
    /// infinite one. A transport that read "until the peer is done" would never return, and the
    /// memory it consumed on the way would be chosen by the peer.
    func testAFloodingChildIsReadInBoundedChunks() async throws {
        try await withChild(Self.floodingChild, maxFrameBytes: 4096) { transport in
            for attempt in 1...3 {
                let received = await transport.receive()
                XCTAssertEqual(
                    received, .success(self.frame("y")),
                    "frame \(attempt) from an infinite producer must still be one frame")
                let buffered = await transport.bufferedByteCount
                XCTAssertLessThanOrEqual(
                    buffered, StdioMCPTransport.Configuration.readChunkBytes,
                    """
                    the buffer held \(buffered) bytes after read \(attempt). What is retained \
                    between frames must be bounded by our chunk size, never by how fast the peer \
                    can write.
                    """)
            }
        }
    }

    /// A single frame larger than the bound is **refused**, and refusing is terminal.
    ///
    /// The other half of "bounded": `yes` floods with newlines, so each frame is tiny and only the
    /// retained buffer is at risk. A peer that never sends a newline at all attacks the frame
    /// accumulator directly, and the only defence is a cap that ends the exchange.
    ///
    /// The frame goes out through `send` unbounded on purpose. The cap is on what an **untrusted
    /// peer hands back**, not on what this process hands it — bounding our own outbound frame
    /// would defend against nobody and would make this case unstageable with `/bin/cat`.
    func testAFrameLargerThanTheBoundIsRefusedAndTheRefusalIsTerminal() async throws {
        try await withChild(Self.echoingChild, maxFrameBytes: 64) { transport in
            let oversize = Data(repeating: UInt8(ascii: "a"), count: 4096)
            let sent = await transport.send(oversize)
            XCTAssertNil(
                sent,
                "the outbound frame is ours and is not capped — the cap is on the peer's reply")

            let received = await transport.receive()
            XCTAssertEqual(
                received, .failure(.peerUnavailable),
                """
                a frame that passes the cap with no delimiter in sight must end the exchange. \
                Growing the buffer instead would let the peer choose this process's memory \
                footprint, which is the unbounded read this acceptance forbids.
                """)

            let buffered = await transport.bufferedByteCount
            XCTAssertEqual(
                buffered, 0,
                "the refused bytes must be dropped, not kept — a bound that caps growth but "
                    + "retains what it refused has only moved the leak")

            let asked_again = await transport.receive()
            XCTAssertEqual(
                asked_again, .failure(.peerUnavailable),
                "the refusal is terminal: a peer we stopped reading from is not a peer we may "
                    + "resume trusting by asking again")
            let sentAfterRefusal = await transport.send(self.frame("{}"))
            XCTAssertEqual(
                sentAfterRefusal, .peerUnavailable,
                "and terminal in both directions")
        }
    }

    // MARK: - Acceptance 7: no orphan survives teardown

    /// After teardown the **real pid** is gone.
    ///
    /// Asserted with `kill(pid, 0)` against the operating system rather than against an internal
    /// flag, because every way this can go wrong leaves the flag correct: a `terminate()` that was
    /// never delivered, a child that ignores `SIGTERM`, a child reparented to `launchd`, or an
    /// exited child never reaped and left as a zombie. `ESRCH` is the only answer that means what
    /// the acceptance says.
    func testNoOrphanSurvivesTeardown() async throws {
        let configuration = StdioMCPTransport.Configuration(
            executablePath: Self.silentChild, arguments: ["300"])
        let transport = StdioMCPTransport(
            configuration: configuration,
            clock: ContinuousStdioClock(),
            sleeper: TaskStdioPollSleeper())
        let launchFailure = await transport.start()
        XCTAssertNil(launchFailure, "the fixture child must launch")

        let identifier = await transport.childProcessIdentifier
        let pid = try XCTUnwrap(
            identifier, "a started transport must have a child")
        XCTAssertEqual(
            kill(pid, 0), 0, "the child must be alive before teardown — otherwise this test "
                + "asserts nothing about teardown")

        await transport.shutdown()

        XCTAssertEqual(
            kill(pid, 0), -1,
            """
            pid \(pid) still exists after teardown. `kill(pid, 0)` asks the kernel, which is the \
            point: an internal `isRunning` flag reads correctly in every way this can fail.
            """)
        XCTAssertEqual(
            errno, ESRCH,
            "the child must be gone *and reaped* — a zombie answers kill(pid, 0) successfully, so "
                + "ESRCH is the assertion and not merely a non-zero return")
    }

    /// Teardown is idempotent, and a second shutdown does not signal a pid the process no longer
    /// owns.
    ///
    /// The helper shuts every transport down, and two of the tests above are shut down by their
    /// own body first. A `terminate()` on an unlaunched or already-reaped child raises rather than
    /// returns, so "shutdown twice" is a real path through this object and not a hypothetical.
    func testShutdownIsIdempotent() async throws {
        try await withChild(Self.silentChild, arguments: ["300"]) { transport in
            await transport.shutdown()
            await transport.shutdown()
            let identifier = await transport.childProcessIdentifier
            XCTAssertNil(
                identifier,
                "a shut-down transport holds no child — and the helper is about to call shutdown "
                    + "a third time")
        }
    }
}

// MARK: - Injected time

/// A clock that advances by a fixed step on every reading.
///
/// The `StepAdvancingClock` shape from `InjectionTestDoubles`, kept local because what this suite
/// needs is one property: time passes *because the transport looked at it*, so a bound of any size
/// is reached in a bounded number of polls and the suite never waits.
private final class SteppingStdioClock: MonotonicClock, @unchecked Sendable {
    private let step: Duration
    private var reading: Duration = .zero
    private let lock = NSLock()

    init(step: Duration) {
        self.step = step
    }

    var now: Duration {
        lock.lock()
        defer { lock.unlock() }
        reading += step
        return reading
    }
}

/// A poll wait that does not wait, and counts how often it was asked to.
///
/// The count is what keeps the timeout test from passing for the wrong reason: a transport that
/// spun without ever yielding would also finish in milliseconds.
private actor InstantStdioPollSleeper: StdioPollSleeper {
    private(set) var waits = 0

    func wait(_ duration: Duration) async {
        waits += 1
        await Task.yield()
    }
}
