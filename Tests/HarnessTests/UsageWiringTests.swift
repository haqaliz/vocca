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

import XCTest

/// **Where the daily-use ledger is plugged in** — pinned, because nothing else can reach it.
///
/// `UsageRecorderTests` drives every decision the recorder makes. What it cannot drive is the
/// composition: that `configure` builds the recorder over the *shipped* store and the *local* day
/// provider, that the launch load happens at all, that the ledger's sink is the thing that folds,
/// and that termination flushes. `configure` is `@MainActor`, builds an audio graph and an event
/// tap, and is executed by nothing in CI; `main()` needs a run loop and a user pressing ⌘Q. So
/// this is a source scan, the ``SessionKindWiringTests`` shape — aimed at the smallest facts that
/// matter, with a planted-mutant guard so the scan cannot pass vacuously.
///
/// Each fact here is one a green suite would otherwise be silent about. A recorder built but never
/// loaded resets the ledger every launch. A sink that folds without asking the cadence writes only
/// at midnight and at quit. A quit that does not flush loses the interval's counts on every single
/// exit rather than only on a crash.
final class UsageWiringTests: XCTestCase {

    // MARK: - configure

    /// The recorder is built over the shipped store, the local day provider and the loop's own
    /// clock.
    ///
    /// All three are the wiring's job and none is checkable anywhere else: the store's default
    /// initialiser is the one that resolves `~/Library/Application Support/Vocca/` (no test may
    /// call it), the provider is what makes the day *local* rather than UTC, and the clock is the
    /// single instance every `Duration` in the process is minted from.
    func testConfigureBuildsTheRecorderOverTheShippedStoreAndTheLocalDayProvider() throws {
        let body = try Self.configureBody()
        guard !body.isEmpty else { return }

        XCTAssertTrue(
            body.contains("let usageRecorder = UsageRecorder("),
            """
            `configure` no longer builds a `UsageRecorder`. It is the holder that owns the live \
            window; without it the ledger has a vocabulary, a file and a day provider, and \
            nothing that has ever seen a session.
            """)
        XCTAssertTrue(
            body.contains("store: PersistentUsageStore()"),
            """
            The recorder is no longer built over the shipped store. \
            `PersistentUsageStore.init()` is the one initialiser that resolves the real \
            Application Support path — a store over anything else is a ledger the user never sees.
            """)
        XCTAssertTrue(
            body.contains("day: SystemCalendarDayProvider().provider"),
            """
            The recorder is no longer built over `SystemCalendarDayProvider`. It is the adapter \
            that makes "today" the day on the user's own wall — `epochSeconds / 86_400` posts a \
            New Yorker's evening dictations to tomorrow, every day, not at an edge case.
            """)
        XCTAssertTrue(
            body.contains("clock: clock"),
            """
            The recorder no longer takes the loop's clock. One clock instance mints every \
            `Duration` in this process; a second one here would make the write cadence measured \
            against a different timeline from everything else.
            """)
    }

    /// The window is loaded **at launch**, and the load does not block `configure`.
    ///
    /// A recorder that is never loaded starts every launch from an empty window: the counts would
    /// be written and then immediately replaced by a run that had not read them, and a seven-day
    /// streak (`ROADMAP.md:102`) would be unmeasurable by construction.
    func testConfigureLoadsThePersistedWindowAtLaunchWithoutBlocking() throws {
        let body = try Self.configureBody()
        guard !body.isEmpty else { return }

        XCTAssertTrue(
            body.contains("Task { await usageRecorder.load() }"),
            """
            The launch load is gone from `configure`, or it is no longer in a task. It must \
            happen — the ledger is a file nobody reads otherwise — and it must not block: \
            `configure` may not block (the recovery journal's assembly is deferred for the same \
            reason), and the store's load reads a file.
            """)
    }

    /// The ledger's sink folds every finalized record and then asks the cadence — in that order.
    ///
    /// The sink is the seam the whole aspect hangs off (`usage-wiring/spec.md` §1): it sees every
    /// finalize, including the ones the ledger's 512-record cap later evicts. Asking the cadence
    /// *after* the fold is what keeps the write off the dictation path — `finalize` has already
    /// returned by the time this task runs, and the fold itself never touches a file.
    func testTheLedgersSinkFoldsEachRecordAndThenAsksTheCadence() throws {
        let body = try Self.configureBody()
        guard !body.isEmpty else { return }

        guard let sink = body.range(of: "let ledger = LatencyLedger(sink:") else {
            XCTFail(
                """
                The ledger is no longer constructed with a sink. Without it a finalized record \
                reaches nothing: folding from `snapshot()` instead would double-count on every \
                pass and would silently drop whatever the 512-record cap had already evicted.
                """)
            return
        }
        let installation = String(body[sink.lowerBound...].prefix(400))
        Self.assertFoldsThenFlushes(installation)
    }

    // MARK: - main

