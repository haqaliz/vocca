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
import XCTest

/// **Acceptance A3: the realtime path does none of the things that make audio glitch.**
///
/// CoreAudio's realtime thread has a deadline measured in milliseconds and no way to report missing
/// it. Anything that can block — an allocation, a lock, a log line, a reference-count operation, an
/// `await`, a hop to another executor — turns a missed deadline into a click the user hears, and it
/// does so intermittently, on their machine, with nothing in any log. There is no test that can
/// observe this: `AVAudioSinkNode` is unsupported in manual rendering mode, so CI never executes the
/// realtime block at all. The only available check reads the source.
///
/// ## How a function opts in
///
/// A function that runs on the realtime thread carries the line comment `// @realtime` immediately
/// before its declaration. This suite finds every one of them, extracts the body, and applies three
/// passes.
///
/// **Three passes, because each is blind to what the next one sees.** This repository has shipped
/// several checks that passed while measuring less than they claimed, and a single-pass version of
/// this lint would be another:
///
/// 1. **An allow-list over call names.** A `deinit`-style deny-list would pass the first forbidden
///    thing nobody thought of; the realtime body is tiny by construction, so an allow-list is
///    maintainable, and adding to it is a reviewed line in a diff.
/// 2. **A deny-list over identifiers.** ``SwiftSourceScanner/callNames(inBody:)`` reads the
///    identifier before a `(`, so it cannot see `Task { … }` — a call written entirely in
///    trailing-closure form, and the single most likely way for someone to try to signal a consumer
///    from the audio thread. Pass 1 is structurally blind to it.
/// 3. **Forbidden substrings.** `[Float](repeating:count:)` allocates and its call name is not an
///    identifier at all — the character before `(` is `]`. `"\(value)"` allocates and involves no
///    call token either. Passes 1 and 2 are both blind to these.
///
/// And the signature is checked as well as the body, because `throws` and `async` appear in neither.
final class RealtimeSafetyTests: XCTestCase {

    /// The marker. Everything this suite checks is selected by it and nothing else, so that a
    /// function joining the realtime path is a deliberate, greppable line rather than an inference
    /// from what it happens to call.
    static let marker = "// @realtime"

    /// Every declaration in `Sources/` that claims to run on the realtime thread, by file and name.
    ///
    /// Asserted as **set equality**, not as a minimum. Too few means a marker was deleted and a
    /// realtime function is now unlinted; too many means a function joined the realtime path without
    /// anyone reading this list. Phase 4 adds the `AVAudioSinkNode` block, and it should have to
    /// edit this line to do it.
    static let expectedRealtimeDeclarations: Set<String> = [
        "AudioRingBuffer.swift: write"
    ]

    /// What a realtime body may call.
    ///
    /// Each name is a claim that the call is bounded, lock-free and allocation-free:
    /// - `load`, `store`, `wrappingAdd` — `Synchronization.Atomic`, lock-free for a 64-bit word on
    ///   every platform this package supports.
    /// - `min` — arithmetic on `Int`.
    /// - `advanced`, `update` — pointer arithmetic and a `memmove` over trivial memory. No
    ///   allocation, no reference count, no bridging.
    /// - `Int`, `UInt64` — width conversions between fixed-width integers.
    static let permittedCalls: Set<String> = [
        "load", "store", "wrappingAdd",
        "min",
        "advanced", "update",
        "Int", "UInt64",
    ]

