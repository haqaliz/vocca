# Vocca

**Speak; it appears, or it answers — instantly, on your machine, and yours to change.**

Vocca is an open-source, macOS, local-first voice tool. Hold a hotkey and talk, and polished text types itself into *any* app. Talk to it and it talks back through local Kokoro TTS — and it can *act*.

Your audio never has to leave your Mac.

---

> ### ⚠️ Status: planning
>
> **Nothing is built yet.** This repository currently contains the plan: the vision, the phased roadmap, the capability backlog, the architecture, and the product spec. Implementation starts at **C1** (audio capture + global hotkey).
>
> If you're here from a link expecting a download — there isn't one yet. Star the repo if you want to know when there is.

---

## Why

Wispr Flow proved that voice-to-text-everywhere is a daily habit worth paying for. But it's closed, cloud, and rented — it structurally cannot be private, local, or open.

Good open-source Mac dictation now exists ([VoiceInk](https://github.com/Beingpax/VoiceInk), [FluidVoice](https://github.com/altic-dev/FluidVoice), Handy, Whispering), and we're glad it does — it means dictation quality is table stakes rather than a differentiator. What still doesn't exist is the *combination*:

**great dictation + a voice agent that can actually do things + fully local + extensible.**

That combination is the open lane, and it's what Vocca is for.

## What it will do

1. **Dictate anywhere** — hold `⌥Space`, talk, release. Polished text lands in whatever app has focus.
2. **Clean it up** — fillers gone, punctuation right, your names spelled your way. Deterministic by default; a local LLM if you want one.
3. **Type reliably** — a four-rung injection ladder that ends, always, in your words being recoverable. Losing a transcript is treated as a bug with no acceptable rate.
4. **Talk back** — local Kokoro TTS, real turn-taking, and barge-in you can interrupt.
5. **Act** — voice that drives MCP tools, commands, and coding agents, with the active app and your selection as context.

## Principles

- **Local-first, literally.** The default configuration makes **zero network calls** — asserted by a CI test that is a permanent release blocker. Any egress is opt-in and badged at the moment it happens.
- **A transcript is never lost.** Every failure path ends with your text recoverable and copyable.
- **Everything pluggable.** ASR, cleanup, TTS, and actions each sit behind an interface with **two real implementations shipped** — because a seam with one implementation is an assertion, not a seam.
- **The local core is never crippled.** A future hosted tier may only ever be *added* to a seam. Nothing local gets removed, degraded, or feature-gated to sell it.
- **Gets better as local models improve.** Our value is the integration, the UX, and the action layer — never a wrapper around one checkpoint.

## Planned stack

| Layer | Choice | Why |
|-------|--------|-----|
| Shell + core | Native SwiftUI, single Swift 6 process | Direct AX/CGEvent/Pasteboard access, no IPC on the latency path |
| ASR (default) | [Parakeet TDT 0.6B v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) via [FluidAudio](https://github.com/FluidInference/FluidAudio) | CoreML on the Neural Engine; ~24× realtime on M4; low power |
| ASR (second) | whisper.cpp large-v3-turbo | Shipped, not promised — proves the seam and hedges ecosystem risk |
| TTS | [Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M) | Small, fast time-to-first-audio, Apache-2.0 |
| VAD / turn-taking | Silero VAD + Parakeet EOU 120M | Frame-level VAD alone doesn't do turn-taking |
| Cleanup | Rules → Ollama → BYOK | Rules by default: ~0 MB, <5 ms, no network |
| Actions | MCP | The action layer, gated on confirmation and an audit log |

Platform: **macOS on Apple Silicon.** No Windows or Linux until the Mac experience is genuinely good.

## Documentation

| Document | What it covers |
|----------|----------------|
| [`VISION.md`](VISION.md) | The thesis, the moat, the non-goals |
| [`docs/ROADMAP.md`](docs/ROADMAP.md) | Six phases (P0–P5), each with milestones, metrics, and an exit gate |
| [`docs/technical/CAPABILITY_ROADMAP.md`](docs/technical/CAPABILITY_ROADMAP.md) | C1–C14: the independently-shippable build backlog |
| [`docs/technical/ARCHITECTURE.md`](docs/technical/ARCHITECTURE.md) | **Authoritative.** Types, seams, threading, failure semantics |
| [`docs/product/PRODUCT_SPEC.md`](docs/product/PRODUCT_SPEC.md) | Widget states, interaction, onboarding, settings |
| [`CLAUDE.md`](CLAUDE.md) | Orientation for coding agents working in this repo |

## Non-goals

- Cross-platform before macOS is genuinely good.
- Cloud in the open core, or any audio leaving the device by default.
- A crippled free tier to upsell a hosted one.
- An over-built assistant before dictation is excellent.
- A searchable archive of everything you've ever said.

## Contributing

Not yet — there's no code to contribute to. Once C1 lands, the seams in [`ARCHITECTURE.md`](docs/technical/ARCHITECTURE.md) are the extension points, and "add your own ASR engine" is an explicitly supported path.

Issues and discussion about the plan itself are welcome now.

## License

Apache-2.0. The patent grant matters for a tool doing system-level input injection, and it's the friendlier choice for the open-core structure described in the roadmap.
