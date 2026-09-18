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
import VoccaContext
import XCTest

/// The `accessibility-context` aspect's **real** resolution run (R3, S1's env-gated half): the
/// real ``AccessibilityContext`` over the matrix apps actually present on the machine, driving
/// focus from app to app and resolving each time.
///
/// **The real run is executed by nothing in CI** (O4, the tap-adapter precedent): the suite is
/// env-gated on `VOCCA_CONTEXT_REAL` — CI runs the skip path, the visible skip names the
/// variable and still counts as executed, which is what the floor's arithmetic assumes. With the
/// variable set, the suite activates each matrix app that is running, resolves through the real
/// adapter, and records `CONTEXT-RESOLUTION <correct>/<attempted> recorded-never-gated`.
///
/// The number is **never gated** (R3): real-app resolution is environment by nature, so no
/// percentage may be quoted from CI, and a CI assertion on a real-focus number would be a drift,
/// not an improvement. The CI-measurable contract — the ≥95% bar over the scripted corpus — is
/// `ContextResolutionHarnessTests`'.
final class AccessibilityContextRealSuiteTests: XCTestCase {

    /// The matrix's 22 rows, bundle IDs only — the same rows the scripted corpus is seeded from,
    /// so the real run and the CI harness measure the same shape.
    private static let matrixBundleIDs: [(app: String, bundleID: String)] = [
        ("Notes", "com.apple.Notes"),
        ("Mail", "com.apple.mail"),
        ("TextEdit", "com.apple.TextEdit"),
        ("Xcode", "com.apple.dt.Xcode"),
        ("Messages", "com.apple.MobileSMS"),
        ("Telegram", "ru.keepcoder.Telegram"),
        ("VSCode", "com.microsoft.VSCode"),
        ("Teams", "com.microsoft.teams2"),
        ("Discord", "com.hnc.Discord"),
        ("ChatGPT", "com.openai.codex"),
        ("Obsidian", "md.obsidian"),
        ("Safari", "com.apple.Safari"),
        ("Chrome", "com.google.Chrome"),
        ("GoogleDocs", "com.google.Chrome"),
        ("Firefox", "org.mozilla.firefox"),
        ("Terminal", "com.apple.Terminal"),
        ("Warp", "dev.warp.Warp-Stable"),
        ("Ghostty", "com.mitchellh.ghostty"),
        ("IntelliJ", "com.jetbrains.intellij"),
        ("Zed", "dev.zed.Zed"),
        ("Passwords", "com.apple.Passwords"),
        ("PasswordField", "com.apple.Safari"),
    ]

    /// The real resolution run — env-gated, recorded never gated.
    func testRealContextResolutionAcrossTheMatrixApps() throws {
        guard ProcessInfo.processInfo.environment["VOCCA_CONTEXT_REAL"] != nil else {
            throw XCTSkip(
                "set VOCCA_CONTEXT_REAL=1 to run the real context-resolution suite — CI has no "
                    + "focus to drive and no Accessibility grant")
        }

        let context = AccessibilityContext(
            axRead: AXContextSource(),
            secureInputRead: ContextSecureInputRead())

        var attempted = 0
        var correct = 0
        var misses: [String] = []
        for row in Self.matrixBundleIDs {
            guard
                let app = NSRunningApplication.runningApplications(
                    withBundleIdentifier: row.bundleID).first
            else {
                continue  // not present on this machine — not an attempted row
            }
            app.activate()
            Thread.sleep(forTimeInterval: 0.5)  // let focus and AX settle before the read
            let snapshot = context.resolveCurrent()
            attempted += 1
            if snapshot.bundleID == row.bundleID {
                correct += 1
            } else {
                misses.append("\(row.app): resolved \(snapshot.bundleID ?? "nil")")
            }
        }

        print(
            "CONTEXT-RESOLUTION \(correct)/\(attempted) recorded-never-gated"
                + (misses.isEmpty ? "" : " misses: \(misses.joined(separator: "; "))"))
    }
}