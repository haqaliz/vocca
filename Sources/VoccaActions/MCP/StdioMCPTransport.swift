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

/// The second ``MCPTransport``: a child process, spoken to over its stdin and stdout.
///
/// This is the **only** file under `Sources/VoccaActions/` permitted to name the `Process` family,
/// and the permission is a reviewed entry in `ActionTransportProhibitionTests`. The spawn is
/// confined to one file because a confinement spread over two files is not one.
///
/// ## D2, answered — the child is **not** observable, and no mitigation makes it so
///
/// Vocca's permanent release blocker is a zero-network CI test driven by a `dyld` interposer, and
/// that interposer counts loopback as NETWORK on purpose. So an MCP server reached over HTTP or
/// SSE on `127.0.0.1` is a *violation of the invariant*, and stdio is the only transport the
/// invariant permits. But stdio means a child, and the C13 slice-1 dig measured what happens to a
/// child: a restricted child ignores `DYLD_INSERT_LIBRARIES` **and purges `DYLD_*` from the
/// environment it passes on**. `/usr/bin/env node server.js`, any shell wrapper and any Apple
/// platform binary are therefore **blind** to the interposer, and one hop launders the insertion
/// for the entire descendant tree. There is no mitigation. An arbitrary child cannot be made
/// observable from inside this process, and a transport that claimed otherwise would be claiming
/// something measurably false.
///
/// **So the claim is not "we watch it". The claim is that the default configuration cannot create
/// one.** No server is configured out of the box, nothing under `Sources/` outside this file names
/// this type, and constructing it spawns nothing — only ``start()`` does. The probe therefore
/// never reaches a spawn, and the zero-network assertion stays true *and verifiable*, because
/// there is no child for it to be blind to. A configured server is a trust the user extends to
/// **that server's author**, and the documentation says so plainly rather than implying our
/// interposer still covers them.
///
/// This is the `BYOKCleanupProvider` precedent, applied. BYOK is not an *exception* to the
/// zero-network test; it is **unreachable by default** — constructed at one site behind a
/// configuration block that does not exist out of the box, declaring `requiresNetwork = true`
/// rather than inheriting the offline default, and folded once at launch into a badge. This
/// transport takes the same shape, and ``spawnsSubprocess`` is the analogue of that declaration.
///
/// The narrowed sentence is the deliverable. Where Vocca has said *"the default configuration
/// makes zero network calls"*, it must now also say **"and spawns no child process"** — and, where
/// a child *is* configured, that **Vocca cannot observe what that child does on the network.**
///
/// ## The peer is hostile, and four of its failure modes do not exist above a pipe
///
/// ``InMemoryMCPTransport`` is a peer whose worst behaviour is a bad string literal. A child can
/// exit mid-sentence, never answer, answer forever, and outlive the object that started it. A
/// spawned peer is *less* trustworthy than an in-memory one, not more, and every read here is
/// written that way: nothing off the pipe is force-unwrapped, nothing is indexed unchecked, the
/// per-read size is bounded, the accumulated frame is bounded, the wait is bounded, and teardown
/// kills rather than asks.
///
/// - **Reading is non-blocking, and that is load-bearing.** ``start()`` refuses to run at all if
///   `O_NONBLOCK` cannot be set on the child's stdout. A blocking read would park inside the
///   actor with no bound whatsoever, and the timeout below would be decoration: an unresponsive
///   server would wedge the caller forever exactly as if no bound existed.
/// - **`SIGPIPE` is ignored.** Writing to a pipe whose reader has died does not return an error by
///   default — it raises `SIGPIPE`, whose default disposition terminates the process. A child that
///   crashes between two frames would take Vocca with it. The disposition is set once, on the
///   first launch, so a build that never configures a server never touches it.
/// - **stderr goes to the null device, not to a pipe.** A server's logs are not this seam's
///   business, and an unread pipe is a trap: a chatty child would fill 64 KB and block forever on
///   its own logging, which reads from here as a peer that mysteriously stopped answering.
///
/// ## Framing is newline-delimited, which the encoder makes safe
///
/// One JSON-RPC message per line, the MCP stdio convention. It is safe because `JSONRPCRequest`
/// serialises without pretty-printing and JSON escapes any newline inside a string, so no frame
/// this process emits can contain a raw `\n`. Incoming bytes are not trusted to honour that:
/// anything before the next newline is one frame, a blank line is not a frame, and a run of bytes
/// that passes ``Configuration/maxFrameBytes`` with no newline in sight ends the exchange.
public actor StdioMCPTransport: MCPTransport {

    // MARK: - Configuration

    /// What to launch, and the three bounds that keep an untrusted child from deciding how much
    /// time and memory this process spends on it.
    public struct Configuration: Sendable {

        /// How long one ``receive()`` waits for a peer that is alive and silent.
        ///
        /// **The one place the bound is pinned.** A second bound beside it would not be wrong so
        /// much as ambiguous, which is the failure mode timeouts actually have.
        public static let defaultReadTimeout: Duration = .seconds(10)

        /// How long ``receive()`` waits between polls of a child that has not spoken yet.
        public static let defaultPollInterval: Duration = .milliseconds(5)

        /// The largest run of bytes that may arrive with no delimiter before the peer is refused.
        /// 1 MiB: far above any real MCP frame, far below a number that matters to this process.
        public static let defaultMaxFrameBytes = 1 << 20

        /// The most that is taken from the pipe in a single read.
        ///
        /// This is the bound on a *flooding* peer, and it is separate from
        /// ``defaultMaxFrameBytes`` because the two attacks are different: one endless frame
        /// grows the accumulator, while endless small frames grow nothing but would let a peer
        /// that writes faster than we read hold the actor in one call indefinitely.
        public static let readChunkBytes = 16 * 1024

        /// The executable to launch. An absolute path — nothing here consults a `PATH`, because
        /// resolving a name against an environment variable is a second decision about *which*
        /// program runs, and it is not this seam's to make.
        public let executablePath: String

        /// The child's arguments, passed through untouched.
        public let arguments: [String]

        /// How long ``receive()`` waits before answering ``MCPTransportFailure/noFrameAvailable``.
        public let readTimeout: Duration

        /// How long ``receive()`` waits between polls.
        public let pollInterval: Duration

        /// The delimiter-free byte run at which the peer is refused.
        public let maxFrameBytes: Int

        public init(
            executablePath: String,
            arguments: [String] = [],
            readTimeout: Duration = Configuration.defaultReadTimeout,
            pollInterval: Duration = Configuration.defaultPollInterval,
            maxFrameBytes: Int = Configuration.defaultMaxFrameBytes
        ) {
            self.executablePath = executablePath
            self.arguments = arguments
            self.readTimeout = readTimeout
            self.pollInterval = pollInterval
            self.maxFrameBytes = maxFrameBytes
        }
    }

    // MARK: - Declaration

    /// **`true`** — using this transport starts a child process on the user's machine.
    ///
    /// The ``CleanupProvider/requiresNetwork`` analogue, and the reason it is a value rather than
    /// a comment: a composition root has to be able to fold the fact into a badge before anything
    /// runs. Readable without starting anything, because a fact learned by spawning arrives too
    /// late to decide with.
    public nonisolated var spawnsSubprocess: Bool { true }

    // MARK: - State

    private let configuration: Configuration
    private let clock: any MonotonicClock & Sendable
    private let sleeper: any StdioPollSleeper

    /// The child, once ``start()`` has launched it. `nil` before a start and after a shutdown —
    /// which is what makes "constructed but not started" a state in which the machine is
    /// untouched.
    private var child: Process?

    /// The child's stdin, for ``send(_:)``.
    private var inbound: FileHandle?

    /// The child's stdout, for ``receive()``.
    private var outbound: FileHandle?

    /// The child's stdout, as a descriptor, so reads can be non-blocking.
    private var outboundDescriptor: Int32?

    /// Bytes read from the peer and not yet delivered as a frame. Bounded by
    /// ``Configuration/maxFrameBytes``.
    private var buffer = Data()

    /// Whether the peer has been given up on. Terminal in both directions, matching
    /// ``MCPTransportFailure/peerUnavailable``'s documented meaning: a peer that is not there at
    /// all fails every future operation too.
    private var isTerminal = false

    /// The child's pid, or `nil` when there is no child.
    ///
    /// Exposed so that "no orphan survives teardown" can be asserted against the **operating
    /// system** — `kill(pid, 0)` — rather than against a flag of ours. Every way teardown can go
    /// wrong leaves our flag reading correctly.
    public var childProcessIdentifier: pid_t? { child?.processIdentifier }

    /// How many bytes are retained between frames. Exposed for the boundedness acceptance: a cap
    /// that is claimed rather than measured is not a cap.
    public var bufferedByteCount: Int { buffer.count }

    public init(
        configuration: Configuration,
        clock: any MonotonicClock & Sendable,
        sleeper: any StdioPollSleeper
    ) {
        self.configuration = configuration
        self.clock = clock
        self.sleeper = sleeper
    }

    // MARK: - Launch

    /// Spawns the child. **The only thing in this type that starts a process.**
    ///
    /// Separate from `init` on purpose: it is what makes "constructed but not configured" a state
    /// in which nothing is running, and therefore what makes the D2 answer above enforceable
    /// rather than merely asserted.
    ///
    /// - Returns: `nil` when the child is running, or the reason it is not. Failure is a returned
    ///   value, following the seam's posture — a caller cannot drop it by omitting a `catch`.
    public func start() -> StdioLaunchFailure? {
        guard child == nil, !isTerminal else { return .alreadyStarted }

        // `access(2)` rather than FileManager: this module's FileManager surface is confined to
        // the audit seam by a per-seam lint, and a transport has no business widening it.
        guard access(configuration.executablePath, X_OK) == 0 else {
            return .executableNotFound(configuration.executablePath)
        }

        Self.ignoreBrokenPipeSignal()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: configuration.executablePath)
        process.arguments = configuration.arguments

        let toChild = Pipe()
        let fromChild = Pipe()
        process.standardInput = toChild
        process.standardOutput = fromChild
        // Never a third pipe. An unread pipe fills at 64 KB and blocks the child inside its own
        // logging, which arrives here as a peer that stopped answering for no reason.
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return .notLaunched(String(describing: error))
        }

        let descriptor = fromChild.fileHandleForReading.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL, 0)
        guard flags != -1, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) != -1 else {
            // Refuse rather than proceed. A blocking descriptor makes ``receive()``'s bound
            // decoration: the read would park with no timeout at all and the caller would be
            // wedged by the first silent server it met.
            process.terminate()
            process.waitUntilExit()
            return .notLaunched("the child's stdout could not be made non-blocking")
        }

        child = process
        inbound = toChild.fileHandleForWriting
        outbound = fromChild.fileHandleForReading
        outboundDescriptor = descriptor
        return nil
    }

    // MARK: - MCPTransport

    public func send(_ frame: Data) async -> MCPTransportFailure? {
        guard !isTerminal, let handle = inbound, let process = child, process.isRunning else {
            return .peerUnavailable
        }

        // The outbound frame is **not** capped. ``Configuration/maxFrameBytes`` bounds what an
        // untrusted peer hands back; capping what this process hands it would defend against
        // nobody.
        var payload = frame
        payload.append(Self.newline)
        do {
            try handle.write(contentsOf: payload)
        } catch {
            isTerminal = true
            return .peerUnavailable
        }
        return nil
    }

    public func receive() async -> Result<Data, MCPTransportFailure> {
        // Buffered frames are delivered even after the peer has gone. What the child said before
        // it died is still what it said, and dropping it would lose a complete answer to a
        // request that was actually made.
        switch takeBufferedFrame() {
        case .frame(let frame): return .success(frame)
        case .oversize:
            await shutdown()
            return .failure(.peerUnavailable)
        case .none: break
        }

        guard !isTerminal, let descriptor = outboundDescriptor else {
            return .failure(.peerUnavailable)
        }

        let deadline = clock.now + configuration.readTimeout
        while true {
            switch takeBufferedFrame() {
            case .frame(let frame):
                return .success(frame)
            case .oversize:
                // The peer is either not speaking the protocol or is choosing this process's
                // memory footprint; either way there is nothing further from it worth reading.
                await shutdown()
                return .failure(.peerUnavailable)
            case .none:
                break
            }

            switch readAvailable(from: descriptor) {
            case .bytes(let chunk):
                buffer.append(chunk)
                continue
            case .endOfFile, .failed:
                await shutdown()
                return .failure(.peerUnavailable)
            case .nothingYet:
                break
            }

            if clock.now >= deadline { return .failure(.noFrameAvailable) }
            await sleeper.wait(configuration.pollInterval)
        }
    }

    // MARK: - Teardown

    /// Stops the child, closes the pipes, and forgets both. **Idempotent**, because it is reached
    /// from a caller's teardown, from a refused peer and from end-of-file.
    ///
    /// Terminate, then wait a bounded number of polls, then `SIGKILL`. A hostile child may ignore
    /// `SIGTERM`, and a teardown that asked politely and then trusted the answer would be exactly
    /// the orphan this is written to prevent. `waitUntilExit()` afterwards is what **reaps** the
    /// child: an exited-but-unreaped zombie still answers `kill(pid, 0)` successfully, so a
    /// teardown that skipped the reap would leave the acceptance's own assertion passing over a
    /// process table entry that is still there.
    public func shutdown() async {
        isTerminal = true
        buffer.removeAll(keepingCapacity: false)

        try? inbound?.close()
        inbound = nil

        if let process = child {
            let pid = process.processIdentifier
            if process.isRunning { process.terminate() }
            await waitForExit(of: pid)
            if isAlive(pid) {
                kill(pid, SIGKILL)
                await waitForExit(of: pid)
            }
        }

        try? outbound?.close()
        outbound = nil
        outboundDescriptor = nil
        child = nil
    }

    /// Whether `pid` still occupies a slot in the process table.
    ///
    /// Signal 0 performs the permission and existence checks and delivers nothing — the standard
    /// liveness probe. It answers `0` for a **zombie** too, which is the point: a reaped child and
    /// an exited-but-unreaped one are different states, and only the first is "no orphan".
    private nonisolated func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }

    /// Waits, bounded, for `pid` to leave the process table entirely.
    ///
    /// Polls rather than calling `Process.waitUntilExit()`, and the reason is measured rather than
    /// stylistic: `waitUntilExit()` spins the **calling thread's run loop** waiting for a source
    /// signalled against the run loop that was current when the child was launched. Launch and
    /// teardown here both happen on the concurrency pool, where run loops are not running and the
    /// thread is not even the same one twice — so the call blocks a cooperative thread forever and
    /// takes the suite with it. That is not a hypothetical; it is what this loop replaced.
    ///
    /// Bounded by ``terminationPolls``, so an unkillable child costs a bounded wait and not a hang
    /// — the same posture as every other wait in this type.
    private func waitForExit(of pid: pid_t) async {
        var remainingPolls = Self.terminationPolls
        while remainingPolls > 0, isAlive(pid) {
            remainingPolls -= 1
            await sleeper.wait(configuration.pollInterval)
        }
    }

    // MARK: - The pipe

    /// The frame delimiter: one message per line.
    private static let newline = UInt8(ascii: "\n")

    /// A carriage return, tolerated before the delimiter. A peer written on another platform is
    /// not a hostile peer.
    private static let carriageReturn = UInt8(ascii: "\r")

    /// How many polls a child gets to honour `SIGTERM` before it is killed outright.
    private static let terminationPolls = 100

    /// What one non-blocking read found.
    private enum ReadOutcome {
        /// Bytes, bounded by ``Configuration/readChunkBytes``.
        case bytes(Data)
        /// The pipe is open and empty. The peer is alive and has not spoken.
        case nothingYet
        /// The write end is closed. The child is gone, or has closed its stdout, which this seam
        /// cannot distinguish and does not need to.
        case endOfFile
        /// The descriptor itself failed. Treated as the peer being gone: a pipe we cannot read is
        /// a peer we cannot hear.
        case failed
    }

    /// One bounded, non-blocking read.
    ///
    /// Never reads "until the peer is done". A peer decides when it is done, and `/usr/bin/yes`
    /// is the reminder that some peers never are.
    private func readAvailable(from descriptor: Int32) -> ReadOutcome {
        var scratch = [UInt8](repeating: 0, count: Configuration.readChunkBytes)
        var errorNumber: Int32 = 0
        let count: Int = scratch.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return -1 }
            let result = read(descriptor, base, raw.count)
            errorNumber = errno
            return result
        }

        if count > 0 { return .bytes(Data(scratch[0..<count])) }
        if count == 0 { return .endOfFile }
        if errorNumber == EAGAIN || errorNumber == EWOULDBLOCK || errorNumber == EINTR {
            return .nothingYet
        }
        return .failed
    }

    /// What ``buffer`` currently holds.
    private enum FrameOutcome {
        /// One complete frame, removed from the buffer.
        case frame(Data)
        /// No complete frame, and the buffer is within the bound.
        case none
        /// The peer has passed ``Configuration/maxFrameBytes``. Terminal.
        case oversize
    }

    /// The next complete frame in ``buffer``, if there is one and it is within the bound.
    ///
    /// **Both oversize cases resolve here, in one place.** A delimiter-free run past the cap is
    /// the obvious one; a *complete* frame past the cap is the one that is easy to miss, because
    /// the delimiter can arrive in the same read as the bytes that broke the bound and a check
    /// written as "no delimiter yet, and too big" would never see it. That was a real defect in
    /// this file, caught by the acceptance rather than by reading: the peer's 4 KiB reply came
    /// back whole against a 64-byte cap and was delivered as a success.
    ///
    /// Every index comes from a search rather than from arithmetic, and the trailing byte is read
    /// through `last` rather than by subtracting one — the untrusted-peer discipline the frame
    /// parser above this seam follows for the same reason: an empty or single-byte line is exactly
    /// what a hostile peer sends.
    private func takeBufferedFrame() -> FrameOutcome {
        while let delimiter = buffer.firstIndex(of: Self.newline) {
            guard buffer.distance(from: buffer.startIndex, to: delimiter)
                <= configuration.maxFrameBytes
            else {
                return .oversize
            }
            let line = buffer[buffer.startIndex..<delimiter]
            buffer.removeSubrange(buffer.startIndex...delimiter)
            let trimmed = line.last == Self.carriageReturn ? line.dropLast() : line
            // A blank line is not a frame. Returning empty bytes would hand the protocol layer a
            // "frame" it must then decide is not one, in a type that cannot say so.
            if trimmed.isEmpty { continue }
            return .frame(Data(trimmed))
        }
        return buffer.count > configuration.maxFrameBytes ? .oversize : .none
    }

    /// Sets `SIGPIPE` to ignored, once per process, on the first launch.
    ///
    /// A `static let` rather than a flag, so the disposition is set exactly once however many
    /// transports are started, and **not at all** in a build that never starts one — which keeps
    /// the default configuration's footprint at nothing, the same property the rest of this type
    /// is written around.
    private static let brokenPipeSignalIgnored: Bool = {
        signal(SIGPIPE, SIG_IGN)
        return true
    }()

    private static func ignoreBrokenPipeSignal() {
        _ = brokenPipeSignalIgnored
    }
}

