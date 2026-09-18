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

/// The AND-gate (`byok-context-grant` D2/D4): the pure decision that a snapshot may travel with
/// a cloud cleanup request — per-app consent **and** the separate, off-by-default global grant,
/// never either alone (`prd.md:102-107`).
///
/// ## The caller-side doctrine
///
/// The gate is the caller's decision, never the provider's (`CleanupProvider.swift:39-41`: the
/// caller owns context decisions, a conformer must not reinterpret them). It is the pure,
/// headless-tested half that `bootstrap-wiring`'s composed ``GrantedContextSource`` applies to a
/// ``ContextProvider`` snapshot before the source answers: a gate that ever returned a snapshot
/// without both gates would be the privacy incident the roadmap names
/// (`CAPABILITY_ROADMAP.md:353-355` — context never appears in a request payload without the
/// separate explicit grant).
///
/// ## The ≤ 4 KB bound
///
/// The bound lives here — in exactly one place — because the snapshot must already be bounded
/// when it reaches the wire: `selectedText` is truncated to the largest UTF-8 prefix ≤
/// ``maxSelectedTextBytes`` **bytes** (a character count would overflow the bound on multibyte
/// text), and the truncation never splits a scalar — the result is always a valid UTF-8 prefix.
/// Stdlib-only, like the vocabulary it guards: this module imports nothing.
public enum ContextGrantGate {

    /// The bound on `selectedText`, in **UTF-8 bytes** (`prd.md:192-195`, Open Q1).
    public static let maxSelectedTextBytes = 4096

    /// The granted snapshot, or `nil` when the AND-gate does not hold.
    ///
    /// - Parameters:
    ///   - snapshot: the turn's snapshot, or `nil` when nothing resolved — nothing resolved is
    ///     nothing granted, even with both gates on.
    ///   - consentActive: whether per-app consent held at the snapshot's moment.
    ///   - grantEnabled: whether the separate global grant is on.
    /// - Returns: `snapshot` with `selectedText` bounded to ≤ ``maxSelectedTextBytes`` UTF-8
    ///   bytes when both gates held and a snapshot exists; `nil` otherwise.
    public static func granted(
        snapshot: ContextSnapshot?,
        consentActive: Bool,
        grantEnabled: Bool
    ) -> ContextSnapshot? {
        guard consentActive, grantEnabled, let snapshot else { return nil }
        guard
            let text = snapshot.selectedText,
            text.utf8.count > maxSelectedTextBytes
        else {
            return snapshot
        }
        return ContextSnapshot(
            bundleID: snapshot.bundleID,
            windowTitle: snapshot.windowTitle,
            selectedText: boundedPrefix(of: text))
    }

    /// The largest UTF-8 prefix of `text` with at most ``maxSelectedTextBytes`` bytes, built one
    /// scalar at a time so the boundary never falls inside a scalar.
    private static func boundedPrefix(of text: String) -> String {
        var bytes = 0
        var prefix = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            let width = String(scalar).utf8.count
            guard bytes + width <= maxSelectedTextBytes else { break }
            bytes += width
            prefix.append(scalar)
        }
        return String(prefix)
    }
}