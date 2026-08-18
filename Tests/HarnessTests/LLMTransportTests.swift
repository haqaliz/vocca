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
import VoccaText
import XCTest

/// The LLM transport seam: the vocabulary `ARCHITECTURE.md:16` names as the second network type,
/// as code, with the error vocabulary and the stub's failure modes pinned.
///
/// ``DefaultLLMTransport`` is executed by nothing in CI (the ``DefaultModelTransport`` precedent):
/// `URLSession` works on a hosted runner in principle, but no test dials the real network and the
/// zero-network probe would flag any `connect(2)`. So the decisions are tested **above** the seam —
/// over this stub, which can emit every failure mode a provider will need to map — and the real
/// adapter's translation is the smoke-verified surface (`root-wiring` M10).
///
/// The B2 contract (`spec.md`, amended by the plan): the error **vocabulary** is pinned here, and
/// the stub can produce each case, so future providers test their own mapping over the closed set.
final class LLMTransportTests: XCTestCase {

    /// B1 — the seam exists and a stub conformer round-trips: a request in, a response out, and the
    /// request recorded verbatim for the shape assertions (B4).
    func testTheSeamRoundTripsARequestIntoAResponse() async throws {
        func requireTransport(_ transport: any LLMTransport) -> any LLMTransport { transport }

        let expected = LLMResponse(statusCode: 200, body: Data("{\"ok\":true}".utf8))
        let stub = StubLLMTransport(mode: .happyPath(response: expected))
        let transport: any LLMTransport = requireTransport(stub)

        let request = LLMRequest(
            url: URL(string: "https://example.com/v1/chat")!,
            headers: ["Content-Type": "application/json"],
            body: Data("{\"prompt\":\"hello\"}".utf8))

        let response = try await transport.complete(request)

        XCTAssertEqual(response.statusCode, expected.statusCode)
        XCTAssertEqual(response.body, expected.body)
        let recorded = await stub.recordedRequests
        XCTAssertEqual(recorded.count, 1)
        XCTAssertEqual(recorded.first?.url, request.url)
    }

    /// B1 — the seam is `Sendable`: an `any LLMTransport` existential satisfies a `Sendable`-bound
    /// generic, so a conformance that stops being Sendable stops building the test.
    func testTheTransportExistentialIsSendable() {
        func requireSendable<T: Sendable>(_ value: T) {}
        let transport: any LLMTransport = StubLLMTransport(
            mode: .happyPath(response: LLMResponse(statusCode: 200, body: Data())))
        requireSendable(transport)
    }

    /// B3 — the vocabulary is closed at exactly three cases, distinct from each other. The
    /// exhaustive switch only compiles while the set is exactly these three, and the distinct
    /// discriminators make a collapsed or aliased case fail at runtime instead of silently.
    func testTheErrorVocabularyIsClosedAndDistinct() {
        XCTAssertEqual(LLMTransportTests.discriminator(.unreachable), 0)
        XCTAssertEqual(LLMTransportTests.discriminator(.serverStatus(418)), 1)
        XCTAssertEqual(LLMTransportTests.discriminator(.invalidResponse), 2)
        XCTAssertNotEqual(LLMTransportTests.discriminator(.unreachable), LLMTransportTests.discriminator(.invalidResponse))
    }

    /// B3 — `serverStatus` carries the status code the caller can log (body deliberately absent).
    func testServerStatusCarriesTheStatusCode() {
        guard case .serverStatus(let code) = LLMTransportError.serverStatus(418) else {
            return XCTFail("serverStatus must carry its status code")
        }
        XCTAssertEqual(code, 418)
    }

    /// B3 — the stub can emit every case of the vocabulary, so a future provider tests its own
    /// mapping over the closed set (the B2 reframe).
    func testTheStubEmitsEveryFailureMode() async {
        let rows: [(mode: StubLLMTransport.Mode, expected: LLMTransportError)] = [
            (.failsUnreachable, .unreachable),
            (.serverStatus(500), .serverStatus(500)),
            (.malformedResponse, .invalidResponse),
        ]
        for row in rows {
            let stub = StubLLMTransport(mode: row.mode)
            do {
                _ = try await stub.complete(
                    LLMRequest(url: URL(string: "https://example.com/")!, headers: [:], body: Data()))
                XCTFail("mode \(row.mode) must throw")
            } catch let thrown as LLMTransportError {
                Self.assertMatches(thrown, row.expected)
            } catch {
                XCTFail("unexpected error type: \(error)")
            }
        }
    }

    /// B4 — the default method is `POST`, exactly as the spec's vocabulary declares it.
    func testTheDefaultMethodIsPost() {
        let request = LLMRequest(
            url: URL(string: "https://example.com/")!, headers: [:], body: Data())
        XCTAssertEqual(request.method, "POST")
    }

    /// B4 — the recorded request carries URL, method, headers and body verbatim.
    func testRecordedRequestsCarryUrlMethodHeadersAndBody() async throws {
        let stub = StubLLMTransport(
            mode: .happyPath(response: LLMResponse(statusCode: 200, body: Data("{}".utf8))))
        let url = URL(string: "https://example.com/v1/chat")!
        let headers = ["Content-Type": "application/json", "X-Trace-Id": "abc123"]
        let body = Data("{\"prompt\":\"hello world\"}".utf8)
        let request = LLMRequest(url: url, method: "POST", headers: headers, body: body)

        _ = try await stub.complete(request)

        let recorded = await stub.recordedRequests
        XCTAssertEqual(recorded.count, 1)
        let sent = try XCTUnwrap(recorded.first)
        XCTAssertEqual(sent.url, url)
        XCTAssertEqual(sent.method, "POST")
        XCTAssertEqual(sent.headers, headers)
        XCTAssertEqual(sent.body, body)
    }

