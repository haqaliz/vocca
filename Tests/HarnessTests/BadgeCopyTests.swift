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
import VoccaUI
import XCTest

/// The egress badge's copy — pinned byte-for-byte to `PRODUCT_SPEC.md:250-264`, the
/// `EnginePickerCopyTests` rule (`spec.md:34-35`): the ☁︎ glyph and the hover template are the
/// product's own wording, not a paraphrase. If the spec's wording changes, this test fails until
/// the copy changes with it.
final class BadgeCopyTests: XCTestCase {

    /// **B4 — the glyph is the cloud with the variation selector** (U+2601 CLOUD + U+FE0F
    /// VARIATION SELECTOR-16), exactly as the spec's recording-pill mock places it after the
    /// elapsed timer (`PRODUCT_SPEC.md:256`).
    func testTheEgressGlyphMatchesTheSpec() {
        XCTAssertEqual(BadgeCopy.egressGlyph, "☁︎")
    }

    /// **B4 — the hover template matches the spec byte-for-byte** with the endpoint
    /// interpolated (`PRODUCT_SPEC.md:261`: "Cleanup runs on api.example.com. Your text is sent
    /// there.") — the marker states plainly where the text goes, never the key.
    func testTheHoverTemplateMatchesTheSpecByteForByte() {
        XCTAssertEqual(
            BadgeCopy.egressHoverText(endpoint: "api.example.com"),
            "Cleanup runs on api.example.com. Your text is sent there.")
    }

    /// **B4 — the interpolated endpoint is the configured one.** The Ollama default and a BYOK
    /// endpoint both surface verbatim, so the user sees exactly where the text is sent.
    func testTheHoverInterpolatesTheConfiguredEndpoint() {
        XCTAssertTrue(
            BadgeCopy.egressHoverText(endpoint: "http://localhost:11434")
                .contains("http://localhost:11434"))
        XCTAssertTrue(
            BadgeCopy.egressHoverText(endpoint: "https://api.example.com/v1")
                .contains("https://api.example.com/v1"))
    }
}
