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

/// The Conversation tab's words — one file, so the page, the confirmation and the disclosure
/// can never drift out of agreement (the ``UsageTabCopy`` shape).
public enum ConversationTabCopy {

    /// Before the file has been read. Distinct from ``empty`` on purpose: a store that failed
    /// to load must never present itself as "no conversation" to a user who conversed an hour
    /// ago — the ``UsageTabCopy/loading`` guard, applied to the first turn-carrying surface.
    public static let loading = "Reading the conversation…"

    /// Read, and holding nothing — honest about *why* it is empty rather than reading like a
    /// fault: a fresh install has never conversed.
    public static let empty = "No conversation yet."

    /// The interrupted marker (S2) — the word a barge-in'd turn earns. Attached to the row the
    /// driver marked, never to a guess at which reply a barge-in cut.
    public static let interruptedMarker = "Interrupted"

    // MARK: - The Forget control

    /// The button. Names what goes, not what happens to a screen.
    public static let forgetButton = "Forget conversation"

    /// What it does, and the part that earns the confirmation: this deletes bytes rather than
    /// resetting something derived, so it is the **Speech** removal treatment and not the Apps
    /// reset one — the ``UsageTabCopy/clearExplanation`` argument, applied to the first file
    /// that holds what the user said.
    public static let forgetExplanation =
        "Deletes the file the conversation is kept in. It can't be undone."

    /// The confirmation's question. Asks about everything, because that is what goes.
    public static let forgetConfirmationTitle = "Forget the whole conversation?"

    /// The destructive choice.
    public static let forgetConfirmButton = "Forget it"

    /// The way out, phrased as the outcome rather than as "Cancel" — at a dialog a user reads
    /// two buttons and picks the one describing what they want to be true afterwards.
    public static let forgetCancelButton = "Keep it"

    // MARK: - What the page says about itself

    /// The disclosed window (`prd.md` R2, the D3 divergence made visible): the bound is said
    /// out loud so eviction is never a surprise. The number is decided copy here because
    /// `VoccaUI` may not name the store's constant (`ModuleBoundaryTests`) — the day the cap
    /// moves, this line and its pin move with it.
    public static let boundDisclosure =
        "Vocca keeps the last 50 turns; when the window is full, the oldest are dropped."

    /// The privacy line, in the ``UsageTabCopy/localOnly`` sentence's words — reused rather
    /// than re-invented, because it is the same claim: this tab is the first surface that shows
    /// what the user said, and the line that it never left the machine is the whole reason the
    /// window exists. `PRODUCT_SPEC.md` §12's *"No transcript history browser"* stands beside
    /// it — this is a bounded recent-turns window, never an archive.
    public static let localOnly =
        "All of this is read from a file on this Mac. None of it has ever left it."
}