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

/// The converse widget's shape and colour tokens (`dual-mode` widget-converse D3/D4): the tested
/// half of the first two cues in `PRODUCT_SPEC.md`'s five-cue table (`:193-194`).
///
/// **Shape** — "pill with a distinct notch" against dictate's rounded rectangle: `WidgetShape`
/// is the pure mapping from every `WidgetState` to one of the two shapes, and `NotchedPill` (the
/// SwiftUI `Shape`) is glue executed by nothing in CI. A drifted mapping — a converse state
/// drawing a capsule, or a dictate state drawing the notch — fails here, which is the whole
/// point of putting the mapping above the window server.
///
/// **Colour** — "clearly different hue (not a tint of the same one)" (`:194`): `conversing` is
/// purple, the system semantic hue furthest from the widget's other fills. It is the **third**
/// cue, not the first (`:203`): the notch and the `◈` label carry the mode signal independently,
/// so the purple/red distinction does not have to survive deuteranopia alone. What this suite
/// pins is the token-level claim — the colour differs from every other state colour and from
/// the egress badge's.
final class ConverseWidgetTokensTests: XCTestCase {

    /// The shape mapping is total over the closed `WidgetState` set: `.conversing` (both phases)
    /// draws the notched pill, every other state draws the capsule. A drifted mapping fails here.
    func testTheShapeMappingIsTotalOverTheWidgetStates() {
        let rows: [(WidgetState, WidgetShape, String)] = [
            (.idle, .capsule, "idle"),
            (.opening(targetAppName: "Slack"), .capsule, "opening"),
            (.recording, .capsule, "recording"),
            (.transcribing, .capsule, "transcribing"),
            (.delivered(targetAppName: "Slack"), .capsule, "delivered"),
            (.conversing(phase: .listening), .notchedPill, "conversing listening"),
            (.conversing(phase: .speaking), .notchedPill, "conversing speaking"),
        ]
        for (state, expected, name) in rows {
            XCTAssertEqual(
                WidgetShape.for(state), expected,
                "\(name) must draw the \(expected) — the mapping above the window server is the "
                    + "tested half of the shape cue")
        }
    }

    /// `WidgetShape` is closed over the two cases — the exhaustive switch below stops compiling
    /// if a third shape appears without a row in the mapping.
    func testWidgetShapeIsClosedOverTheTwoCases() {
        func name(_ shape: WidgetShape) -> String {
            switch shape {
            case .capsule: return "capsule"
            case .notchedPill: return "notchedPill"
            }
        }
        XCTAssertEqual(name(.capsule), "capsule")
        XCTAssertEqual(name(.notchedPill), "notchedPill")
        XCTAssertNotEqual(name(.capsule), name(.notchedPill))
    }

    /// The notch's metrics exist and are positive — a zero-depth notch is no notch at all, and
    /// these two named tokens are the one place the geometry lives (`DesignTokens.swift:17-31`).
    func testTheNotchMetricsArePositiveAndNamed() {
        XCTAssertGreaterThan(VoccaTheme.Panel.converseNotchDepth, 0)
        XCTAssertGreaterThan(VoccaTheme.Panel.converseNotchWidth, 0)
    }

    /// The token-level reading of `:194`'s "clearly different hue (not a tint of the same one)":
    /// the converse colour differs from every other state colour and from the egress badge's —
    /// purple is the system hue furthest from the widget's blue/red/green/orange fills.
    func testTheConverseColourIsADistinctHueNotATint() {
        XCTAssertNotEqual(VoccaTheme.State.conversing, VoccaTheme.State.opening)
        XCTAssertNotEqual(VoccaTheme.State.conversing, VoccaTheme.State.recording)
        XCTAssertNotEqual(VoccaTheme.State.conversing, VoccaTheme.State.transcribing)
        XCTAssertNotEqual(VoccaTheme.State.conversing, VoccaTheme.State.delivered)
        XCTAssertNotEqual(VoccaTheme.State.conversing, VoccaTheme.egress)
    }
}