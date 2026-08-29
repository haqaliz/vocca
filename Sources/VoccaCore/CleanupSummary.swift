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

/// **What the Cleanup tab says Vocca is actually using** — derived from the resolved provider,
/// never from the file and never from a literal.
///
/// `AppBootstrap.showSettings()` used to pass `("Built-in rules", nil)`: a constant, so a user on
/// Ollama or BYOK read "Built-in rules" with no endpoint while the widget's egress badge correctly
/// showed the cloud marker. `SettingsView` calls the tab's egress line *"the point of this tab …
/// where they can check before it ever does"*, and with a literal behind it that line could never
/// appear. This is the type that made it appear.
///
/// ## Two facts, not one
///
/// ``sendsTextOffTheMac`` and ``endpoint`` answer different questions — *does text leave* and
/// *where does it go* — and the first is the one the privacy promise is made of. A surface that
/// inferred it from the second would fall silent, rendering the reassuring local line, in exactly
/// the case where a network provider could not name its destination. So the flag is carried, and
/// ``resolved(identity:requiresNetwork:endpoint:)`` is the only thing that sets it.
///
/// ## Why the endpoint is gated on the declaration
///
/// ``CleanupProvider/requiresNetwork`` is the seam's own egress declaration
/// (`CleanupProvider.swift:51`); the endpoint is bookkeeping the resolver keeps beside it. A
/// resolve that degraded a bad LLM block to the rules provider can leave an endpoint string in
/// hand, and rendering a cloud line over a provider that never dials would be the egress badge's
/// failure in reverse — a warning about traffic that does not exist teaches a user to ignore the
/// one that does. The declaration decides; the string only names.
public struct CleanupSummary: Sendable, Equatable {

    /// The resolved provider's human name — ``ProviderIdentity/displayName``.
    public let name: String

    /// Whether the resolved provider sends text off the device, as the provider itself declares.
    public let sendsTextOffTheMac: Bool

    /// Where the text goes, when there is a destination to name. `nil` for a local provider,
    /// always — and `nil` for a network provider whose endpoint the resolver could not name, which
    /// ``sendsTextOffTheMac`` still reports as egress.
    public let endpoint: String?

    /// The summary of a provider that has been resolved.
    ///
    /// The one constructor with the gating rule in it, so no caller can assemble a summary that
    /// shows an endpoint for a provider that does not dial.
    public static func resolved(
        identity: ProviderIdentity,
        requiresNetwork: Bool,
        endpoint: String?
    ) -> CleanupSummary {
        CleanupSummary(
            name: identity.displayName,
            sendsTextOffTheMac: requiresNetwork,
            endpoint: requiresNetwork ? endpoint : nil)
    }

    public init(name: String, sendsTextOffTheMac: Bool, endpoint: String?) {
        self.name = name
        self.sendsTextOffTheMac = sendsTextOffTheMac
        self.endpoint = endpoint
    }
}
