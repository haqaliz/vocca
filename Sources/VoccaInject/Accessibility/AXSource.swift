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

/// **The AX adapter — the one file in `VoccaInject` permitted to speak Accessibility.**
///
/// The injection ladder's accessibility rung (`ARCHITECTURE.md:398-401`) must name
/// `AXUIElement` and the `kAX*` attributes to find the focused field, write into it and read it
/// back, and this file is the only one in the module that may: the H9-style seam lint (Phase D
/// of `plan_20260809.md`) will pin that — ``AccessibilityRungStrategy`` and
/// ``TargetResolution`` speak the two seams below, which this file implements. No typealias, no
/// laundering: if an identifier in the `AXUIElement`/`kAX`/`AXError` family appears in another
/// `VoccaInject` file, that file is the seam violation this one exists to confine.
///
/// Like the tap adapter, this file is **executed by nothing in CI**: `AXUIElement` calls need an
/// Accessibility grant and a real focused application, TCC cannot be granted on a hosted runner,
/// and no test can drive another application's focus. So every line below is translation with no
/// decisions in it — raw results only — and the decisions that would live here are made above
/// the seam, where they are tested:
///
/// | The question | Where it is answered |
/// |---|---|
/// | May this application be typed into through AX at all? | The allowlist gate, in ``AccessibilityRungStrategy`` (and the order) |
/// | Does an unverified "success" count as failure? | The ladder's decision (`ARCHITECTURE.md:400`) |
/// | What does "nothing focused" mean for the ladder? | ``TargetResolution`` (the `.noFocusedField` row) |
/// | What does a timeout mean? | A timeout *is* a failure, applied here at the API boundary — the policy that decides where the ladder goes from there is the decision's |
///
/// ## The three raw questions, and the one hop
///
/// ``FocusedAppReading/focusedApp()`` answers "which application is focused" (bundle ID +
/// window title, via the `kAXFocusedApplicationAttribute` → `kAXFocusedWindowAttribute` →
/// `kAXTitleAttribute` walk, with `AXUIElementGetPid` → `NSRunningApplication` for the bundle
/// identifier — the one place this file leaves AX for AppKit). ``AccessibilityInserting``'s
/// three methods answer "is there a focused element", "did the write land"
/// (`kAXSelectedTextAttribute`) and "what does the field hold now" (`kAXValueAttribute`).
///
/// ## Isolation and the per-call timeout
///
/// Every call runs on this file's dedicated serial queue, under a per-call timeout below the
/// system default — `AXUIElementCopyAttributeValue` against an unresponsive application blocks
/// for the system default (seconds), and that is the frozen-UI trap `ARCHITECTURE.md:323` warns
/// of. The caller (the rung or resolver actor) waits on a semaphore for at most ``callTimeout``;
/// a timed-out call answers as a failure. The class holds no mutable state, so `Sendable` is
/// checked, not asserted: sharing one instance across the rung and the resolver is safe because
/// the queue serializes every call.
final class AXSource: FocusedAppReading, AccessibilityInserting, Sendable {

    /// The per-call budget, below the system default: one answer per question, no matter how
    /// unresponsive the focused application is.
    private static let callTimeout: TimeInterval = 0.5

    /// The one queue every AX call in this file runs on. AX is not documented as thread-safe
    /// across simultaneous calls on one element, so a single serial queue is the safe shape —
    /// and it is a background queue, never the main thread, which is the point of the rule this
    /// file exists to satisfy.
    private let callQueue = DispatchQueue(label: "dev.vocca.ax-source", qos: .userInitiated)

    init() {}

    // MARK: - FocusedAppReading

    /// The focused application's identity, raw: its bundle identifier and its focused window's
    /// title. `nil` when the system answers "nothing focused".
    func focusedApp() async -> FocusedAppIdentity? {
        timedCall { () -> FocusedAppIdentity? in
            guard let appElement = self.copyElement(
                kAXFocusedApplicationAttribute as CFString, on: AXUIElementCreateSystemWide())
            else { return nil }
            return FocusedAppIdentity(
                bundleID: self.bundleIdentifier(of: appElement),
                windowTitle: self.focusedWindowTitle(of: appElement))
        }
    }

    // MARK: - AccessibilityInserting

    /// Whether a focused UI element could be resolved at all — the first raw answer, asked
    /// before anything is written.
    func resolveFocusedElement() async -> Bool {
        timedCall { () -> Bool in self.focusedElement() != nil } ?? false
    }

    /// Insert `text` into the focused field by setting its selected text. Raw: `true` when the
    /// system accepted the write. A timeout is `false` — the API's own guard, never a success.
    func insertSelectedText(_ text: String) async -> Bool {
        timedCall { () -> Bool in
            guard let element = self.focusedElement() else { return false }
            return AXUIElementSetAttributeValue(
                element, kAXSelectedTextAttribute as CFString, text as CFString) == AXError.success
        } ?? false
    }

    /// What the focused field contains now, raw; `nil` when it cannot be read (including a
    /// timeout).
    func readBackValue() async -> String? {
        timedCall { () -> String? in
            guard let element = self.focusedElement() else { return nil }
            return self.copyAttribute(kAXValueAttribute as CFString, on: element) as? String
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

    /// The focused UI element — the text field the write lands in — via the system-wide
    /// element's `kAXFocusedUIElementAttribute`.
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

    // MARK: - The per-call timeout

    /// Run `body` on ``callQueue`` and wait up to ``callTimeout`` for its answer; `nil` when the
    /// budget is exhausted first.
    ///
    /// The only concurrency machinery in this file, and it exists for one reason: an AX call
    /// against an unresponsive application blocks for the system default, and the ladder cannot
    /// wait that long. The call itself never runs on the caller's thread — which is how the
    /// "AX calls never run on the main thread" rule is satisfied for this file — and the caller
    /// is never blocked longer than the budget. A timed-out answer is a failure answer (the
    /// upstream `false`/`nil`), and a call that timed out once may still complete later on the
    /// queue; the serial queue bounds that overlap to one straggler at a time, each bounded by
    /// the same budget.
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