    /// Identifiers a realtime body may not mention, whether or not they are followed by a `(`.
    ///
    /// Grouped by the failure each one causes on the audio thread.
    static let forbiddenIdentifiers: Set<String> = [
        // Suspension and executor hops. The audio thread is not a cooperative-pool thread and
        // cannot be suspended; `Task` is also the shape someone reaches for to signal a consumer.
        "await", "async", "Task", "TaskGroup", "actor", "MainActor", "AsyncStream",
        "withCheckedContinuation", "withUnsafeContinuation",

        // Error handling. A throw allocates an existential box, and the signature check below
        // covers the declaration; these cover the body.
        "try", "throw", "throws", "rethrows",

        // Locks and semaphores, in every spelling available.
        "DispatchQueue", "DispatchSemaphore", "DispatchGroup", "DispatchSource", "DispatchWorkItem",
        "NSLock", "NSRecursiveLock", "NSCondition", "NSConditionLock", "Mutex",
        "os_unfair_lock", "os_unfair_lock_lock", "pthread_mutex_t", "pthread_mutex_lock",
        "lock", "unlock", "wait", "signal", "sync", "barrier",

        // Logging. Every logging API on this platform can allocate, take a lock, or both.
        "print", "NSLog", "os_log", "Logger", "OSLog", "debugPrint", "dump", "assertionFailure",

        // Allocation, directly or through a heap-backed type.
        "malloc", "calloc", "realloc", "free", "allocate", "deallocate", "autoreleasepool",
        "Array", "ContiguousArray", "String", "Dictionary", "Set", "Data", "AnyObject",
        "reserveCapacity", "append", "insert", "removeAll",

        // The consumer's wake mechanisms, named explicitly because "just yield to the consumer" is
        // the exact instinct `AudioRingBuffer`'s polling design exists to refuse.
        "yield", "notify", "sleep", "usleep", "sched_yield",
    ]

    /// Substrings neither identifier pass can see. See this type's header for why each is here.
    static let forbiddenSubstrings: [(text: String, why: String)] = [
        ("](", "an array or dictionary type instantiation such as [Float](repeating:count:) allocates"),
        ("\\(", "string interpolation allocates a String"),
    ]

    // MARK: - The lint, over Sources/

    /// The exact set of realtime declarations, so that neither a deleted marker nor an unreviewed
    /// new one is silent.
    func testTheRealtimeMarkersInTheSourcesAreExactlyTheExpectedSet() throws {
        let declarations = try Self.realtimeDeclarationsInSources()
        XCTAssertEqual(
            Set(declarations.map(\.qualifiedName)), Self.expectedRealtimeDeclarations,
            """
            The set of `\(Self.marker)` markers in Sources/ changed.

            Too few: a marker was deleted, so a function that runs on CoreAudio's realtime thread is \
            no longer linted by anything — and nothing in CI executes that code, so the lint is the \
            only check there is.
            Too many: a function joined the realtime path. That is a reviewed decision, not an \
            incidental one: add it to `expectedRealtimeDeclarations` in the same commit, and expect \
            the allow-list below to need widening.
            """)
    }

    /// Pass 1: an allow-list over everything the body calls.
    func testEveryRealtimeBodyCallsOnlyPermittedFunctions() throws {
        let declarations = try Self.realtimeDeclarationsInSources()
        XCTAssertFalse(declarations.isEmpty, "the lint found no realtime bodies, which is not a pass")

        for declaration in declarations {
            let offenders = SwiftSourceScanner.callNames(inBody: declaration.body)
                .subtracting(Self.permittedCalls)
            XCTAssertTrue(
                offenders.isEmpty,
                """
                \(declaration.qualifiedName) runs on CoreAudio's realtime thread and calls \
                \(offenders.sorted().joined(separator: ", ")), which is not on the allow-list.

                The thread has a deadline of a few milliseconds and no way to report missing one: an \
                allocation, a lock, a log line or an ARC operation becomes an audible click on the \
                user's machine, intermittently, with nothing in any log. If this call is genuinely \
                bounded and lock-free, add it to `permittedCalls` with the sentence that says why. \
                If it is not, it belongs on the consumer side of AudioRingBuffer.
                """)
        }
    }