    /// B4 — the hang mode parks a call deterministically: the call is truly suspended inside the
    /// gate (not merely scheduled), and the release completes it with an observable response.
    func testTheHangModeParksACallUntilTheGateReleases() async throws {
        let gate = AsyncGate()
        await gate.arm()
        let stub = StubLLMTransport(mode: .hangs(gate: gate))

        let task = Task {
            try await stub.complete(
                LLMRequest(url: URL(string: "https://example.com/")!, headers: [:], body: Data()))
        }

        for _ in 0..<1000 where await gate.parkedCount == 0 {
            try await Task.sleep(for: .microseconds(100))
        }
        XCTAssertEqual(await gate.parkedCount, 1, "the hang mode must park the call until released")

        await gate.release()
        let completed = try await task.value
        XCTAssertEqual(completed.statusCode, 200)
        XCTAssertEqual(completed.body, Data("{\"done\":true}".utf8))
    }

    // MARK: - Helpers

    /// A distinct discriminator per vocabulary case, so distinctness is observable. The closed set
    /// is a compile-time pin (an exhaustive switch over all three cases).
    private static func discriminator(_ error: LLMTransportError) -> Int {
        switch error {
        case .unreachable:
            return 0
        case .serverStatus:
            return 1
        case .invalidResponse:
            return 2
        }
    }

    /// Asserts `thrown` is exactly `expected` — including the carried status code for
    /// `serverStatus`.
    private static func assertMatches(
        _ thrown: LLMTransportError,
        _ expected: LLMTransportError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch (thrown, expected) {
        case (.unreachable, .unreachable), (.invalidResponse, .invalidResponse):
            break
        case (.serverStatus(let thrownCode), .serverStatus(let expectedCode)):
            XCTAssertEqual(thrownCode, expectedCode, file: file, line: line)
        default:
            XCTFail("expected \(expected), got \(thrown)", file: file, line: line)
        }
    }
}

/// The transport double the LLM seam's tests drive through (the ``StubTransport`` shape,
/// `ModelTransportTestDoubles.swift:34-153`): an in-memory responder behind the real ``LLMTransport``
/// seam with a recorded-request ledger and an async gate, so a call can be parked deterministically.
///
/// Failure modes: ``Mode/failsUnreachable`` throws `LLMTransportError.unreachable`,
/// ``Mode/serverStatus(_:)`` throws `LLMTransportError.serverStatus(_:)` and
/// ``Mode/malformedResponse`` throws `LLMTransportError.invalidResponse` — every case the
/// vocabulary defines, so a future provider tests its own mapping over the closed set.
actor StubLLMTransport: LLMTransport {

    /// What a `complete` call may do.
    enum Mode: Sendable {
        /// Serve `response` verbatim.
        case happyPath(response: LLMResponse)
        /// Throw `LLMTransportError.unreachable` — a connection-family failure.
        case failsUnreachable
        /// Throw `LLMTransportError.serverStatus(code)` — body-less by contract.
        case serverStatus(Int)
        /// Throw `LLMTransportError.invalidResponse` — a non-HTTP or undecodable response.
        case malformedResponse
        /// Park every call at `gate` until it is released; each released call completes with a
        /// 200 empty-object response so the release is observable.
        case hangs(gate: AsyncGate)
    }

    private let mode: Mode

    /// Every request `complete` received, in order — the shape ledger (B4).
    private(set) var recordedRequests: [LLMRequest] = []

    init(mode: Mode) {
        self.mode = mode
    }

    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        recordedRequests.append(request)
        switch mode {
        case .happyPath(let response):
            return response
        case .failsUnreachable:
            throw LLMTransportError.unreachable
        case .serverStatus(let code):
            throw LLMTransportError.serverStatus(code)
        case .malformedResponse:
            throw LLMTransportError.invalidResponse
        case .hangs(let gate):
            await gate.waitIfArmed()
            return LLMResponse(statusCode: 200, body: Data("{\"done\":true}".utf8))
        }
    }
}

/// The async gate ``StubLLMTransport`` parks on — the `armGate`/`releaseGate` shape from
/// ``StubTransport``, as its own actor so a mode can carry it. The gate stays armed across
/// releases, matching the precedent.
actor AsyncGate {
    private var armed = false
    private var parked: [CheckedContinuation<Void, Never>] = []

    /// How many calls are parked right now — what a test polls to know a call is truly suspended
    /// inside the transport rather than merely scheduled.
    var parkedCount: Int { parked.count }

    /// Arms the gate: the next calls wait until ``release()``.
    func arm() {
        armed = true
    }

    /// Resumes every parked call. The gate stays armed.
    func release() {
        let waiters = parked
        parked = []
        for waiter in waiters {
            waiter.resume()
        }
    }

    func waitIfArmed() async {
        guard armed else { return }
        await withCheckedContinuation { continuation in
            parked.append(continuation)
        }
    }
}
