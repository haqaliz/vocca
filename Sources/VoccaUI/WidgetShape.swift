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

import SwiftUI

/// The converse pill's shape (`dual-mode` D3): the capsule with a small triangular notch cut
/// into the leading edge — `PRODUCT_SPEC.md:193`'s "pill with a distinct notch", which is what
/// distinguishes the mode from dictate's rounded rectangle at a glance.
///
/// **Glue, executed by nothing in CI** (the window-server precedent, exactly like ``WidgetView``):
/// the mapping that decides *when* this shape draws is ``WidgetShape`` above it, tested
/// headlessly in `ConverseWidgetTokensTests`; what is here is only the path the notch takes, read
/// from the token metrics (``VoccaTheme/Panel/converseNotchDepth`` and
/// ``VoccaTheme/Panel/converseNotchWidth``) so the geometry lives in exactly one place each.
///
/// The notch is cut into the leading edge (the left edge in LTR) with its apex pointing inward —
/// a notch, not a bite: small, quiet, and legible at the pill's 30-point height. Shape carries
/// the mode signal for color-vision deficiencies (`:203`), which is why it exists at all.
public struct NotchedPill: InsettableShape {

    /// The inset the hairline outline applies — the standard `InsettableShape` pattern
    /// (`Capsule`'s): `strokeBorder` insets the path by half the line width so the hairline sits
    /// inside the pill's edge.
    private var insetAmount: CGFloat = 0

    public init() {}

    public func inset(by amount: CGFloat) -> some InsettableShape {
        var shape = self
        shape.insetAmount += amount
        return shape
    }

    public func path(in rect: CGRect) -> Path {
        let rect = rect.insetBy(dx: insetAmount, dy: insetAmount)
        let radius = min(VoccaTheme.Panel.cornerRadius, rect.height / 2)
        let depth = VoccaTheme.Panel.converseNotchDepth
        let notchWidth = VoccaTheme.Panel.converseNotchWidth
        let notchTop = (rect.height - notchWidth) / 2
        let notchApexY = rect.height / 2

        var path = Path()
        path.move(to: CGPoint(x: radius, y: 0))
        path.addQuadCurve(
            to: CGPoint(x: 0, y: radius),
            control: CGPoint(x: 0, y: 0))
        // The leading edge, with the notch: up to the notch's top, in to the apex, back out.
        path.addLine(to: CGPoint(x: 0, y: notchTop))
        path.addLine(to: CGPoint(x: depth, y: notchApexY))
        path.addLine(to: CGPoint(x: 0, y: notchTop + notchWidth))
        path.addLine(to: CGPoint(x: 0, y: rect.height - radius))
        path.addQuadCurve(
            to: CGPoint(x: radius, y: rect.height),
            control: CGPoint(x: 0, y: rect.height))
        path.addLine(to: CGPoint(x: rect.width - radius, y: rect.height))
        path.addQuadCurve(
            to: CGPoint(x: rect.width, y: rect.height - radius),
            control: CGPoint(x: rect.width, y: rect.height))
        path.addLine(to: CGPoint(x: rect.width, y: radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.width - radius, y: 0),
            control: CGPoint(x: rect.width, y: 0))
        path.closeSubpath()
        return path
    }
}