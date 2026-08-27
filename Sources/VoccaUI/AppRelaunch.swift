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

/// **The relaunch adapter — quit and relaunch the same bundle** (`first-run-permissions` PRD M3):
/// the freshly-granted process must re-create its tap with a live mask, and a mask cleared at
/// creation cannot be re-enabled (`ARCHITECTURE.md:604`) — so `[Restart Vocca]` is a real
/// terminate + relaunch, never an in-process re-arm.
///
/// Translation only, the tap-adapter rule: no launch-argument replay (the fresh instance starts
/// clean, exactly like a user launching Vocca), no loop guard (the window glue guards
/// double-invocation), and nothing is decided here. Executed by nothing in CI — relaunching the
/// suite's own host process would be absurd, and the smoke checklist's grant → restart →
/// dictate row is its first execution (PRD M10, R2).
///
/// **Terminate first, then launch** — the plan's order (`plan_20260827.md` step 5): LaunchServices
/// will not launch a second instance of a bundle whose instance is still alive, so the old
/// instance must be gone before the new one arrives, or `openApplication` would only bring the
/// dying process forward and the restart would never happen.
@MainActor
public enum AppRelaunch {

    /// Quits the current instance and launches the same bundle fresh.
    public static func relaunch() {
        NSApp.terminate(nil)
        NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL, configuration: NSWorkspace.OpenConfiguration())
    }
}