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

import AVFoundation
import Foundation
import VoccaCore

/// The widget's sound vocabulary (`dual-mode` D6) — one case per sound, closed, exactly as
/// ``WidgetState``'s vocabulary is.
///
/// `PRODUCT_SPEC.md:339` names four sound events ("recording starts", "converse starts",
/// "delivered", "failsafe"). Only the converse tick exists in the tree today — **the other
/// three are recorded as future cases, not added empty** (YAGNI, and a future dictation-tick
/// aspect fills its own slot). Adding a case is a decision, and the exhaustive switch in
/// `WidgetSoundSelectionTests` stops compiling until every caller handles it.
public enum WidgetSound: Equatable, Sendable {
    /// The converse start tick (`PRODUCT_SPEC.md:339`): "lower tick, clearly different from
    /// dictate", played exactly on entry into a converse session (``WidgetSoundSelection``).
    case converseStarted
}

/// The pure, tested half of the sound cue (`dual-mode` D6): *when* a sound plays.
///
/// The contract, pinned by `WidgetSoundSelectionTests`: `.converseStarted` plays **only** on a
/// transition into `.conversing` from a non-converse state — the first entry from IDLE and a
/// re-entry after the session ended included. The listening ↔ speaking phase change plays
/// nothing (one continuous session, not a new cue), and every other transition plays nothing.
///
/// The dictation transitions are silent because the dictate tick is not built yet. The "clearly
/// different from dictate" half (`PRODUCT_SPEC.md:196,339`) is a **directional claim recorded
/// against the unbuilt dictate tick**: the converse tone (`SystemWidgetSoundPlayer`) is defined
/// at the low end of the tick range, the dictate slot reserved higher, and the audible
/// distinction is verified when the dictate tick ships (SMOKE) — never gated here.
public enum WidgetSoundSelection {

    /// The one decision: a sound, if any, for the transition `previous` → `next`.
    public static func sound(from previous: WidgetState, to next: WidgetState) -> WidgetSound? {
        if isConverse(next), !isConverse(previous) { return .converseStarted }
        return nil
    }

    private static func isConverse(_ state: WidgetState) -> Bool {
        if case .conversing = state { return true }
        return false
    }
}

/// The playback seam — the ``LiveLevelSource`` shape (`LiveLevelSource.swift:30-33`): one
/// synchronous read-style operation, `Sendable` so the panel can hold it across the store
/// observation.
public protocol WidgetSoundPlaying: Sendable {
    /// Play one widget sound.
    func play(_ sound: WidgetSound)
}

/// The real conformance: a short, quiet, **low** tone with a fast decay envelope.
///
/// **Glue, executed by nothing in CI** (the window-server precedent): the *selection* is the
/// tested decision (`WidgetSoundSelectionTests`, driven through the panel by
/// `WidgetPanelBindingTests`); the tone's audible character is a SMOKE observation (the `record`
/// aspect's SMOKE 134 "the lower tick" state-entered check), never gated.
///
/// The tone is ~60 ms at 220 Hz with an exponential decay — the "lower" decision recorded
/// honestly: chosen at the low end of the tick range, with the dictate tick's slot reserved
/// higher, and the audible "clearly different from dictate" (`PRODUCT_SPEC.md:339`) verified
/// when the dictate tick ships. Audio is created lazily on first `play`, so constructing the
/// default player is headless-safe — `configure` can build it and no audio exists until a
/// session actually starts.
///
/// `@MainActor` — the blessed main-actor-friendly form, never `@unchecked Sendable`; the
/// `@preconcurrency` on the conformance is the toolchain's accepted way for a `Sendable`-inheriting
/// protocol to be witnessed from a `@MainActor` class under strict concurrency (the isolation is
/// real: every call site — the panel's `apply` — is on the main actor).
@MainActor
public final class SystemWidgetSoundPlayer: @preconcurrency WidgetSoundPlaying {

    /// The tone, created on first play and reused — synthesizing is cheap, and a fresh buffer
    /// per tick would be needless work on the play path.
    private var tone: AVAudioPCMBuffer?

    /// The engine and node, created on first play — nothing exists until a sound is actually
    /// asked for, which is what keeps constructing the default player headless-safe.
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?

    public init() {}

    public func play(_ sound: WidgetSound) {
        switch sound {
        case .converseStarted:
            renderConverseTick()
        }
    }

    /// Renders the converse tick through the shared engine.
    private func renderConverseTick() {
        if engine == nil {
            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: nil)
            engine.prepare()
            self.engine = engine
            self.player = player
        }
        guard let engine, let player else { return }
        let tone = self.tone ?? Self.makeConverseTick()
        self.tone = tone
        if !engine.isRunning {
            try? engine.start()
        }
        player.stop()
        player.scheduleBuffer(tone)
        player.play()
    }

    /// The tick itself: ~60 ms at 220 Hz — low, per the recorded "lower" decision — with a fast
    /// decay envelope, at a quiet 0.15 peak amplitude.
    private static func makeConverseTick() -> AVAudioPCMBuffer {
        let sampleRate: Double = 44_100
        let frames: AVAudioFrameCount = 2646  // ~60 ms at 44.1 kHz
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
            ?? AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        guard let samples = buffer.floatChannelData?[0] else { return buffer }
        let frequency: Float = 220
        for i in 0..<Int(frames) {
            let t = Float(i) / Float(sampleRate)
            let envelope = exp(-t * 90)
            samples[i] = 0.15 * envelope * sin(2 * .pi * frequency * t)
        }
        return buffer
    }
}