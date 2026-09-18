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

/// The shipped default ``ContextProvider``: **reads nothing** and resolves to the all-absent
/// snapshot — every field `nil`, never `""`.
///
/// ## The honesty posture
///
/// The default answers "there is no context to report" for every call. It claims nothing it
/// did not read: deterministic by construction (the constant function — no hidden state, no
/// environment), stdlib-only (this module imports nothing, so no AX name can even compile
/// here), and zero-network. It is the honest shipped default until `accessibility-context`'s
/// consent gate is on (`prd.md:72-75`) and its `AccessibilityContext` takes the slot behind
/// the same seam (`ContextProvider`) — this type stays in the tree as the fallback.
public struct NullContext: ContextProvider {

    public init() {}

    /// The all-absent snapshot — nothing focused, no title, no selection.
    public func resolveCurrent() -> ContextSnapshot {
        ContextSnapshot(bundleID: nil, windowTitle: nil, selectedText: nil)
    }
}