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

/// **The quit policy — the "keep in tray" option's decision half** (`SettingsCopy.keepInTrayTitle`).
///
/// Vocca is an `LSUIElement` app that only shows a Dock icon while a focus-taking window
/// (Settings, onboarding) is up — which is exactly when a user might quit it "from the dock".
/// With keep-in-tray enabled, that quit must not end the process: the menu bar is where Vocca
/// lives, and the user's intent was to close the app, not to kill it.
///
/// The policy distinguishes the two kinds of quit **by who initiated it**:
///
/// - **Intentional** — the tray menu's own "Quit Vocca" and the onboarding flow's
///   [ Restart Vocca ] mark themselves before terminating (`markIntentionalQuit()`). These always
///   quit.
/// - **Everything else** — ⌘Q, the Dock's Quit, the system's shutdown sequence — consults
///   ``applicationShouldTerminate(_:)``. With keep-in-tray off, they quit exactly as before.
///   With it on, the termination is refused and the app returns to its menu-bar life
///   (`stayInTray` closes the settings window and drops the activation policy back to
///   `.accessory`, so the Dock icon goes away).
///
/// ## The work that must finish before the process ends
///
/// A quit is also the last chance to commit anything held in memory — today, the daily-use
/// ledger's unwritten counts (`usage-wiring/spec.md` §3). Committing is asynchronous, and
/// `.terminateNow` would end the process with the save still in flight, so a policy with
/// ``flushBeforeTerminating`` installed answers **`.terminateLater`** — AppKit's documented "I
/// will tell you when" — runs the work, and only then replies. Every quit that actually ends the
/// process passes through here, marked or not, so this one hook catches ⌘Q, the Dock's Quit, the
/// tray menu's and the onboarding restart's alike.
///
/// A **refused** quit runs none of it: the app is going back to the menu bar, not ending, and the
/// ordinary write cadence goes on running there. With nothing installed the answer is
/// `.terminateNow`, exactly as before — an app that defers with nothing to reply with never quits
/// at all.
///
/// The reply is a separate injected closure for one reason: a test that sent a real
/// `reply(toApplicationShouldTerminate: true)` on `NSApplication.shared` would be telling AppKit
/// a genuine termination could proceed, and the test host is what would end.
///
/// **The policy only marks; the caller terminates.** `markIntentionalQuit()` never terminates
/// itself — the tray menu's wiring and `AppRelaunch` call `NSApplication.terminate` after marking.
/// That keeps the policy testable headlessly (a policy that terminated from inside would kill the
/// test host), and it keeps the terminate call in the glue where the window-server rule already
/// puts it.
///
/// The flag is consumed by the refusal check and set only immediately before a terminate, so it
/// cannot leak across quits: a refused quit leaves it clear, and the next quit is refused again.
///
/// Executed by nothing in CI — `applicationShouldTerminate` needs a running `NSApplication` and
/// a user pressing ⌘Q — which is why the decision table lives here as pure closures and is
/// driven headlessly in `AppQuitPolicyTests`, and why the smoke checklist carries the real-quit
/// rows. `main()` installs the policy as `NSApplication.shared.delegate`.
@MainActor
public final class AppQuitPolicy: NSObject, NSApplicationDelegate {

    /// Whether the keep-in-tray option is currently enabled — asked at quit time, never cached,
    /// so a toggle flipped in Settings while the window is up is honoured by the next quit.
    private let keepInTray: () -> Bool

    /// What returning to the tray means: close the focus-taking window and drop the Dock icon.
    private let stayInTray: () -> Void

    /// Work that must finish before the process ends — the daily-use ledger's unwritten counts,
    /// committed. `nil` is the shipped default for a policy built without one, and answers
    /// `.terminateNow` exactly as before.
    private let flushBeforeTerminating: (@Sendable () async -> Void)?

    /// How the policy tells AppKit that a deferred termination may proceed. Injected so a test
    /// can watch the reply without a real `NSApplication` acting on it.
    private let replyWhenFinished: @MainActor (Bool) -> Void

    /// Set by an intentional quit immediately before terminating; consumed by the refusal check.
    private var intentionalQuit = false

    /// - Parameters:
    ///   - keepInTray: reads the persisted option.
    ///   - stayInTray: the refused quit's consequence — the `[weak root]` wiring closes the
    ///     settings window and sets the activation policy back to `.accessory`.
    ///   - flushBeforeTerminating: work that must finish before the process ends. Installing it
    ///     is what turns an accepted quit into a `.terminateLater`.
    ///   - replyWhenFinished: how the deferred termination is released. The default is AppKit's
    ///     own reply; see the type's doc comment for why it is injectable.
    public init(
        keepInTray: @escaping () -> Bool,
        stayInTray: @escaping () -> Void,
        flushBeforeTerminating: (@Sendable () async -> Void)? = nil,
        replyWhenFinished: @escaping @MainActor (Bool) -> Void = {
            NSApplication.shared.reply(toApplicationShouldTerminate: $0)
        }
    ) {
        self.keepInTray = keepInTray
        self.stayInTray = stayInTray
        self.flushBeforeTerminating = flushBeforeTerminating
        self.replyWhenFinished = replyWhenFinished
        super.init()
    }

    /// Marks the next termination as intentional — the tray menu's "Quit Vocca" and the onboarding
    /// flow's [ Restart Vocca ], both of which the caller then terminates itself. Whatever the
    /// keep-in-tray option, a marked quit is never refused.
    public func markIntentionalQuit() {
        intentionalQuit = true
    }

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard keepInTray() else { return accept() }
        guard !intentionalQuit else {
            intentionalQuit = false
            return accept()
        }
        stayInTray()
        return .terminateCancel
    }

    /// The accepted quit: immediate when there is nothing to finish, deferred when there is.
    ///
    /// The task runs on the main actor — the policy's own isolation — so the reply lands where
    /// AppKit expects it, and the work itself is whatever the composition installed.
    private func accept() -> NSApplication.TerminateReply {
        guard let flushBeforeTerminating else { return .terminateNow }
        Task { @MainActor in
            await flushBeforeTerminating()
            replyWhenFinished(true)
        }
        return .terminateLater
    }
}