    /// Termination hands the recorder's `flush()` to the quit policy.
    ///
    /// Every quit — ⌘Q, the Dock's, the tray menu's, the onboarding restart's — goes through
    /// `applicationShouldTerminate`, so that is the one hook that catches all of them. Without it
    /// the debounce's unwritten counts are lost on *every* exit rather than only on a crash,
    /// which is a different and much worse bargain than the one the interval was chosen for.
    ///
    /// It is wired in `main()` rather than in `App/VoccaApp.swift`, which
    /// `BundleConfigurationTests.testAppTargetSourceIsOnlyAShimToTheBootstrapModule` pins to an
    /// exact shim and which therefore cannot hold lifecycle code.
    func testMainHandsTheRecordersFlushToTheQuitPolicy() throws {
        let body = try Self.mainBody()
        guard !body.isEmpty else { return }

        XCTAssertTrue(
            body.contains("flushBeforeTerminating:"),
            """
            `main()` no longer gives the quit policy anything to do before terminating. The \
            counts folded since the last write live only in memory; a quit that does not commit \
            them throws them away on every ordinary exit.
            """)
        XCTAssertTrue(
            body.contains("flush()"),
            """
            The termination hook no longer reaches the recorder's `flush()`. `flushIfDue()` is \
            the wrong call here — it honours the interval, and termination has no next tick to \
            wait for.
            """)
    }

    // MARK: - The vacuity guard

    /// The scan rejects the wiring it exists to catch.
    ///
    /// Run against a sink that folds nothing, and against one that folds without ever asking the
    /// cadence, the same checks that pass above have to fail — otherwise this file would hold
    /// over a tree where the ledger's file is written at midnight and never again.
    func testTheWiringScanRejectsASinkThatDoesNotFoldOrDoesNotFlush() {
        let foldsNothing = "let ledger = LatencyLedger(sink: { _ in }) "
        XCTAssertFalse(
            foldsNothing.contains("usageRecorder.fold(record)"),
            "the scan would pass a sink that folds nothing — it does not look at the sink at all")

        let foldsWithoutCadence =
            "let ledger = LatencyLedger(sink: { record in Task { "
            + "await usageRecorder.fold(record) } }) "
        XCTAssertTrue(
            foldsWithoutCadence.contains("usageRecorder.fold(record)"),
            "the planted body does fold — the missing cadence is what is under test")
        XCTAssertFalse(
            foldsWithoutCadence.contains("usageRecorder.flushIfDue()"),
            """
            the scan would pass a sink that never asks the cadence, leaving the ledger written \
            only on a rollover and at quit
            """)
    }

    // MARK: - The scan

    /// Both halves of the sink's contract, asserted the same way wherever the installation is
    /// found — so the two call sites cannot check different things.
    private static func assertFoldsThenFlushes(_ installation: String) {
        guard let fold = installation.range(of: "await usageRecorder.fold(record)") else {
            XCTFail(
                """
                The sink no longer folds the record into the usage recorder: \(installation)
                """)
            return
        }
        guard let cadence = installation.range(of: "await usageRecorder.flushIfDue()") else {
            XCTFail(
                """
                The sink folds but never asks the cadence, so the window reaches disk only on a \
                day rollover and at quit — a crash would then cost a whole day rather than one \
                interval: \(installation)
                """)
            return
        }
        XCTAssertTrue(
            fold.upperBound <= cadence.lowerBound,
            """
            The cadence is consulted before the fold, so the record that triggered the write is \
            not in it — every write would be one session behind: \(installation)
            """)
    }

    /// `configure`'s body, comments stripped and whitespace collapsed — so a mention in prose is
    /// never mistaken for the wiring, and reformatting the file does not fail the pin.
    private static func configureBody() throws -> String {
        try body(afterDeclaration: "public static func configure(_ application: NSApplication)")
    }

    /// `main()`'s body, on the same terms.
    private static func mainBody() throws -> String {
        try body(afterDeclaration: "public static func main()")
    }

    /// The braced body following `declaration` in `AppBootstrap.swift`, normalised.
    private static func body(afterDeclaration declaration: String) throws -> String {
        let root = try PackageRootLocator.find(from: #filePath)
        let file = root.appendingPathComponent("Sources/VoccaBootstrap/AppBootstrap.swift")
        let source = SwiftSourceScanner.stripComments(
            from: try String(contentsOf: file, encoding: .utf8))
        guard let start = source.range(of: declaration) else {
            XCTFail(
                """
                `AppBootstrap.swift` no longer declares `\(declaration)`. That is where the usage \
                ledger is composed; if the declaration moved, this pin has to move with it rather \
                than be deleted.
                """)
            return ""
        }
        let characters = Array(source[start.upperBound...])
        guard let opening = characters.firstIndex(of: "{"),
            let braced = SwiftSourceScanner.bracedBody(
                in: characters, openingBraceIndex: opening)
        else {
            XCTFail("`\(declaration)` has no braced body the scan can read")
            return ""
        }
        // Every run of whitespace becomes one space, so a line break inside a call is invisible to
        // the scan and reformatting the file cannot fail a pin.
        return braced.body.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