    /// Pass 2: a deny-list over every identifier, which is what sees `Task { … }`.
    func testNoRealtimeBodyMentionsAForbiddenIdentifier() throws {
        let declarations = try Self.realtimeDeclarationsInSources()
        XCTAssertFalse(declarations.isEmpty, "the lint found no realtime bodies, which is not a pass")

        for declaration in declarations {
            let offenders = SwiftSourceScanner.identifiers(inBody: declaration.body)
                .intersection(Self.forbiddenIdentifiers)
            XCTAssertTrue(
                offenders.isEmpty,
                """
                \(declaration.qualifiedName) mentions \(offenders.sorted().joined(separator: ", ")) \
                on the realtime path. Several of these are invisible to the call-name pass because \
                they are written without parentheses — `Task { … }` most of all, which is how a \
                producer would try to wake its consumer. It does not wake it: it allocates on the \
                audio thread. AudioRingBuffer's consumer polls precisely so that nothing here needs \
                to signal.
                """)
        }
    }

    /// Pass 3: the shapes that carry no call token and no forbidden identifier at all.
    func testNoRealtimeBodyContainsAForbiddenConstruct() throws {
        let declarations = try Self.realtimeDeclarationsInSources()
        XCTAssertFalse(declarations.isEmpty, "the lint found no realtime bodies, which is not a pass")

        for declaration in declarations {
            for forbidden in Self.forbiddenSubstrings {
                XCTAssertFalse(
                    declaration.body.contains(forbidden.text),
                    """
                    \(declaration.qualifiedName) contains `\(forbidden.text)`: \(forbidden.why). \
                    Neither the call-name pass nor the identifier pass can see this shape, which is \
                    why there is a third one.
                    """)
            }
        }
    }

    /// The signature, which is where `throws` and `async` live and where neither body pass looks.
    func testNoRealtimeDeclarationIsThrowingOrAsynchronous() throws {
        let declarations = try Self.realtimeDeclarationsInSources()
        XCTAssertFalse(declarations.isEmpty, "the lint found no realtime bodies, which is not a pass")

        for declaration in declarations {
            let tokens = SwiftSourceScanner.identifiers(inBody: declaration.signature)
            XCTAssertTrue(
                tokens.isDisjoint(with: ["throws", "rethrows", "async"]),
                """
                \(declaration.qualifiedName)'s signature is `\(declaration.signature.trimmingCharacters(in: .whitespacesAndNewlines))`. \
                A realtime function can neither throw — the error box is a heap allocation, and the \
                audio thread has nobody to report to — nor suspend.
                """)
        }
    }

    // MARK: - Positive controls
    //
    // Without these, every test above is a scan that finds nothing and says so approvingly. Each
    // pass is shown rejecting the shape it exists to reject, and clearing the shape that ships.

    func testTheMarkerIsWhatSelectsADeclarationAndNothingElse() {
        let unmarked = """
            func write(_ samples: UnsafePointer<Float>, count: Int) -> Bool {
                return true
            }
            """
        XCTAssertTrue(
            Self.realtimeDeclarations(inSource: unmarked, file: "X.swift").isEmpty,
            "an unmarked function was linted, so the marker is not what selects")

        let marked = """
            // @realtime
            @discardableResult
            public func write(_ samples: UnsafePointer<Float>, count: Int) -> Bool {
                return true
            }
            """
        let found = Self.realtimeDeclarations(inSource: marked, file: "X.swift")
        XCTAssertEqual(found.map(\.qualifiedName), ["X.swift: write"])
        XCTAssertEqual(
            found.first?.body.trimmingCharacters(in: .whitespacesAndNewlines), "return true",
            "the body extracted was not the function's own")
    }

    /// A marker that is *not* directly before a declaration must be a loud failure, not a silent
    /// skip — a marker the extractor cannot resolve is a realtime function nothing is checking.
    func testAMarkerWithNoDeclarationAfterItIsAFailureAndNotASkip() {
        let orphaned = """
            // @realtime
            let notAFunction = 1
            """
        XCTAssertThrowsError(try Self.realtimeDeclarationsOrThrow(inSource: orphaned, file: "X.swift")) {
            XCTAssertTrue(
                "\($0)".contains("no function declaration"),
                "the orphaned marker was reported as something other than an unresolved marker")
        }
    }

