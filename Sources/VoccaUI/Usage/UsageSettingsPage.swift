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

/// **The Usage tab** (`PRODUCT_SPEC.md` §7, the **Usage** entry) — a placeholder, deliberately.
///
/// `SettingsView`'s page switch is exhaustive with no `default`, so ``SettingsTab/usage`` needs a
/// page for the module to build. The tab's state, its reducer and every one of its strings landed
/// with this file (``UsageTabState``, ``UsageTabCopy``) and are driven by
/// `UsageTabReducerTests`/`UsageTabCopyTests`; the table, the summary and the Clear control are
/// the next unit of work, and are not written here on a guess.
///
/// It renders the not-yet-read line rather than nothing, so a user who selects the tab before the
/// real page exists is not handed a blank pane — and so this file makes no claim the ledger has
/// been read, which is the one thing a placeholder on this particular tab must not do.
///
/// Executed by nothing in CI (the window-server rule), as every page in this window is.
struct UsageSettingsPage: View {

    let bindings: SettingsBindings

    var body: some View {
        VStack {
            Spacer()
            Text(UsageTabCopy.loading)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
}
