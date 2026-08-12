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
/// **immediately** before its declaration — only attributes and declaration modifiers may stand
/// between. This suite finds every one of them, extracts the body, and applies four passes.
///
/// **Four passes, because each is blind to what the others see.** This repository has shipped
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
///    call token either. A subscript, `scratch[0]`, carries no call token, no forbidden identifier
///    and not even a `](`. Passes 1 and 2 are blind to all three.
/// 4. **No mutation.** A realtime body may bind locals and call permitted functions. It may not
///    assign to anything else, because everything else it could assign to is either a heap-backed
///    collection (a copy-on-write uniqueness check, and possibly a reallocation) or a property on a
///    captured object (an ARC-relevant access and a dynamic exclusivity check). `sidecar.total +=
///    count` has no call token, no forbidden identifier and no forbidden substring; it is invisible
///    to the first three passes and it is exactly what a sink-node block will reach for.
///
/// And the signature is checked as well as the body, because `throws` and `async` appear in neither.
///
/// ## What these four still cannot see, stated rather than implied
///
/// "Each is blind to what the others see" is not "between them they see everything", and the
/// difference matters because **nothing in CI ever executes this code**. A text lint cannot reach:
///
/// - **A permitted *name* on a different receiver.** The allow-list matches the bare identifier
///   before a `(`, so an allocating method that happens to be called `update`, defined anywhere,
///   passes pass 1. `update`, `store`, `load`, `min`, `advanced`, `Int` and `UInt64` are permitted
///   names, not permitted operations. Closing this needs type resolution, which needs a real Swift
///   parser in the harness; the guard against it today is that ``expectedRealtimeDeclarations`` is
///   asserted as an equality, so the *set* of bodies a reviewer must read stays small and known.
/// - **What a called function does.** Pass 1 says `min` is bounded; it does not check that.
///
/// So this suite bounds the shapes, and a human bounds the semantics. That is the honest division,
/// and the reason the marker set is a reviewed constant rather than a discovered one.
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
        "AudioRingBuffer.swift: write",
        // Added after `room` was extracted from `write` and spent a round unlinted: an allocation
        // and a `print` inside it passed the whole suite. The header's compensating control is that
        // "the set of bodies a reviewer must read stays small and known" — it had grown from one to
        // two without this set changing, which is the control failing quietly.
        "AudioRingBuffer.swift: room",
        // Phase 4. The sink node's block, and the channel policy it calls.
        //
        // `receive` is the `AVAudioSinkNode` block itself. It lives in `AudioBufferListInterleaving.swift`
        // and not on the graph on purpose: `AVAudioSinkNode(receiverBlock: self.render)` with a
        // bound method on the graph captures the graph, so graph → node → block → graph is a cycle
        // and the graph's `deinit` — which is what stops the engine, and therefore what puts out
        // the orange mic indicator — never runs (measured with a probe against the real framework;
        // the whole argument is the interleaver's header). The block capturing the interleaver is
        // what keeps the graph releasable. `interleave` is where the strided copy actually
        // happens, and it is deliberately *not* in the graph file: `AudioBufferList` is a plain C
        // struct, so a test builds one and drives the copy — which is what turns "the declared
        // channel count matches the samples" from an obligation on the implementer into an
        // assertion. Both are marked, because both run on CoreAudio's thread and the marker is
        // what selects, not the file.
        "AudioBufferListInterleaving.swift: receive",
        "AudioBufferListInterleaving.swift: interleave",
    ]

    /// What a realtime body may call.
    ///
    /// Each name is a claim that the call is bounded, lock-free and allocation-free:
    /// - `load`, `store` — `Synchronization.Atomic`, a plain 64-bit load and a plain 64-bit store.
    ///   **Not `wrappingAdd`**, and its absence is deliberate: a read-modify-write is wait-free on
    ///   Apple silicon's LSE and would be perfectly safe here, but `AudioRingBuffer`'s second
    ///   invariant claim is that no atomic in that file is ever the target of one. Leaving the name
    ///   off this list is what makes the claim checkable instead of merely written down.
    /// - `min`, `max` — arithmetic on `Int` and `UInt64`.
    /// - `room` — `AudioRingBuffer.room(capacity:write:read:)`, two lines of fixed-width integer
    ///   arithmetic with no conversion that can trap **for any argument at all**, which is a
    ///   stronger claim than the one this entry made last round and is why `max(capacity, 0)` is in
    ///   it: the previous wording said "no conversion that can trap" while `UInt64(capacity)` died
    ///   on a negative capacity with `Fatal error: Negative value is not representable`. The
    ///   function is `public`, so "a constructed ring cannot reach it" was the same reasoning that
    ///   defended the trapping conversion `room` was extracted to remove. It is also **linted in its
    ///   own right** now — being on this list is a claim about the call, not a substitute for
    ///   reading the callee.
    /// - `advanced`, `update` — pointer arithmetic and a `memmove` over trivial memory. No
    ///   allocation, no reference count, no bridging.
    /// - `Int`, `UInt64` — width conversions between fixed-width integers.
    ///
    /// These are permitted **names**, not permitted operations — see this type's header for what
    /// that costs and why the marker set is pinned by equality as the compensating control.
    /// **It did not double, and the per-declaration allow-list was not needed.** Phase 4 was expected
    /// to roughly double this set and to make a per-declaration split worth having. It added four
    /// names, because the work the sink node does was written as pointer arithmetic against the ring
    /// rather than as anything new. The shared list stays shared, which keeps the reviewer's job one
    /// list rather than three; revisit if a later phase needs a name that is bounded in one body and
    /// not in another.
    static let permittedCalls: Set<String> = [
        "load", "store",
        "min", "max", "room",
        "advanced", "update",
        "Int", "UInt64",

        // Phase 4.
        // - `write` — `AudioRingBuffer.write`, itself on this list of linted bodies. The
        //   interleaver hands it the scratch buffer once per callback.
        // - `assumingMemoryBound` — a compile-time pointer type change. No allocation, no check, no
        //   runtime work at all; it is `unsafeBitCast` for pointers with a name that says what it
        //   assumes.
        // - `UnsafeRawPointer` — the same, as an initializer: a pointer-to-pointer conversion used
        //   once, to reach `mBuffers` at the byte offset resolved at construction. The offset is
        //   *not* computed here; `MemoryLayout.offset(of:)` takes a key path and a key path is not
        //   something to materialise on the audio thread.
        // - `interleave` — `AudioBufferListInterleaver.interleave`, linted in its own right. Being
        //   on this list is a claim about the call, not a substitute for reading the callee.
        "write", "assumingMemoryBound", "UnsafeRawPointer", "interleave",
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
    ///
    /// `[` subsumes `](` and is listed separately from it anyway, because the two report different
    /// things to whoever hits them and the message is most of a lint's value.
    static let forbiddenSubstrings: [(text: String, why: String)] = [
        (
            "](",
            "an array or dictionary type instantiation such as [Float](repeating:count:) allocates"
        ),
        ("\\(", "string interpolation allocates a String"),
        (
            "[",
            """
            a subscript on the realtime path is either a bounds check on a pointer — write it as \
            .advanced(by:) — or a copy-on-write uniqueness check on a heap-backed collection, which \
            can reallocate. The shipped body contains no `[` at all, so this costs nothing today \
            and makes the first one a deliberate argument rather than an accident
            """
        ),
    ]

    /// Assignment operators forbidden outright on the realtime path, and the shape pass 4 uses to
    /// find a bare `=` that is not a local binding.
    ///
    /// Compound assignment is always a mutation of something that already exists, which on this
    /// path is always either a collection or a property on a captured object.
    static let forbiddenAssignments: [String] = [
        "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "<<=", ">>=",
    ]

    /// Operators that end in `=` without being an assignment. Pass 4 must not read these as one.
    private static let comparisonSuffixes: Set<Character> = ["=", "!", "<", ">", "+", "-", "*", "/", "%", "&", "|", "^"]

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

    /// Pass 4: a realtime body binds locals and calls permitted functions. It mutates nothing.
    ///
    /// The two shapes this exists for — `scratch[0] = samples[0]` on a stored array and
    /// `sidecar.total += count` on a stored object — carry no call token, no forbidden identifier
    /// and (before `[` was added) no forbidden substring. Both survived the first three passes when
    /// they were planted.
    func testNoRealtimeBodyAssignsToAnythingButANewLocal() throws {
        let declarations = try Self.realtimeDeclarationsInSources()
        XCTAssertFalse(declarations.isEmpty, "the lint found no realtime bodies, which is not a pass")

        for declaration in declarations {
            let offenders = Self.mutatingStatements(inBody: declaration.body)
            XCTAssertTrue(
                offenders.isEmpty,
                """
                \(declaration.qualifiedName) mutates something on the realtime path:
                \(offenders.joined(separator: "\n"))

                A realtime body may bind locals and call permitted functions. Everything else it \
                could assign to is either a heap-backed collection — a copy-on-write uniqueness \
                check, and a reallocation if the check fails — or a property on a captured object, \
                which is an ARC-relevant access with a dynamic exclusivity check on it. If a sample \
                has to reach memory the buffer owns, it goes through a pointer, which is what \
                AudioRingBuffer.write does.
                """)
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

    func testTheCallAllowListRejectsTheAllocationsAndLocksItExistsToReject() throws {
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

        // The shipped bodies themselves, read from `Sources/` rather than transcribed. A
        // hand-written approximation of "the shipped body" had already drifted after one round —
        // it still carried the arithmetic as it read *before* `room` was extracted — and a control
        // that no longer resembles what it clears is a control that will pass whatever ships.
        for declaration in try Self.realtimeDeclarationsInSources() {
            XCTAssertTrue(
                SwiftSourceScanner.callNames(inBody: declaration.body)
                    .subtracting(Self.permittedCalls).isEmpty,
                """
                \(declaration.qualifiedName) was reported by the call allow-list, so this lint fails \
                a correct build. (The pass itself asserts the same thing; this control exists to \
                fail here first, where the message says the lint is wrong rather than the code.)
                """)
        }
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

        // The subscript, which carries no call token, no forbidden identifier and not even a `](`.
        let subscripting = "scratch[0] = samples[0]"
        XCTAssertTrue(
            SwiftSourceScanner.callNames(inBody: subscripting).subtracting(Self.permittedCalls)
                .isEmpty,
            "the call scan reported a subscript; if so this control needs a different example")
        XCTAssertTrue(
            SwiftSourceScanner.identifiers(inBody: subscripting)
                .intersection(Self.forbiddenIdentifiers).isEmpty,
            "the identifier scan reported a subscript; if so this control needs a different example")
        XCTAssertFalse(
            subscripting.contains(Self.forbiddenSubstrings[0].text),
            "`](` matched a plain subscript, so it was never the narrow rule it claimed to be")
        XCTAssertTrue(
            subscripting.contains(Self.forbiddenSubstrings[2].text),
            "a subscript reached the realtime path with every earlier pass green")
    }

    /// Pass 4's controls: the two shapes that defeated the first three, and the shipped body which
    /// must stay clear of it.
    func testTheMutationPassSeesWhatTheFirstThreeCannot() throws {
        let storedArrayWrite = "scratch[0] = samples[0]"
        let capturedObjectWrite = "sidecar.total += count"

        for body in [storedArrayWrite, capturedObjectWrite] {
            XCTAssertTrue(
                SwiftSourceScanner.callNames(inBody: body).subtracting(Self.permittedCalls).isEmpty,
                "`\(body)` was reported by the call pass; this control needs a different example")
            XCTAssertTrue(
                SwiftSourceScanner.identifiers(inBody: body)
                    .intersection(Self.forbiddenIdentifiers).isEmpty,
                "`\(body)` was reported by the identifier pass; pick a different example")
            XCTAssertEqual(
                Self.mutatingStatements(inBody: body), [body],
                "`\(body)` reached the realtime path with nothing reporting it")
        }

        // And the shipped shape must not be reported, or the lint fails a correct build. Every one
        // of these is a `let` binding, a comparison, or a call.
        // The same shape written with a semicolon, which is how this pass was bypassed in the round
        // it was added: the *line* starts with `let`, so a per-line first-token test skips it whole.
        let hiddenBehindASemicolon = "let probe = count; Self.sidecar.total = probe"
        XCTAssertTrue(
            SwiftSourceScanner.callNames(inBody: hiddenBehindASemicolon)
                .subtracting(Self.permittedCalls).isEmpty,
            "the call pass reported the semicolon form; this control needs a different example")
        XCTAssertEqual(
            Self.mutatingStatements(inBody: hiddenBehindASemicolon),
            ["Self.sidecar.total = probe"],
            """
            A mutation hidden after a `;` on a line beginning with `let` was not reported. That is \
            pass 4's own bypass: one extra character turns the exact shape this pass exists to catch \
            back into something nothing in the suite sees.
            """)

        // The shipped bodies, read from `Sources/` rather than transcribed — see the same control in
        // `testTheCallAllowListRejects…` for why. The version this replaced still carried the
        // arithmetic as it read *before* `room` was extracted, one round after the code moved.
        for declaration in try Self.realtimeDeclarationsInSources() {
            XCTAssertEqual(
                Self.mutatingStatements(inBody: declaration.body), [],
                "\(declaration.qualifiedName) was reported by pass 4, so it fails a correct build")
        }

        // A local `var` is stack storage and is allowed; mutating it afterwards is not, because the
        // scan cannot tell `total += 1` on a local from the same line on a captured property.
        XCTAssertEqual(Self.mutatingStatements(inBody: "var total = 0"), [])
        XCTAssertEqual(Self.mutatingStatements(inBody: "total += 1"), ["total += 1"])
    }

    /// The vacuity guard's own control: the scan **throws** on a tree with nothing in it.
    ///
    /// The first version of this test asserted that `SwiftSourceScanner.swiftFiles(under:)` returns
    /// nothing for an empty directory — a property of the file walk — while its doc comment claimed
    /// to stand for "the scan refuses to proceed when it returns nothing". Deleting the `guard`
    /// left the whole suite green. It now calls the scan itself.
    func testTheScanRefusesAnEmptyTreeRatherThanReportingNoViolations() throws {
        let empty = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vocca-realtime-lint-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }

        XCTAssertThrowsError(try Self.realtimeDeclarations(under: empty)) {
            XCTAssertTrue(
                "\($0)".contains("evaluated against nothing"),
                """
                An empty tree was reported as something other than a vacuous scan. A broken package \
                root must fail this suite loudly: every pass here returns "no violations" over zero \
                bodies, which reads exactly like a clean build.
                """)
        }
    }

    /// **A marker above anything that is not a `func` is an error, and this is the blocking fix of
    /// review round 2.**
    ///
    /// The closure is `AVAudioSinkNode`'s shape, which is what Phase 4 writes next, and the body
    /// planted in it allocates *and* logs. Before this fix the marker walked past the closure to the
    /// `func` below, both markers produced the same qualified name, `Set` collapsed them, the
    /// set-equality control was satisfied, and this allocating realtime body was read by nothing.
    func testAMarkerAboveAClosureIsRejectedRatherThanAdoptingTheNextFunction() {
        let sinkNodeShape = """
            // @realtime
            let sink = AVAudioSinkNode { _, frameCount, audioBufferList in
                let scratch = [Float](repeating: 0, count: Int(frameCount))
                print("captured \\(scratch.count)")
                return noErr
            }

            // @realtime
            public func write(_ samples: UnsafePointer<Float>, count: Int) -> Bool {
                return true
            }
            """

        XCTAssertThrowsError(
            try Self.realtimeDeclarationsOrThrow(inSource: sinkNodeShape, file: "Sink.swift")
        ) {
            XCTAssertTrue(
                "\($0)".contains("no function declaration"),
                """
                A marked closure was resolved to something instead of being rejected. If it resolved \
                to the `func` below, the two declarations carry the same qualified name, the \
                set-equality assertion collapses them into one, and an allocating, logging realtime \
                body ships with the whole suite green — which is measured, not hypothetical.
                """)
        }

        // And the modifiers that legitimately stand between a marker and its function still do.
        for prefix in ["", "@discardableResult\n", "@inlinable\npublic final ", "nonisolated static "]
        {
            let marked = """
                // @realtime
                \(prefix)func render(count: Int) -> Bool {
                    return true
                }
                """
            XCTAssertEqual(
                Self.realtimeDeclarations(inSource: marked, file: "X.swift").map(\.qualifiedName),
                ["X.swift: render"],
                "the modifier prefix `\(prefix)` made a legitimate marked function unreachable")
        }
    }

    /// `unbalancedBody`'s control: a marked declaration whose braces never close must be an error,
    /// not a body the scan quietly truncates or skips.
    func testAMarkedDeclarationWithUnbalancedBracesIsAnError() {
        let truncated = """
            // @realtime
            func write(count: Int) -> Bool {
                if count > 0 {
                    return true
            """
        XCTAssertThrowsError(
            try Self.realtimeDeclarationsOrThrow(inSource: truncated, file: "X.swift")
        ) {
            XCTAssertTrue(
                "\($0)".contains("brace-balance"),
                "an unbalanced marked body was reported as something other than unbalanced")
        }
    }

    /// Lines in `body` that assign to something other than a newly bound local.
    ///
    /// Statement-based and deliberately crude. A statement counts as a mutation if it contains a
    /// compound assignment operator, or a bare `=` — one not part of `==`, `<=`, `!=`, `&=` and the
    /// rest — and its first token is neither `let` nor `var`. A multi-line expression whose
    /// continuation begins with `=` would be reported, which is over-reporting and therefore the
    /// safe direction for a lint; no shipped body is written that way.
    ///
    /// **A `;` separates statements as surely as a newline, and missing that was this pass's own
    /// bypass in the round it was added.** `let probe = count; Self.sidecar.total = probe` — a write
    /// to a property on a captured object, the exact shape pass 4 exists for — cleared passes 1-3
    /// for the same reasons `sidecar.total += count` does, and cleared pass 4 because the *line*
    /// began with `let`. Splitting on `;` first is the whole fix.
    static func mutatingStatements(inBody body: String) -> [String] {
        var offenders: [String] = []

        let statements = SwiftSourceScanner.stripComments(from: body)
            .replacingOccurrences(of: ";", with: "\n")
        for rawLine in statements.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if forbiddenAssignments.contains(where: line.contains) {
                offenders.append(line)
                continue
            }

            let first = line.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
            guard first != "let", first != "var" else { continue }
            guard !isAStoreThroughAPointer(line) else { continue }
            if containsABareAssignment(line) { offenders.append(line) }
        }
        return offenders
    }

    /// Whether `line` is a store through a pointer — `somePointer.advanced(by: i).pointee = …`.
    ///
    /// **The one exemption pass 4 has, added by Phase 4 and anticipated by the plan that asked for
    /// it.** Interleaving a deinterleaved `AudioBufferList` is a *strided* copy: destination index
    /// `frame * channels + channel`, source index `frame * channelsInBuffer + channel`. A stride
    /// cannot use `update(from:count:)`, which copies a contiguous run, so it needs a per-element
    /// store — and pass 4 reports that, because it cannot tell a pointer store from
    /// `sidecar.total = count`.
    ///
    /// The exemption is deliberately about the **left-hand side and nothing else**: the assignment
    /// target must end in `.pointee`. That is exactly what `update(from:count:)` already does,
    /// unrolled — a write through a pointer into memory the object owns. It is neither of the two
    /// shapes this pass exists for:
    ///
    /// - a copy-on-write uniqueness check on a stored collection (`scratch[0] = …`), which pass 3
    ///   already refuses on the `[` and which does not end in `.pointee` either;
    /// - a property write on a captured object (`sidecar.total = count`), which ends in the property
    ///   name.
    ///
    /// **Compound assignment is untouched.** `pointer.pointee += 1` is still reported, because the
    /// compound rule runs first and unconditionally — a read-modify-write is a different claim from
    /// a store, and `AudioRingBuffer`'s whole atomic argument rests on the difference.
    private static func isAStoreThroughAPointer(_ line: String) -> Bool {
        guard let equals = line.firstIndex(of: "=") else { return false }
        return line[line.startIndex..<equals]
            .trimmingCharacters(in: .whitespaces)
            .hasSuffix(".pointee")
    }

    /// Whether `line` contains an `=` that is an assignment rather than part of a comparison or a
    /// compound operator.
    private static func containsABareAssignment(_ line: String) -> Bool {
        let characters = Array(line)
        for (index, character) in characters.enumerated() where character == "=" {
            let before = index > 0 ? characters[index - 1] : " "
            let after = index + 1 < characters.count ? characters[index + 1] : " "
            if comparisonSuffixes.contains(before) || after == "=" { continue }
            return true
        }
        return false
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
        return try realtimeDeclarations(under: root.appendingPathComponent("Sources"))
    }

    /// The same scan over an arbitrary root, so that the vacuity guard has somewhere to be tested
    /// from.
    ///
    /// It was not, for a round: the control written for it asserted that
    /// `SwiftSourceScanner.swiftFiles(under:)` returns nothing for an empty directory — a property
    /// of the file *walk* — while claiming to stand for "this refuses to proceed when it returns
    /// nothing". Deleting the `guard` below left the whole suite green. Taking the root as a
    /// parameter is what makes the guard reachable from a test at all.
    static func realtimeDeclarations(under root: URL) throws -> [RealtimeDeclaration] {
        let files = SwiftSourceScanner.swiftFiles(under: root)
        guard !files.isEmpty else { throw ScanError.noSourcesFound(root: root.path) }

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

    /// Finds each ``marker``, requires it to sit **immediately** above a `func`, and returns that
    /// function's signature and brace-balanced body.
    ///
    /// "Immediately" is the whole of this round's blocking fix, so it is worth stating exactly. The
    /// scan used to take the *next* `func` anywhere below the marker, walking past whatever lay
    /// between. Measured: a marker placed above a **closure** containing `[Float](repeating:count:)`
    /// and `print(…)`, sited just above `write`'s own marker, passed the entire suite — both markers
    /// resolved to `write`, the two qualified names were identical, `Set` collapsed them to one
    /// element, the set-equality assertion that is supposed to be the compensating control was
    /// satisfied, all four passes ran over `write`'s body twice, and the allocating closure was read
    /// by nothing.
    ///
    /// **That is the exact shape Phase 4 writes next.** `AVAudioSinkNode`'s receiver block is a
    /// closure literal with no `func` in it, and acceptance A3 is "the realtime block allocates
    /// nothing — asserted by a source lint". A lint blind to the only realtime block that matters is
    /// not an assertion. So a marker that does not resolve to a `func` is now an error, and
    /// `plan_20260806.md`'s Phase 4 says to write the sink body as a named function passed to the
    /// node rather than inline.
    ///
    /// The search runs over the *comment-stripped* remainder, so neither the marker's own prose nor
    /// a doc comment below it can be mistaken for a declaration. It inherits ``SwiftSourceScanner``'s
    /// known limit — not string-literal aware — which fails towards reading too much and therefore
    /// towards over-reporting, the safe direction for a lint.
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
                let keyword = funcKeywordDirectlyBelow(characters),
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

    /// Tokens that may stand between a marker and the `func` it marks: attributes, and the
    /// declaration modifiers Swift allows in front of a method.
    ///
    /// An allow-list, and it has to be. A deny-list — or the old "find the next `func`" — walks past
    /// `let sink = AVAudioSinkNode { … }` and lands on whatever function follows, which is how a
    /// marked closure came to be silently linted as somebody else's body.
    private static let permittedDeclarationModifiers: Set<String> = [
        "public", "internal", "package", "private", "fileprivate", "open",
        "static", "class", "final", "override", "mutating", "nonmutating", "dynamic",
        "consuming", "borrowing", "nonisolated",
    ]

    /// The index of the `f` of the `func` keyword **directly** below the marker, or `nil` if the
    /// next thing is not a function declaration.
    ///
    /// Directly means: only attributes (`@discardableResult`, `@inlinable`, …) and the modifiers
    /// above may intervene. Anything else — `let`, `var`, a closure, a type declaration — is not a
    /// marked function, and returning `nil` here is what turns it into a loud error rather than a
    /// marker that quietly adopts the next function it can find.
    private static func funcKeywordDirectlyBelow(_ text: [Character]) -> Int? {
        var index = 0
        while index < text.count {
            while index < text.count, text[index].isWhitespace { index += 1 }
            guard index < text.count else { return nil }

            // One token: everything up to the next whitespace.
            var end = index
            while end < text.count, !text[end].isWhitespace { end += 1 }
            let token = String(text[index..<end])

            if token == "func" { return index }

            // The leading identifier of the token, so that `private(set)` and `@_spi(X)` are
            // classified by what they are rather than rejected for their parentheses.
            let head = String(token.prefix { $0.isLetter || $0 == "_" || $0 == "@" })
            guard head.hasPrefix("@") || permittedDeclarationModifiers.contains(head) else {
                return nil
            }
            index = end
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
