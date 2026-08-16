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

/// One replacement in the user's dictionary: what a ``CleanupProvider`` rewrites and how.
///
/// **Order is the contract.** ``CleanupContext/dictionary`` is an ordered array and the type
/// carries no sorting — declared order is application order (`prd.md:180-181`,
/// `CAPABILITY_ROADMAP.md:124`): `["gonna" → "going to"]` before `["going to" → "go to"]` means
/// something different from the reverse, and neither the seam nor the provider may reorder or
/// deduplicate. A conformer observes the array exactly as given; the seam test asserts it
/// (`CleanupProviderSeamTests`).
///
/// ``caseSensitive`` and ``wordBoundary`` are independent flags: a rule may be case-sensitive
/// without a word boundary and vice versa.
///
/// `Codable` so the `user-dictionary` aspect can persist the dictionary without Core ever
/// touching JSON — the store's schema is decided there; here the guarantee is that a rule
/// round-trips all four fields.
public struct ReplacementRule: Sendable, Hashable, Codable {
    /// The phrase or word to rewrite, exactly as spoken (modulo ``caseSensitive``).
    public let source: String

    /// The text ``source`` becomes.
    public let replacement: String

    /// `true` ⇒ the match must respect case (`"Gonna"` is not `"gonna"`); `false` ⇒ case-blind.
    public let caseSensitive: Bool

    /// `true` ⇒ the match must sit on a word boundary (no replacement inside a longer word);
    /// `false` ⇒ substring matches apply.
    public let wordBoundary: Bool

    public init(source: String, replacement: String, caseSensitive: Bool, wordBoundary: Bool) {
        self.source = source
        self.replacement = replacement
        self.caseSensitive = caseSensitive
        self.wordBoundary = wordBoundary
    }
}
