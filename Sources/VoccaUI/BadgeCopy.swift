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

/// The egress badge's copy — pinned byte-for-byte to `PRODUCT_SPEC.md:250-264` (the
/// `EnginePickerCopyTests` rule): the ☁︎ glyph and the hover template are the product's own
/// wording, not a paraphrase. The badge is the privacy promise made visible — "This is the
/// difference between a tool that is private and a tool that says it is"
/// (`PRODUCT_SPEC.md:264`).
public enum BadgeCopy {

    /// The glyph the recording pill shows while a network provider is active
    /// (`PRODUCT_SPEC.md:256`): U+2601 CLOUD + U+FE0F VARIATION SELECTOR-16, byte-pinned in
    /// `BadgeCopyTests`.
    public static let egressGlyph = "☁︎"

    /// The hover copy stating plainly where the text goes (`PRODUCT_SPEC.md:261`): "Cleanup runs
    /// on <endpoint>. Your text is sent there." — the configured endpoint, never the key.
    public static func egressHoverText(endpoint: String) -> String {
        "Cleanup runs on \(endpoint). Your text is sent there."
    }

    // MARK: - The context badge (widget-indicator D5)

    /// The SF Symbol the context marker draws (`context-provider` M8): `eye`, distinct from the
    /// ☁︎ egress glyph at a glance — shape-carrying, the "shape carries the state" doctrine
    /// applied to the badge. Decided-new copy the spec does not write (O2), exact-equality
    /// pinned in `BadgeCopyTests`.
    public static let contextGlyphSymbolName = "eye"

    /// The context marker's hover copy — the egress hover's fact-then-consequence shape
    /// (`PRODUCT_SPEC.md:323`), naming what is being read (M8): "Vocca can read <app>. <app>
    /// allowed this." An empty or unresolved name renders the honest fallback — the badge is
    /// the message, the name is the detail (the dangling-arrow honesty rule,
    /// `WidgetCopy.swift:29-33`).
    public static func contextHoverText(appName: String?) -> String {
        guard let appName, !appName.isEmpty else {
            return "Vocca can read the focused app. It allowed this."
        }
        return "Vocca can read \(appName). \(appName) allowed this."
    }
}