    func testTheCallAllowListRejectsTheAllocationsAndLocksItExistsToReject() {
        let violations: [(String, String)] = [
            ("os_unfair_lock_lock(&lock)", "os_unfair_lock_lock"),
            ("buffer.append(sample)", "append"),
            ("logger.debug(message)", "debug"),
            ("queue.async(execute: work)", "async"),
        ]
        for (body, expected) in violations {
            XCTAssertTrue(
                SwiftSourceScanner.callNames(inBody: body).subtracting(Self.permittedCalls)
                    .contains(expected),
                "`\(body)` was not reported by the call allow-list")
        }

        let shipped = """
            let write = writeIndex.load(ordering: .relaxed)
            storage.advanced(by: offset).update(from: samples, count: firstRun)
            writeIndex.store(write &+ UInt64(count), ordering: .releasing)
            """
        XCTAssertTrue(
            SwiftSourceScanner.callNames(inBody: shipped).subtracting(Self.permittedCalls).isEmpty,
            "the shipped realtime body was reported as a violation, so this lint fails a correct build")
    }

    /// The pass-1 blind spot, demonstrated rather than asserted in prose: the call-name scan does
    /// not see `Task { … }`, and the identifier scan does.
    func testTheIdentifierDenyListSeesWhatTheCallScanStructurallyCannot() {
        let trailingClosureCall = "Task { await consumer.drain() }"

        XCTAssertFalse(
            SwiftSourceScanner.callNames(inBody: trailingClosureCall).contains("Task"),
            """
            The call scan reported `Task { … }`, which it cannot do — it reads the identifier before \
            a `(` and there is none. If this ever passes, the second pass may have become redundant; \
            check before deleting it.
            """)
        XCTAssertFalse(
            SwiftSourceScanner.identifiers(inBody: trailingClosureCall)
                .intersection(Self.forbiddenIdentifiers).isEmpty,
            "the identifier pass missed `Task { await … }`, so nothing in this suite catches it")
    }

    func testTheSubstringPassSeesWhatNeitherIdentifierPassCan() {
        let allocation = "let scratch = [Float](repeating: 0, count: count)"
        XCTAssertTrue(
            SwiftSourceScanner.callNames(inBody: allocation).subtracting(Self.permittedCalls).isEmpty,
            "the call scan reported [Float](…); if so this control needs a different example")
        XCTAssertTrue(
            allocation.contains(Self.forbiddenSubstrings[0].text),
            "the substring pass missed an array allocation on the realtime path")

        let interpolation = #"let message = "wrote \(count) samples""#
        XCTAssertTrue(
            interpolation.contains(Self.forbiddenSubstrings[1].text),
            "the substring pass missed a string interpolation on the realtime path")
    }

    // MARK: - The scan

    /// A declaration marked as running on the realtime thread.
    struct RealtimeDeclaration {
        let qualifiedName: String
        /// The text from `func` up to (not including) the opening brace.
        let signature: String
        /// The body, with comments stripped.
        let body: String
    }

    private enum ScanError: Error, CustomStringConvertible {
        case noSourcesFound(root: String)
        case noDeclarationAfterMarker(file: String)
        case unbalancedBody(file: String, name: String)

        var description: String {
            switch self {
            case .noSourcesFound(let root):
                return
                    "No .swift files were found under \(root), so this lint was evaluated against nothing."
            case .noDeclarationAfterMarker(let file):
                return
                    "\(file): a \(RealtimeSafetyTests.marker) marker has no function declaration after it. A marker the scan cannot resolve is a realtime function nothing is checking."
            case .unbalancedBody(let file, let name):
                return "\(file): the body of \(name) does not brace-balance, so it was not linted."
            }
        }
    }

