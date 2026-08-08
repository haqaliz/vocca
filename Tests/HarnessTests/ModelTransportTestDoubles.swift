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
/// call counter and an async gate so that overlap claims are observed rather than assumed.
///
/// The failure modes Phase 2 needs — fails-after-N-bytes, corrupt-bytes, ignores-Range — are
/// deliberately **not** built yet (the plan's Phase 1 takes only the happy path and the call
/// count). What is built now is the shape they will extend: the byte content is injectable per
/// file name, every `download` is counted, and the gate lets a test park a download mid-flight so
/// the store's state can be read while the store is suspended inside the transport. The mode
/// exists as an explicit enum with one case rather than as an if statement Phase 2 would have to
/// turn into one.
actor StubTransport: ModelTransport {

    /// What a `download` may do. Phase 1 has exactly one mode.
    enum Mode: Sendable {
        /// Serve the registered bytes for the file, whole — regardless of `rangeStart`. Range
        /// semantics arrive with Phase 2's resume tests (including the mode that *ignores* Range,
        /// which is the interesting one); Phase 1's store always asks from zero.
        case happyPath
    }

    private let files: [String: [UInt8]]
    private let mode: Mode

    /// How many times `download` was entered — the ledger half of the single-flight claim: two
    /// concurrent `downloadIfMissing` calls must result in exactly one `download` here.
    private(set) var downloadCallCount = 0

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
        switch mode {
        case .happyPath:
            await waitForGate()
            guard let bytes = files[name] else {
                throw StubTransportError.unknownFile(name)
            }
            try Data(bytes).write(to: destination)
            onBytesWritten?(bytes.count)
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
/// fixture, not a transport failure.
private enum StubTransportError: Error {
    case unknownFile(String)
}