// MARK: - Launch failure

/// Why a child was not started.
///
/// A returned value rather than a thrown error, matching the seam: a launch that failed is a fact
/// the composition root must decide something about, and an omitted `catch` must not be able to
/// turn it into a transport that looks started.
public enum StdioLaunchFailure: Error, Equatable, Sendable {

    /// ``StdioMCPTransport/start()`` was called on a transport that already has a child, or on one
    /// that has been shut down. Restarting is not a thing this type does: a second child behind
    /// the same object would make "which process answered that frame" unanswerable.
    case alreadyStarted

    /// Nothing executable at that path. Checked before the spawn so that the common
    /// misconfiguration — a server that is not installed — is a named failure rather than a
    /// `Process` error string.
    case executableNotFound(String)

    /// The spawn itself failed, or the child could not be set up safely. Carries the reason as
    /// text, because the underlying failures are not a closed set.
    case notLaunched(String)
}

// MARK: - The injected wait

/// How the transport waits between polls of a child that has not spoken yet.
///
/// Injected for the reason `MonotonicClock` is injected (`MonotonicClock.swift:23-27`): a bound
/// that can only be observed by waiting for it is a bound no suite will keep testing. With this
/// seam and an injected clock, a ten-minute timeout is exercised in milliseconds, and the
/// assertion that the suite did *not* sleep is itself part of the acceptance.
public protocol StdioPollSleeper: Sendable {

    /// Suspends for roughly `duration`. A conformer may return immediately; the transport's
    /// progress is decided by the clock, never by this call's fidelity.
    func wait(_ duration: Duration) async
}

/// The shipped wait: `Task.sleep`.
///
/// Cancellation is swallowed on purpose. A cancelled sleep must not become a frame, and the loop
/// above re-reads the clock on the next turn either way — so a cancelled poll costs one extra
/// read, never a lost bound.
public struct TaskStdioPollSleeper: StdioPollSleeper {

    public init() {}

    public func wait(_ duration: Duration) async {
        try? await Task.sleep(for: duration)
    }
}

/// The shipped ``MonotonicClock`` for this transport: `ContinuousClock`, with the origin captured
/// at construction so ``now`` is a `Duration` since a process-local origin — the `MonotonicClock`
/// contract exactly, and no wall-clock semantics anywhere. The same shape as
/// `ContinuousMonotonicClock` in the ASR adapter; adapters may read a clock, and `VoccaCore` may
/// not.
public struct ContinuousStdioClock: MonotonicClock, Sendable {
    private let origin = ContinuousClock.now

    public init() {}

    public var now: Duration { ContinuousClock.now - origin }
}
