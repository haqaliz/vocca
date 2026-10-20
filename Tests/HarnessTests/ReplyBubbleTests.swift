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

import VoccaCore
import VoccaUI
import XCTest

/// **The reply bubble's contract** (`reply-text-rendering` R4/R5, the reply-view aspect's
/// acceptances 1-5): the CONVERSING surface renders the pill plus, when a reply is scheduled,
/// the bubble beneath it. The view itself is window-server glue executed by nothing in CI (the
/// `WidgetView`/`FailsafeView` precedent), so the decision and every string live above it in
/// `WidgetCopy` and the whole contract runs headlessly here.
///
/// Acceptance 1 carries a source pin as well as the predicate rows: a predicate no view calls is
/// a claim, not a render, so the view's own source is read for the pinned decision and label (the
/// `AppBootstrapWiringTests` call-site extraction shape).
final class ReplyBubbleTests: XCTestCase {

    // MARK: - Acceptance 1: the bubble decision

    /// The bubble shows exactly when there is a reply with something to say: a non-nil,
    /// non-empty text. `nil` — no reply scheduled, or the carrier's lifecycle clear — shows
    /// nothing, and an empty reply is silence, the generator's own contract
    /// (`ReplyGenerator.reply(to:)`), so an empty box is never drawn (the `openingLabel`
    /// doctrine: an absent thing renders nothing).
    func testTheBubbleShowsExactlyWhenThereIsANonEmptyReply() {
        XCTAssertTrue(
            WidgetCopy.shouldShowReplyBubble("Done."), "a scheduled reply shows the bubble")
        XCTAssertTrue(WidgetCopy.shouldShowReplyBubble("I cleared the audit log."))
        XCTAssertFalse(WidgetCopy.shouldShowReplyBubble(nil), "no reply text, no bubble")
        XCTAssertFalse(
            WidgetCopy.shouldShowReplyBubble(""),
            "an empty reply is silence — the generator's own contract; never an empty box")
    }

