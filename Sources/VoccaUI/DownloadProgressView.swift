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
import SwiftUI
import VoccaCore

/// The minimal first-run download surface (PRD M15): a small window with a progress bar, an
/// honest status line, and a Skip button — the first real `VoccaUI` code.
///
/// The window is **thin glue, executed by nothing in CI** (a real window needs a window server
/// session): every decision it could contain lives in ``DownloadStateReducer`` and is tested
/// headlessly. The view observes the session's events, reduces them to a ``DownloadState``,
/// and renders that — nothing else.
///
/// Skip semantics: Skip calls ``ModelDownloadSession/cancel()``; the partial download survives
/// for the next attempt, and the engine answers `modelUnavailable` with an honest reason until
/// then.
public final class DownloadWindow: NSWindow {

    /// Presents the download window for a session and starts the download.
    public static func present(session: any ModelDownloadSession, title: String) -> DownloadWindow {
        let view = DownloadProgressView(session: session)
        let hosting = NSHostingView(rootView: view)
        let window = DownloadWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 120),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = title
        window.contentView = hosting
        window.center()
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        Task { await session.start() }
        return window
    }
}

/// The SwiftUI content: a progress bar, a status line, and Skip — all derived from the
/// reducer over the session's events.
public struct DownloadProgressView: View {

    private let session: any ModelDownloadSession
    @State private var state: DownloadState = .idle

    public init(session: any ModelDownloadSession) {
        self.session = session
    }

    /// Consumes the session's events, reducing them onto ``state``. Runs until the stream
    /// terminates (after `.committed`, `.failed` or `.cancelled`).
    public func begin() async {
        for await event in session.events {
            state = DownloadStateReducer.reduce(state, event: event)
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Downloading the speech model")
                .font(.headline)
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
            ProgressView(value: progressFraction)
                .disabled(state == .committed)
            HStack {
                Spacer()
                if canSkip {
                    Button("Skip") {
                        session.cancel()
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private var progressFraction: Double {
        if case .downloading(let fraction) = state { return fraction }
        return state == .committed ? 1 : 0
    }

    private var canSkip: Bool {
        switch state {
        case .idle, .downloading: return true
        case .committed, .failed, .skipped: return false
        }
    }

    private var statusText: String {
        switch state {
        case .idle:
            return "Preparing…"
        case .downloading(let fraction):
            return "\(Int(fraction * 100))% — your audio never leaves this Mac"
        case .committed:
            return "Done. Ready to dictate."
        case .failed(let reason):
            return "The download failed: \(reason). Try again later."
        case .skipped:
            return "Skipped. Dictation will be unavailable until the model is downloaded."
        }
    }
}
