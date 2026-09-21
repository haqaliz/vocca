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

/// The Actions tab's strings, kept out of the views so they can be read without a window
/// server — the ``AppsTabCopy``/``BadgeCopy`` shape.
public enum ActionsTabCopy {

    /// The servers section's title.
    public static let serversSectionTitle = "Servers"

    /// The tools section's title — the section whose button spawns the child, and where the
    /// D2 copy must therefore live (the moment of spawn).
    public static let toolsSectionTitle = "Server tools"

    /// The empty state — honest about why it is empty.
    public static let emptyServers =
        "No servers configured yet. Add one to connect its tools."

    /// The add form's name field.
    public static let nameFieldLabel = "Name"

    /// The add form's path field.
    public static let pathFieldLabel = "Path"

    /// The add form's commit button.
    public static let addServerButton = "Add server"

    /// The row's edit button.
    public static let editServerButton = "Edit"

    /// The row's remove button.
    public static let removeServerButton = "Remove"

    /// The editor's commit button.
    public static let saveServerButton = "Save"

    /// The editor's way out, which leaves the server exactly as it was.
    public static let cancelButton = "Cancel"

    /// The discover button — the explicit, user-initiated spawn (`action-surface-wiring` D2).
    public static let discoverButton = "Discover tools"

    /// What the control says while the child is answering.
    public static let discoveringLabel = "Discovering…"

    /// The failed discovery's way forward.
    public static let tryAgainButton = "Try again"

    /// The empty tool list, after a discovery that answered.
    public static let noToolsFound = "This server offers no tools."

    /// **The default-off detail (M7)** — the row copy under the toggles: tools are off until
    /// the user enables them, and a disabled tool cannot be invoked.
    public static let defaultOffDetail =
        "Tools are off by default. Enable a tool before it can be invoked."

    /// The row's invoke button — shown only for enabled tools.
    public static let invokeButton = "Invoke"

    /// The row's preview button — the dry-run, shown only for enabled tools.
    public static let previewButton = "Preview"

    /// What the tools section says while an arm is awaiting the confirmation card.
    public static let awaitingConfirmation = "Waiting for your confirmation…"

    /// **The D2 copy, exact-in-spirit** (`actions-tab/spec.md`): configuring a server is trust
    /// extended to its author, not a guarantee we can make. Vocca's check watches its own
    /// process and cannot see inside a program Vocca starts on your behalf — the narrowed
    /// promise, in words, placed in the discover section so a user meets it at the moment of
    /// spawn.
    public static let d2TrustCopy =
        "Configuring a server is trust extended to its author, not a guarantee we can make."

    /// A failed discovery, with the bounded key the wiring reported.
    public static func discoveryFailed(_ key: String) -> String {
        "Couldn't discover tools: \(key)"
    }

    /// The preview row — the provider's own sentence.
    public static func previewSentence(_ sentence: String) -> String {
        "Preview: \(sentence)"
    }

    /// The claimed radius, in words a person can weigh. The row reports the claim; it never
    /// verifies it — the escalate-only policy is the gate's.
    public static func radiusLabel(_ radius: ActionsTabRadius) -> String {
        switch radius {
        case .readOnly: return "Read only"
        case .destructive: return "Destructive"
        case .outwardFacing: return "Outward facing"
        }
    }

    /// A failed write, surfaced — the `AppsSettingsPage` rule: a store that silently fails to
    /// save is one the user sets up again next launch.
    public static func saveError(_ message: String) -> String {
        "Couldn't save: \(message)"
    }
}