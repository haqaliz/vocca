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
import VoccaASR

/// The transport double the store tests are driven through, mirroring how ``StubEngine`` stands in
/// for the ASR engine: an in-memory byte source behind the real ``ModelTransport`` seam, with a
/// call counter, a recorded range ledger, and an async gate so that overlap claims are observed
/// rather than assumed.
///
/// The stub mirrors the real transport's file discipline: a transfer from `rangeStart == 0`
/// truncates and writes the body; a transfer from `rangeStart > 0` **appends** — the resume
/// contract the downloader's size check depends on. Bytes are written one at a time with a
/// per-byte cancellation check and sleep, so a test can cancel a download mid-transfer at a
/// deterministic point and observe a partial `.part` file.
///
/// Failure modes: ``Mode/failsFirstAttempt(afterBytes:)`` (the first call ever fails after N
/// bytes; later calls behave like ``Mode/happyPath``), ``Mode/corruptBytes`` (every call serves
/// bytes that cannot match the manifest digest), ``Mode/ignoresRange`` (every call serves the
/// full body regardless of `rangeStart` — appending it to partial data, which is what a
/// server that refuses Range causes).
actor StubTransport: ModelTransport {

    /// What a `download` may do.
    enum Mode: Sendable {
        /// Serve the remainder of the file from `rangeStart` (the whole file from zero).
        case happyPath
        /// The *first* download call ever fails after serving `afterBytes` bytes; every later
        /// call behaves like ``Mode/happyPath``. This is the "transfer died once" shape a resume
        /// exists to repair.
        case failsFirstAttempt(afterBytes: Int)
        /// Every call serves the file's bytes XOR-mangled — the same byte count, a digest that
        /// can never match — so verification fails and the restart loop is exercised.
        case corruptBytes
        /// Every call serves the **full** body regardless of `rangeStart`, appending it to
        /// whatever the destination already holds — a server that ignores Range. The downloader
        /// must detect the misaligned file (its size cannot equal `byteCount`) and restart.
        case ignoresRange
    }

    private let files: [String: [UInt8]]
    private let mode: Mode

    /// How many times `download` was entered — the ledger half of the single-flight claim: two
    /// concurrent `downloadIfMissing` calls must result in exactly one `download` here.
    private(set) var downloadCallCount = 0

    /// The `rangeStart` of every `download` call, in order — the resume ledger: a test asserts
    /// the second attempt resumed from the first attempt's partial size, or restarted from zero.
    private(set) var recordedRangeStarts: [Int] = []

    /// `true` while the gate is armed: every `download` that starts then waits until the next
    /// `releaseGate`. The gate stays armed across releases, so a test can park every download of a
    /// multi-file manifest in turn; it is a test-scoped object, so there is no disarm.
    private var gateArmed = false

    /// Downloads currently parked in the gate.
    private var gateWaiters: [CheckedContinuation<Void, Never>] = []

    /// How many downloads are parked in the gate right now — what a test polls to know the store is
    /// truly suspended inside the transport rather than merely scheduled.
    var gatedDownloads: Int { gateWaiters.count }

    init(files: [String: [UInt8]], mode: Mode = .happyPath) {
        self.files = files
        self.mode = mode
    }

    /// Arms the gate: the next `download` calls wait until ``releaseGate()``.
    func armGate() {
        gateArmed = true
    }

    /// Resumes every download currently parked in the gate. The gate stays armed.
    func releaseGate() {
        let waiters = gateWaiters
        gateWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }

    func download(
        file name: String,
        fromRangeStart rangeStart: Int,
        to destination: URL,
        onBytesWritten: (@Sendable (Int) -> Void)?
    ) async throws {
        downloadCallCount += 1
        recordedRangeStarts.append(rangeStart)
        await waitForGate()
        guard let bytes = files[name] else {
            throw StubTransportError.unknownFile(name)
        }

        let isFirstCallEver = downloadCallCount == 1
        var served = Array(bytes[rangeStart...])
        switch mode {
        case .happyPath:
            break
        case .failsFirstAttempt(let afterBytes) where isFirstCallEver:
            served = Array(served.prefix(afterBytes))
        case .failsFirstAttempt:
            break
        case .corruptBytes:
            served = served.map { ~$0 }
        case .ignoresRange:
            served = bytes
        }

        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: destination.path) {
            fileManager.createFile(atPath: destination.path, contents: nil)
        }
        let handle = try FileHandle(forUpdating: destination)
        defer { try? handle.close() }
        if rangeStart == 0 {
            try handle.truncate(atOffset: 0)
        }
        try handle.seekToEnd()

        for (index, byte) in served.enumerated() {
            // The cancellation point: a test cancels mid-transfer and observes a partial .part.
            try Task.checkCancellation()
            try await Task.sleep(for: .microseconds(5))
            try handle.write(contentsOf: Data([byte]))
            onBytesWritten?(index + 1)
        }

        if case .failsFirstAttempt(let afterBytes) = mode, isFirstCallEver, served.count == afterBytes {
            throw StubTransportError.transmissionFailed(name)
        }
    }

    private func waitForGate() async {
        guard gateArmed else { return }
        await withCheckedContinuation { continuation in
            gateWaiters.append(continuation)
        }
    }
}

/// The double's own errors: a `download` for a name that was never registered is a broken test
/// fixture, not a transport failure — and a deliberately failed first attempt is a test fixture
/// too, not a real transport error.
private enum StubTransportError: Error {
    case unknownFile(String)
    case transmissionFailed(String)
}