    /// Every marked declaration under `Sources/`, failing loudly if there is nothing to scan.
    static func realtimeDeclarationsInSources() throws -> [RealtimeDeclaration] {
        let root = try PackageRootLocator.find(from: #filePath)
        let sources = root.appendingPathComponent("Sources")
        let files = SwiftSourceScanner.swiftFiles(under: sources)
        guard !files.isEmpty else { throw ScanError.noSourcesFound(root: sources.path) }

        var declarations: [RealtimeDeclaration] = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            declarations.append(
                contentsOf: try realtimeDeclarationsOrThrow(
                    inSource: source, file: file.lastPathComponent))
        }
        return declarations
    }

    /// Non-throwing form, for the controls that expect a clean parse.
    static func realtimeDeclarations(inSource source: String, file: String) -> [RealtimeDeclaration] {
        (try? realtimeDeclarationsOrThrow(inSource: source, file: file)) ?? []
    }

    /// Finds each ``marker``, then the first `func` after it, and returns that function's signature
    /// and brace-balanced body.
    ///
    /// The search for `func` runs over the *comment-stripped* remainder, so neither the marker's own
    /// prose nor a doc comment below it can be mistaken for a declaration. It inherits
    /// ``SwiftSourceScanner``'s known limit — not string-literal aware — which fails towards reading
    /// too much and therefore towards over-reporting, the safe direction for a lint.
    static func realtimeDeclarationsOrThrow(
        inSource source: String, file: String
    ) throws -> [RealtimeDeclaration] {
        var declarations: [RealtimeDeclaration] = []
        var searchRange = source.startIndex..<source.endIndex

        while let markerRange = source.range(of: marker, range: searchRange) {
            searchRange = markerRange.upperBound..<source.endIndex

            // Resume at the *line* after the marker, not at the character after it. The marker is
            // itself a comment, so anything following it on the same line is no longer recognisable
            // as one once the `//` is behind the range start — and a marker whose own prose said
            // "func" would otherwise be read as a declaration.
            let lineEnd =
                source[searchRange].firstIndex(of: "\n").map(source.index(after:))
                ?? source.endIndex
            let remainder = SwiftSourceScanner.stripComments(
                from: String(source[lineEnd..<source.endIndex]))
            let characters = Array(remainder)
            guard
                let keyword = nextFuncKeyword(in: characters),
                let name = identifier(in: characters, from: keyword + 4),
                let brace = characters[keyword...].firstIndex(of: "{")
            else {
                throw ScanError.noDeclarationAfterMarker(file: file)
            }
            guard
                let found = SwiftSourceScanner.bracedBody(in: characters, openingBraceIndex: brace)
            else {
                throw ScanError.unbalancedBody(file: file, name: name)
            }

            declarations.append(
                RealtimeDeclaration(
                    qualifiedName: "\(file): \(name)",
                    signature: String(characters[keyword..<brace]),
                    body: found.body))
        }
        return declarations
    }

    /// The index of the `f` of the next whole-word `func`, or `nil`.
    private static func nextFuncKeyword(in text: [Character]) -> Int? {
        let keyword = Array("func")
        var index = 0
        while index + keyword.count <= text.count {
            defer { index += 1 }
            guard Array(text[index..<(index + keyword.count)]) == keyword else { continue }
            if index > 0, text[index - 1].isLetter || text[index - 1].isNumber
                || text[index - 1] == "_"
            {
                continue
            }
            let after = index + keyword.count
            guard after < text.count, !text[after].isLetter, !text[after].isNumber,
                text[after] != "_"
            else { continue }
            return index
        }
        return nil
    }

    /// The first identifier at or after `from`.
    private static func identifier(in text: [Character], from: Int) -> String? {
        var index = from
        while index < text.count, !(text[index].isLetter || text[index] == "_") { index += 1 }
        var name = ""
        while index < text.count,
            text[index].isLetter || text[index].isNumber || text[index] == "_"
        {
            name.append(text[index])
            index += 1
        }
        return name.isEmpty ? nil : name
    }
}
