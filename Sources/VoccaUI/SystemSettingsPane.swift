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

import AppKit

/// **The System Settings pane opener — the two frozen pane paths, in exactly the one place.**
///
/// Lifted out of `AppBootstrap.swift:441-446` by the `first-run-permissions` A2 aspect (PRD M1:
/// "the two pane paths already exist privately at `AppBootstrap.swift:441-446` — lift them into
/// the seam rather than duplicating"): the strings are **user-visible navigation targets**,
/// pinned byte-for-byte by `SystemSettingsPaneTests`, and the smoke rows check them.
///
/// The `MenuBarItem` precedent: AppKit glue in `VoccaUI`, executed by nothing in CI — opening a
/// pane is a window-server action a hosted runner cannot perform and must not fake. The open
/// call is translation only: the guard is the API's own (`URL(string:)` cannot fail for the two
/// frozen constants), and no decision lives here.
public enum SystemSettingsPane {

    /// The Accessibility pane — where the user must add Vocca themselves, because macOS will not
    /// prompt for this grant on an app's behalf (`ARCHITECTURE.md:603`; the PRD's M5c path).
    public static let accessibilityPanePath =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"

    /// The Microphone pane — the exact toggle the M2 denial screen names.
    public static let microphonePanePath =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"

    /// Opens `path` in System Settings. Translation only.
    @MainActor
    public static func open(at path: String) {
        guard let url = URL(string: path) else { return }
        NSWorkspace.shared.open(url)
    }
}