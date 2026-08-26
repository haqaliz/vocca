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

/// The one place a colour, a size or a duration is named — the design direction's token layer.
///
/// ## Why these are system colours rather than the design's hex values
///
/// The design specifies Apple's semantic palette with both appearances written out —
/// `#007aff` light, `#0a84ff` dark, and so on. Those are the *right* values, and they are exactly
/// what `NSColor.systemBlue` already resolves to. Naming the system colour instead of copying the
/// pair keeps the two from drifting when Apple retunes them, and picks up Increase Contrast and
/// the accent colour the user chose in System Settings, neither of which a literal can follow.
///
/// The design was authored on the web, where that machinery does not exist, so hardcoding was its
/// only option. On this side of the line it is a choice, and the wrong one.
///
/// Where a literal *is* used, it is because the surface floats over arbitrary wallpaper and must
/// carry its own legibility rather than inherit a window's — see ``Panel``.
public enum VoccaTheme {

    // MARK: - Semantic colour
    //
    // Roles, not hues. The panel asks for `recording`, never for "red", so a later decision to
    // retune a state changes one line here rather than every view that draws it.

    /// State colours, one per phase the user can be in.
    ///
    /// Kept distinct from ``egress`` on purpose, and that separation is load-bearing: the design's
    /// own rationale for the badge is that amber "is distinct from every state colour — blue is
    /// active, red is recording, green is done", so the badge can never read as a phase.
    public enum State {
        /// OPENING: the microphone is coming up. The system accent, so it matches the user's own.
        public static var opening: Color { Color(nsColor: .controlAccentColor) }
        /// RECORDING: live capture. Red is the universal recording convention.
        public static var recording: Color { Color(nsColor: .systemRed) }
        /// TRANSCRIBING: work in flight, deliberately quieter than either neighbour.
        public static var transcribing: Color { Color(nsColor: .secondaryLabelColor) }
        /// DELIVERED: the text landed.
        public static var delivered: Color { Color(nsColor: .systemGreen) }
    }

    /// The network badge's colour — amber, and **only** ever this.
    ///
    /// `PRODUCT_SPEC.md:250-264` makes the badge's presence mean "text is leaving this machine".
    /// It is not a state, not a warning, and not severity: it is a category of its own, which is
    /// why it does not live in ``State``.
    public static var egress: Color { Color(nsColor: .systemOrange) }

    /// Attention colours for surfaces that report a problem — the menu bar's blocked states and
    /// the failsafe's causes.
    public enum Attention {
        /// Something is blocked and the user must act: no Accessibility grant, no microphone.
        public static var blocking: Color { Color(nsColor: .systemRed) }
        /// Something is temporary and resolves itself: Secure Input, a download in progress.
        public static var transient: Color { Color(nsColor: .systemOrange) }
    }

    // MARK: - Type
    //
    // Sizes only. The face is the system's, because a Mac app that ships its own UI font looks
    // like a web app wearing a Mac's clothes — which is the one thing the brief forbids.

    /// The type scale, in points, matched to AppKit's own control sizes so a Vocca label sits at
    /// the same height as a system one beside it.
    public enum Text {
        /// The pill's own text: AppKit's small-control size.
        public static let panel = Font.system(size: 12)
        /// The pill's elapsed timer, monospaced so the digits do not jitter as they count.
        public static let panelTimer = Font.system(size: 12).monospacedDigit()
        /// A window's body text.
        public static let body = Font.system(size: 13)
        /// A settings group's header.
        public static let sectionHeader = Font.system(size: 11, weight: .semibold)
        /// A window's title.
        public static let title = Font.system(size: 15, weight: .semibold)
    }

    // MARK: - The floating panel's own metrics
    //
    // Grouped rather than scattered because they are one shape: change the height and the corner
    // radius must follow it, or the pill stops being a pill.

    /// The pill's geometry.
    public enum Panel {
        /// The pill's height. A capsule, so the radius is always half of it.
        public static let height: CGFloat = 30
        /// Always `height / 2` — a capsule by construction rather than by a number that has to be
        /// kept in step with one.
        public static var cornerRadius: CGFloat { height / 2 }
        /// The inset from the pill's edge to its content.
        public static let horizontalPadding: CGFloat = 12
        /// The gap between the pill's elements.
        public static let itemSpacing: CGFloat = 9

        /// The idle pill's opacity, and the fade it settles to.
        ///
        /// The design's numbers, and its reasoning with them: idle sits at 68% and drops to 28%
        /// after ten seconds, but **never to zero** — "the panel does not disappear, it is always
        /// findable". A widget that vanishes is indistinguishable from one that crashed, which is
        /// the failure this whole design pass exists to end.
        public static let idleOpacity: Double = 0.68
        /// The faded idle opacity, reached after ``idleFadeDelay``.
        public static let idleFadedOpacity: Double = 0.28
        /// How long idle waits before fading (`PRODUCT_SPEC.md:27`).
        public static let idleFadeDelay: Duration = .seconds(10)
    }
}