    /// The decision is the view's, not a parallel copy: `WidgetView` reads the pinned predicate
    /// and the pinned label. A source pin because the view is executed by nothing in CI — the
    /// reducer's converse-only rule can hold the text, and this is what proves the render reads
    /// it.
    func testTheConversingViewReadsThePinnedDecisionAndLabel() throws {
        let source = try String(
            contentsOf: PackageRootLocator.find(from: #filePath)
                .appendingPathComponent("Sources/VoccaUI/WidgetView.swift"),
            encoding: .utf8)
        let stripped = SwiftSourceScanner.stripComments(from: source)
        XCTAssertTrue(
            stripped.contains("shouldShowReplyBubble("),
            "the view must ask WidgetCopy whether to show the bubble — a predicate no view "
                + "calls renders nothing")
        XCTAssertTrue(
            stripped.contains("replyBubbleLabel("),
            "the bubble's accessibility label must be the pinned WidgetCopy string — the label "
                + "doctrine (R5)")
    }

    // MARK: - Acceptance 2: the text is verbatim

    /// The bubble carries the reply text byte-for-byte: no prefix, no suffix, no trimming, no
    /// paraphrase — the sentence doctrine. Newlines, padding and Unicode all survive; the wrap
    /// is the view's and changes no character.
    func testTheBubbleCarriesTheReplyTextVerbatim() {
        let text = "Done. Two lines:\n  • first\n  • second — «quoted», 🎙"
        XCTAssertEqual(WidgetCopy.replyBubbleLabel(text), text)
        XCTAssertEqual(
            WidgetCopy.replyBubbleLabel("  padded  "), "  padded  ",
            "leading and trailing whitespace are characters of the reply — never trimmed")
        XCTAssertEqual(WidgetCopy.replyBubbleLabel(""), "")
        let capped = String(repeating: "x", count: WidgetTiming.maxReplyCharacters)
        XCTAssertEqual(
            WidgetCopy.replyBubbleLabel(capped), capped,
            "the reducer's bounded text reaches the bubble unchanged")
    }

    // MARK: - Acceptance 3: the copy pins

    /// The bubble's copy surface, pinned by exact equality — the predicate's rows and the
    /// label's identity are the whole of it, and a re-decision or a reword fails here (the
    /// `WidgetCopyTests` shape). The shipped replies (`EchoReplyGenerator`'s echo,
    /// `AcknowledgmentReplyGenerator`'s fixed copy) pass through unchanged.
    func testTheBubbleCopyIsPinnedExact() {
        XCTAssertEqual(WidgetCopy.replyBubbleLabel("Done."), "Done.")
        XCTAssertEqual(WidgetCopy.replyBubbleLabel("Vocca is listening."), "Vocca is listening.")
        XCTAssertTrue(WidgetCopy.shouldShowReplyBubble("Done."))
        XCTAssertFalse(WidgetCopy.shouldShowReplyBubble(nil))
    }

    // MARK: - Acceptance 4: never a target

    /// **The never-a-target render pin stays green** (`PRODUCT_SPEC.md:200`): no converse or
    /// reply-bubble renderer in `WidgetCopy` accepts a `targetAppName` — the bubble is part of
    /// the converse surface, and the absence of `→ AppName` is itself the mode signal. Scanned
    /// over the file's own source (the `WidgetCopyTests` shape), comments stripped; the
    /// non-vacuity rows prove both families were actually found.
    func testNoConverseOrReplyBubbleRendererAcceptsATargetAppName() throws {
        let source = try String(
            contentsOf: PackageRootLocator.find(from: #filePath)
                .appendingPathComponent("Sources/VoccaUI/WidgetCopy.swift"),
            encoding: .utf8)
        let stripped = SwiftSourceScanner.stripComments(from: source)
        let renderers = stripped.split(separator: "\n").map(String.init).filter {
            let line = $0.trimmingCharacters(in: .whitespaces)
            return line.hasPrefix("public static func")
                && (line.contains("converse") || line.contains("ReplyBubble"))
        }
        XCTAssertTrue(
            renderers.contains { $0.contains("converse") },
            "the scan must find the converse renderers — a rename of the prefix would make "
                + "this vacuous")
        XCTAssertTrue(
            renderers.contains { $0.contains("ReplyBubble") },
            "the scan must find the reply-bubble renderers — a rename would make this vacuous")
        for line in renderers {
            XCTAssertFalse(
                line.contains("targetAppName"),
                "\(line.trimmingCharacters(in: .whitespaces)) — a converse or reply-bubble "
                    + "renderer must never accept a target app name (PRODUCT_SPEC.md:200)")
        }
    }

    // MARK: - Acceptance 5: the pill's five cues

    /// **The pill's five-cue inputs are unchanged** (`PRODUCT_SPEC.md:190-196`): the bubble is
    /// addition-only (Q2), so the shape, hue, `◈` label and notch metrics the pill renders are
    /// the same inputs the token suites pin — `ConverseWidgetTokensTests` stays green
    /// untouched. This row is the cross-check that the bubble's aspect touched none of them.
    func testThePillsFiveCueInputsAreUnchanged() {
        XCTAssertEqual(WidgetShape.for(.conversing(phase: .listening)), .notchedPill)
        XCTAssertEqual(WidgetShape.for(.conversing(phase: .speaking)), .notchedPill)
        XCTAssertEqual(WidgetCopy.converseLabel(.listening), "◈ listening…")
        XCTAssertEqual(WidgetCopy.converseLabel(.speaking), "◈ speaking…")
        XCTAssertEqual(WidgetCopy.conversePersistentLabel, "◈ Vocca")
        XCTAssertNotEqual(VoccaTheme.State.conversing, VoccaTheme.State.recording)
        XCTAssertNotEqual(VoccaTheme.State.conversing, VoccaTheme.egress)
        XCTAssertGreaterThan(VoccaTheme.Panel.converseNotchDepth, 0)
        XCTAssertGreaterThan(VoccaTheme.Panel.converseNotchWidth, 0)
    }

    // MARK: - Acceptance 6: the copy affordance (N1, issue #64)

    /// The copy control's strings are pinned by exact equality: one affordance, and a VoiceOver
    /// label that carries the reply so the control announces what it will copy. The reply text
    /// is verbatim in the label, the same sentence doctrine as the bubble itself.
    func testTheCopyAffordanceCopyIsPinned() {
        XCTAssertEqual(WidgetCopy.replyCopyAffordance, "Copy")
        XCTAssertEqual(WidgetCopy.replyCopyLabel("Done."), "Copy reply: Done.")
        XCTAssertEqual(
            WidgetCopy.replyCopyLabel("  padded  "), "Copy reply:   padded  ",
            "the label carries the reply byte-for-byte — never trimmed")
    }

    /// The view renders the pinned control and hands the reply text to the injected closure. A
    /// source pin because the view is window-server glue executed by nothing in CI, and the
    /// affordance the issue names is a render, not a predicate.
    func testTheViewWiresThePinnedCopyAffordance() throws {
        let source = try String(
            contentsOf: PackageRootLocator.find(from: #filePath)
                .appendingPathComponent("Sources/VoccaUI/WidgetView.swift"),
            encoding: .utf8)
        let stripped = SwiftSourceScanner.stripComments(from: source)
        XCTAssertTrue(
            stripped.contains("replyCopyAffordance"),
            "the bubble must render the pinned copy affordance")
        XCTAssertTrue(
            stripped.contains("onCopyReply("),
            "the control must hand the reply text to the injected copy closure")
        XCTAssertTrue(
            stripped.contains("replyCopyLabel("),
            "the control's accessibility label must be the pinned WidgetCopy string")
    }

    /// **The first click must land while Vocca is inactive.** A button in a non-active app's
    /// window only receives the click when the view accepts the first mouse; and the panel must
    /// still never become key. Both halves are window-server glue, pinned in source (`canBecomeKey`
    /// is also asserted at runtime by `WidgetPanelBindingTests`).
    func testThePanelAcceptsTheFirstMouseWithoutBecomingKey() throws {
        let source = try String(
            contentsOf: PackageRootLocator.find(from: #filePath)
                .appendingPathComponent("Sources/VoccaUI/WidgetPanel.swift"),
            encoding: .utf8)
        let stripped = SwiftSourceScanner.stripComments(from: source)
        XCTAssertTrue(
            stripped.contains("acceptsFirstMouse"),
            "the copy control would need a focus click before it fires — the panel must accept "
                + "the first mouse")
        XCTAssertTrue(
            stripped.contains("canBecomeKey"),
            "the panel's never-key override is the other half of the no-focus rule")
    }

    /// The write is the composition root's, not `VoccaUI`'s: the root's one `LiveWidget`
    /// construction passes the copy closure, and that closure reaches `ShippingPasteboard.write`.
    /// A source pin because `AppBootstrap.configure` needs an `NSApplication` and a run loop.
    func testTheRootWiresTheCopyToThePasteboard() throws {
        let source = try String(
            contentsOf: PackageRootLocator.find(from: #filePath)
                .appendingPathComponent("Sources/VoccaBootstrap/AppBootstrap.swift"),
            encoding: .utf8)
        let stripped = SwiftSourceScanner.stripComments(from: source)
        XCTAssertTrue(
            stripped.contains("onCopyReply:"),
            "the root must pass a copy closure at the LiveWidget construction")
        XCTAssertTrue(
            stripped.contains("ShippingPasteboard.write"),
            "the copy closure must write through the shipped pasteboard adapter")
    }
}
