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

import AppKit
import ApplicationServices

/// **The context adapter's AX file — the one file in `VoccaContext` permitted to speak
/// Accessibility** (the accessibility family's second seam row, `"context"`, beside
/// `AXSource`'s `"accessibility"`).
///
/// Public because the composition root constructs it (`bootstrap-wiring` builds
/// ``AccessibilityContext`` with this adapter and ``ContextSecureInputRead``). The public surface
/// is the constructor and the one protocol witness — the class's raw answer, exactly the shape
/// ``ContextAXReading`` already consumed when the adapter was module-internal.
///
/// It answers "what is the focused application and its selection right now": the bundle
/// identifier and focused window's title via the `kAXFocusedApplicationAttribute` →
/// `kAXFocusedWindowAttribute` → `kAXTitleAttribute` walk (with `AXUIElementGetPid` →
/// `NSRunningApplication` for the bundle identifier — the one place this file leaves AX for
/// AppKit), and the selection via the focused UI element's `kAXSelectedTextAttribute`. The
/// `kAXSelectedTextAttribute` *read* is a new read beside `AXSource`'s write of the same
/// attribute — a decisionless translation, raw results only.
///
/// ## The recorded posture (D6, `accessibility-context` plan)
///
/// Like the tap adapter, this file is **executed by nothing in CI on its success path**: `AX`
/// calls need an Accessibility grant and a real focused application, TCC cannot be granted on a
/// hosted runner, and no test can drive another application's focus. What **does** run in CI is
/// the failure path: the network probe's ``ContextDrive`` constructs this file and resolves once,
/// and without a grant the copies answer an error — the empty snapshot, deterministically. That
/// is the same honest-empty contract the corpus harness measures; the grant-dependent success
/// path stays unreachable in CI, now and ever. The two-sided pin keeps the family confined, and
/// the decisions that would live here are made above the seam, where they are tested:
///
/// | The question | Where it is answered |
/// |---|---|
/// | What does a failed or timed-out read mean? | ``AccessibilityContext`` (empty snapshot, never a throw — R1) |
/// | What does Secure Input active mean? | ``AccessibilityContext`` (refusal before this file is consulted — M5b/D3) |
/// | What does a `""` selection mean? | ``ContextSnapshot``'s nil semantics (`ContextSnapshot.swift:25-35`) |
///
/// ## Isolation and the per-call timeout
///
/// Every call runs on this file's dedicated serial queue, under a per-call timeout below the
/// system default — `AXUIElementCopyAttributeValue` against an unresponsive application blocks
/// for the system default (seconds), and that is the frozen-UI trap `ARCHITECTURE.md:323` warns
/// of. The caller waits on a semaphore for at most ``callTimeout``; a timed-out call answers as a
/// failure. The class holds no mutable state, so `Sendable` is checked, not asserted.
public final class AXContextSource: ContextAXReading, Sendable {

    /// The per-call budget, below the system default: one answer per question, no matter how
    /// unresponsive the focused application is.
    private static let callTimeout: TimeInterval = 0.5

    /// The one queue every AX call in this file runs on. AX is not documented as thread-safe
    /// across simultaneous calls on one element, so a single serial queue is the safe shape —
    /// and it is a background queue, never the main thread, which is how the "AX calls never run
    /// on the main thread" rule is satisfied for this file.
    private let callQueue = DispatchQueue(label: "dev.vocca.context-ax-source", qos: .userInitiated)

    /// The composition root's construction — a plain adapter, no arguments and no grants
    /// required to build it (the grant gates the *calls*, not the object).
    public init() {}

    /// The focused application's identity and selection, raw: bundle identifier, focused
    /// window's title, and the focused field's selection. `nil` when the system answers
    /// "nothing focused" or any copy fails (including a timeout).
    public func readContext() -> RawContextRead? {
        timedCall { () -> RawContextRead? in
            guard let appElement = self.copyElement(
                kAXFocusedApplicationAttribute as CFString, on: AXUIElementCreateSystemWide())
            else { return nil }
            return RawContextRead(
                bundleID: self.bundleIdentifier(of: appElement),
                windowTitle: self.focusedWindowTitle(of: appElement),
                selectedText: self.selectedText())
        }
    }

    // MARK: - Raw helpers (translation only)

    /// One attribute copy, as raw as the C call: `.success` → the value, anything else → `nil`.
    private func copyAttribute(_ attribute: CFString, on element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == AXError.success else {
            return nil
        }
        return value
    }

    /// One attribute copy that is expected to answer an AX element, with the CFTypeID check the
    /// strict-concurrency rule demands of a CoreFoundation downcast: the copy succeeded *and*
    /// the system says the value is an element.
    private func copyElement(_ attribute: CFString, on element: AXUIElement) -> AXUIElement? {
        guard
            let value = copyAttribute(attribute, on: element),
            CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    /// The focused UI element — the text field whose selection is reported — via the
    /// system-wide element's `kAXFocusedUIElementAttribute`.
    private func focusedElement() -> AXUIElement? {
        copyElement(
            kAXFocusedUIElementAttribute as CFString, on: AXUIElementCreateSystemWide())
    }

    /// The focused application's bundle identifier: `AXUIElementGetPid` → `NSRunningApplication`.
    private func bundleIdentifier(of app: AXUIElement) -> String? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(app, &pid) == AXError.success else { return nil }
        return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }

    /// The focused window's title: the application element's `kAXFocusedWindowAttribute`, then
    /// that window's `kAXTitleAttribute`.
    private func focusedWindowTitle(of app: AXUIElement) -> String? {
        guard let windowElement = copyElement(
            kAXFocusedWindowAttribute as CFString, on: app)
        else { return nil }
        return copyAttribute(kAXTitleAttribute as CFString, on: windowElement) as? String
    }

    /// The focused field's selection, raw: `kAXSelectedTextAttribute` on the focused element.
    /// `nil` when there is no focused element or the read answers an error; `""` when the copy
    /// succeeds with a collapsed (empty) selection.
    private func selectedText() -> String? {
        guard let element = focusedElement() else { return nil }
        return copyAttribute(kAXSelectedTextAttribute as CFString, on: element) as? String
    }

    // MARK: - The per-call timeout

    /// Run `body` on ``callQueue`` and wait up to ``callTimeout`` for its answer; `nil` when the
    /// budget is exhausted first.
    ///
    /// The only concurrency machinery in this file, and it exists for one reason: an AX call
    /// against an unresponsive application blocks for the system default, and the caller cannot
    /// wait that long. The call itself never runs on the caller's thread — which is how the
    /// "AX calls never run on the main thread" rule is satisfied — and the caller is never
    /// blocked longer than the budget. A timed-out answer is a failure answer (the upstream
    /// `nil`), and a call that timed out once may still complete later on the queue; the serial
    /// queue bounds that overlap to one straggler at a time, each bounded by the same budget.
    private func timedCall<T>(_ body: @escaping @Sendable () -> T?) -> T? {
        let box = TimedResultBox<T>()
        let semaphore = DispatchSemaphore(value: 0)
        callQueue.async {
            box.value = body()
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + Self.callTimeout) == .success else { return nil }
        return box.value
    }

    /// The transport for ``timedCall(_:)``: `@unchecked Sendable` because the semaphore's
    /// signal/wait pairing is what synchronises it — the happens-before the semaphore provides
    /// is real, but not something the compiler can see through a box.
    private final class TimedResultBox<T>: @unchecked Sendable {
        var value: T?
    }
}