# Vocca: Product Roadmap

> **Vocca** is an open-source, macOS, local-first voice tool. Press a hotkey and talk, and polished text types itself into *any* app. Talk to it and it talks back through local Kokoro TTS — and it can *act*. It runs on your machine; your audio never has to leave it.

---

## Why this roadmap looks the way it does

**The wedge.** Wispr Flow proved the daily habit and can't be private/local/open — it is closed, cloud, and rented by construction. But **OSS dictation on macOS is no longer an empty lane**: [VoiceInk](https://github.com/Beingpax/VoiceInk) (GPL-3, Swift, already on FluidAudio/Parakeet, $29–69 lifetime) and [FluidVoice](https://github.com/altic-dev/FluidVoice) (free, OSS, Parakeet, explicitly "a local Wispr Flow alternative") both ship today. So *dictation quality alone is table stakes, not differentiation.*

The open lane is the **combination**: great dictation **+ a voice-agent loop that can act +** fully local **+** extensible. That combination is what nobody has shipped. This roadmap is sequenced so we earn the right to build it — dictation first, because that's the daily habit that earns the stars, and because an agent layer cannot rescue mediocre dictation.

**The evidence we're building on:**
- Local ASR on Apple Silicon is genuinely fast enough: Parakeet TDT 0.6B v3 runs at **RTF ~0.042 on an M4** (~24× realtime), from a 0.6B model with a ~2 GB unified-memory floor [[mlx-community/parakeet-tdt-0.6b-v3](https://huggingface.co/mlx-community/parakeet-tdt-0.6b-v3)].
- The Swift/CoreML path is real and maintained: [FluidAudio](https://github.com/FluidInference/FluidAudio) ships ANE-accelerated Parakeet TDT v3, an EOU (end-of-utterance) model, VAD, and diarization behind a Swift SDK.
- Local TTS is solved for our use case: **Kokoro-82M** is small, CPU-viable, and — uniquely among the mainstream local options — **Apache-2.0 and cleanly commercially safe** (XTTS v2 is non-commercial).
- The hard part is not the models. It is **injection reliability** and **perceived latency**. The macOS Accessibility API's documented failure mode is that `AXUIElementSetAttributeValue` on `kAXSelectedTextAttribute` **returns success while inserting nothing** in many apps. That single behavior shapes P0.

If a number you need isn't here or in `VISION.md`, it is unverified. Do not invent one.

---

## Guiding Principles

1. **A transcript is never lost.** Every failure mode in the injection ladder terminates in the widget holding recoverable text. A dictation tool that silently eats thirty seconds of speech is worse than no tool. This is the single non-negotiable invariant of the product.
2. **Local-first, literally — not as a default.** In the OSS core, the shipped default path involves zero network. Any egress is opt-in, explicitly badged at the moment of use, and never silent. "Private by default" must survive an audit of the actual code paths, not just the marketing.
3. **Dictation is table stakes; the action layer is the wedge.** We must *reach parity* with the free OSS incumbents on dictation feel, and *then* win on the voice-agent loop and actions. Both halves are required. Neither alone is a product.
4. **Everything pluggable, from day one.** ASR, TTS, cleanup, and injection each sit behind an interface with **two real implementations shipped** — not one implementation and a promise. A seam with a single implementation is not a seam; it's an assertion. This is also how the later hosted tier slots in without a rewrite.
5. **Latency is a product feature with a number.** Perceived latency (key release → text on screen) is measured, tracked per phase, and regressions block a release. "It feels fast" is not a metric.
6. **Never cripple the local core.** The hosted trained-model tier is designed-for and never built in the OSS core. No capability is withheld from the local path to create upsell pressure. If a feature works locally, it ships locally.
7. **Gets better as local models improve.** A stronger local ASR/TTS/LLM should make Vocca better *for free*. Our value is integration, UX, and the action layer — never a wrapper around one specific checkpoint.

---

## Locked technical decisions

These came out of the planning session and hold until a phase gate explicitly revisits them.

| Decision | Choice | Reasoning |
|----------|--------|-----------|
| **App shell** | Native SwiftUI + a single Swift core process | Direct AX/CGEvent/Pasteboard access, no IPC on the latency path, and FluidAudio's CoreML/ANE models drop straight in. Tauri would buy cross-platform we explicitly deferred and cost us the fastest ASR path. |
| **ASR default** | Parakeet TDT 0.6B v3 via FluidAudio (CoreML/ANE) | Fastest credible local option; ANE offload means low power; ships with streaming + EOU we need in P3. |
| **ASR second engine** | whisper.cpp large-v3-turbo | Shipped, not promised. Hedges Parakeet's thinner ecosystem (Whisper has ~4 production inference paths on Apple Silicon; Parakeet has ~1–2) and covers languages/accuracy cases Parakeet misses. |
| **TTS** | Kokoro-82M behind `SpeechSynthesizer` | Small, fast time-to-first-audio, Apache-2.0. Expressivity-focused alternatives (Chatterbox, XTTS v2) are heavier and/or license-encumbered for a use case that needs speed, not voice cloning. |
| **VAD / endpointing** | Silero VAD + FluidAudio Parakeet EOU 120M — **deferred to P3** | Frame-level VAD alone doesn't do turn-taking; the 2026 pattern is VAD + a small EOU model on top. Dictation with hold-to-talk needs neither. The voice loop does. |
| **P0 capture model** | Hold-to-talk only (`⌥Space` down/up) | The user's finger is the ground truth. Makes "it cut me off mid-sentence" — the #1 rage-quit bug in this category — structurally impossible, and keeps VAD tuning out of P0. |
| **P0 injection** | Clipboard-paste primary, AX opportunistic, widget failsafe | Leads with what actually works everywhere. AX is used only on a verified per-app allowlist precisely because its failure mode is silent. |
| **Cleanup default** | Deterministic rules; local LLM and BYOK both opt-in | Keeps the default install small and the privacy promise literal. |
| **License** | Apache-2.0 | Patent grant matters for a tool doing system-level input injection, and it's the friendlier choice for the later open-core structure. |

---

## Phase Overview

| Phase | Theme | Window | Exit Gate |
|-------|-------|--------|-----------|
| **P0** | Core dictation loop — capture → ASR → inject | Weeks 1–4 | Founder dictates daily for 7 consecutive days without keyboard rescue |
| **P1** | AI cleanup — raw ASR becomes polished text | Weeks 4–7 | Cleaned output beats raw on a held-out set; rules-only stays the default |
| **P2** | Latency + injection feel — the two make-or-break battles | Weeks 7–11 | Latency target met at p50/p95 **and** injection matrix ≥95% across 20 apps |
| **P3** | Voice-agent loop with Kokoro — smarter than SKI | Weeks 11–16 | A full spoken exchange with barge-in, keyboard untouched |
| **P4** | Context + actions / MCP — voice that *does things* | Weeks 16–22 | Voice drives real MCP tools using active-app context, safely |
| **P5** | Reach — community, contributors, hosted-tier seams | Weeks 22+ | Traction thresholds met; every seam proven by a swappable provider |

Windows are sequencing guidance for a solo founder, not commitments. Real user pull reorders this freely.

---

## P0: Core Dictation Loop

**Objective:** Press `⌥Space`, talk, release — and the words appear in whatever app has focus. Nothing else. This is the whole product's spine, and everything after it is an upgrade to a loop that already works.

**Decision philosophy:** Optimize for *the loop never breaking*, not for quality of output. Raw ASR text with no cleanup is acceptable here. Text landing in the wrong place, or vanishing, is not.

**Scope discipline:** No cleanup. No VAD. No streaming. No TTS. No settings UI beyond permissions and one hotkey. If it isn't on the path from key-down to text-on-screen, it is not P0.

### Milestones

| Week | Milestone | Deliverable | Success Signal |
|------|-----------|-------------|----------------|
| 1 | Skeleton + permissions | SwiftUI app, code-signed, non-sandboxed, requests Accessibility + Microphone with honest copy | Cold install on a clean Mac reaches "ready" in under 60 seconds |
| 1 | Global hotkey + capture | `⌥Space` down/up drives `AVAudioEngine`; widget shows a live waveform | 100 press/release cycles, zero missed or stuck sessions |
| 2 | ASR behind the seam | `ASREngine` protocol; **Parakeet via FluidAudio** as the first implementation | A 10-second clip transcribes correctly, on-device, airplane mode on |
| 2 | Second ASR engine | **whisper.cpp large-v3-turbo** behind the same protocol, switchable in settings | Both engines transcribe the same fixture; swapping requires no caller change |
| 3 | The injection ladder | AX allowlist → clipboard+⌘V → CGEvent → widget failsafe, with Secure Input detection | Text lands correctly in the P0 app matrix (below); Secure Input yields an honest message, never a silent drop |
| 3 | Clipboard hygiene | Save → set → paste → restore, with a settling delay and a race-tolerant restore | Clipboard contents survive 100 consecutive dictations with Raycast/Paste running |
| 4 | Failsafe + telemetry-free instrumentation | Widget retains last transcript with ⌘C; **local-only** latency/success counters | No transcript is unrecoverable in any tested failure path |
| 4 | **DECISION GATE** | 7-day daily-use log | See gate below |

### P0 app matrix

Injection is verified against these, chosen to span the failure classes rather than to be exhaustive: **native AppKit** (Notes, Mail, TextEdit), **Electron** (VS Code, Slack, Discord), **browsers** (Safari, Chrome — plain fields *and* Google Docs' custom editor), **terminals** (Terminal, iTerm2, Ghostty), **Java/other** (IntelliJ), and **known-hostile** (any Secure Input field, 1Password).

### P0 Success Metrics

- **Injection success rate:** ≥90% first-method-success across the P0 app matrix. (95% is the P2 bar; P0 only has to be *usable*.)
- **Transcript loss rate:** **0%.** Every failure reaches the widget failsafe. This metric has no acceptable non-zero value.
- **Session reliability:** 0 stuck-recording or missed-hotkey events across a week of real use.
- **Latency:** measured and recorded, but **not yet a gate** — P2 owns the number.

### 🚦 P0 → P1 Gate

- **PROCEED** if the founder dictates as their primary text-input method for **7 consecutive days** without once reaching for the keyboard to fix a Vocca failure, **and** transcript loss is zero, **and** injection success is ≥90% across the matrix.
- **HOLD AND FIX P0** otherwise. Do not advance to cleanup. A polished sentence delivered unreliably is worth less than a rough sentence delivered every time.
- **Calibration note:** P0 is judged against **FluidVoice and VoiceInk installed side by side**, not against zero. If ours feels worse than the free incumbents on the raw loop, the gate has not been met regardless of what the numbers say.

---

## P1: AI Cleanup

**Objective:** Turn raw ASR output into text a person would have typed — fillers gone, punctuation right, names spelled the way the user spells them — without making the default install heavier or the privacy promise softer.

**Scope discipline:** Still no streaming, no TTS, no agent. Cleanup only.

### The three-rung ladder

| Rung | Engine | Default? | Cost | Egress |
|------|--------|----------|------|--------|
| 1 | Deterministic rules | **Yes** | ~0 MB, <5 ms | None |
| 2 | Local LLM via Ollama | Opt-in | User pulls their own model | None |
| 3 | BYOK cloud endpoint | Opt-in, badged | User's API key | **Yes — badged at point of use** |

Rung 1 covers filler removal (um, uh, like, you know), sentence segmentation and punctuation, capitalization, and a **custom dictionary** of user-defined replacements (names, jargon, code identifiers). Rung 2 adds tone, rewriting, and reflow. Rung 3 exists so the tool is honest about what people will do anyway — with a persistent, non-dismissable indicator when it's on.

### Key Deliverables

| Area | Deliverable |
|------|-------------|
| Interface | `CleanupProvider` protocol with all three rungs implemented and hot-swappable |
| Rules engine | Filler/punctuation/capitalization + user dictionary, all deterministic and unit-tested |
| Local LLM | Ollama integration with graceful degradation to rules when Ollama is absent or slow |
| BYOK | Provider-agnostic endpoint config; **persistent egress badge**; off by default; never silently re-enabled |
| Eval harness | A held-out set of real dictation samples with human-preferred targets, run in CI |
| Timeout policy | Cleanup that exceeds its budget yields the *raw* transcript rather than blocking injection |

### Success Metrics

- **Cleanup quality:** blind pairwise preference for cleaned-over-raw on the held-out set — target **≥80%** on rung 1, higher on rung 2.
- **Rules-path latency:** <10 ms, so the default install pays effectively nothing.
- **Default purity:** an automated test asserts the default configuration makes **zero network calls** during a full dictation cycle. This test is a release blocker forever.
- **Degradation:** 100% of cleanup timeouts/failures still inject the raw transcript. Cleanup must never be able to lose text.

### 🚦 P1 → P2 Gate

- Rung-1 rules win ≥80% blind preference over raw, **and**
- The zero-network default test passes in CI, **and**
- Cleanup has never once caused a transcript loss or a blocked injection across a week of daily use.

---

## P2: Latency + Injection Feel

**Objective:** Win the two battles CLAUDE.md names as make-or-break. Make the loop feel instant, and make injection work everywhere — with numbers, not impressions.

**Why this is its own phase:** These are the only two things a user actually notices minute-to-minute, and they are the two places where a closed, well-funded incumbent has spent years. They deserve dedicated engineering rather than being folded into "polish."

### Key Deliverables

| Area | Deliverable |
|------|-------------|
| Latency instrumentation | Local-only histogram of key-release → text-on-screen, broken into capture / ASR / cleanup / inject spans |
| Model warm-start | ASR model resident and warm; first dictation after launch is not the slow one |
| Streaming ASR | Partials rendered **in the widget only** — never injected into the target app (revising text in someone else's field breaks in Electron, terminals, and Docs) |
| Speculative start | Begin ASR on the buffer while the user is still speaking, finalize on release |
| Injection matrix, formalized | The P0 matrix expanded to 20+ apps, run as a semi-automated harness, tracked per release |
| Per-app strategy memory | Learn and persist which rung of the ladder works per bundle ID; stop retrying what's known to fail |
| Clipboard-manager coexistence | Verified against Raycast, Alfred, Paste, Maccy |
| Regression gate | A latency or injection regression blocks the release |

### Success Metrics

- **Perceived latency (release → text):** **p50 ≤ 400 ms, p95 ≤ 800 ms** for a 10-second utterance on an M-series Mac with the default engine. These are the numbers the phase is judged on.
- **Injection success:** **≥95% first-method-success** across the 20-app matrix, with per-app strategy memory active.
- **Transcript loss:** still **0%**.
- **Warm-start:** first-dictation-after-launch latency within 20% of steady-state.

### 🚦 P2 → P3 Gate

- Latency targets met at both p50 and p95, **and**
- ≥95% injection success across the 20-app matrix, **and**
- **≥5 external users** report the dictation loop as good as or better than the tool they were using. This is the first gate that requires someone other than the founder — dictation parity has to be externally confirmed before we spend a line of code on the agent.

---

## P3: Voice-Agent Loop with Kokoro

**Objective:** Vocca talks back. A spoken exchange completes without touching the keyboard — and it is a step past SKI on turn-taking, because barge-in works.

**This is where the wedge starts.** Everything before it was earning the right to be here.

### What "smarter than SKI" means concretely, in this phase

- **Streaming ASR with real endpointing** — Silero VAD for speech/silence plus the Parakeet EOU 120M model for *turn* decisions, not just silence thresholds. Push-to-talk stops being the only option.
- **Barge-in** — the user interrupts mid-reply; TTS ducks and stops, capture resumes, and the interrupted reply is discarded cleanly.
- **Dual mode** — an explicit, visible distinction between *dictate into the focused field* and *converse with Vocca*. The mode is never ambiguous, because ambiguity here means talking to your boss in Slack when you meant to talk to the agent.

### Key Deliverables

| Area | Deliverable |
|------|-------------|
| TTS seam | `SpeechSynthesizer` protocol; **Kokoro** as first implementation, **macOS `AVSpeechSynthesizer`** as the shipped second (proves the seam, and gives a zero-download fallback) |
| Streaming capture | Continuous capture with Silero VAD; EOU model gates turn commitment |
| Barge-in | Full-duplex audio: TTS output ducks and halts on detected user speech within a target window |
| Echo handling | The mic must not transcribe Vocca's own voice |
| Dual mode | Distinct hotkey and unmistakable widget state per mode; no silent mode switching |
| Conversation state | Bounded, inspectable, local turn history — with a visible "forget" control |

### Success Metrics

- **Time-to-first-audio (Kokoro):** ≤300 ms from reply text available.
- **Barge-in responsiveness:** TTS halts within **≤200 ms** of detected user speech.
- **Endpointing accuracy:** ≥95% correct turn commitment on a recorded conversational set — with **false cutoffs weighted 5× worse than late commits**, because being interrupted mid-sentence is the failure users won't forgive.
- **Echo rejection:** 0 instances of Vocca transcribing its own output.
- **Mode clarity:** 0 mis-injections — text intended for the agent never lands in an app field, and vice versa.

### 🚦 P3 → P4 Gate

- A full spoken exchange (≥5 turns, including at least one barge-in) completes with the keyboard untouched, **and**
- False-cutoff rate below the endpointing target on the recorded set, **and**
- Zero mode-confusion mis-injections across a week of daily use.

---

## P4: Context + Actions / MCP

**Objective:** Voice that *does things*. Vocca knows what app you're in and what you have selected, and can drive MCP tools, run commands, and hand work to coding agents.

**This is the differentiator no OSS dictation tool has.** It is also the phase with the largest blast radius, so it is gated on safety, not just capability.

### Key Deliverables

| Area | Deliverable |
|------|-------------|
| Context provider | Active app (bundle ID), window title, and current selection via AX — behind a `ContextProvider` seam |
| Context consent | Per-app opt-in for context capture, with a visible indicator and a global kill switch |
| MCP client | Vocca as an MCP client; tools discoverable, listed, and individually enable-able |
| Action confirmation | Destructive or outward-facing actions require explicit confirmation; the confirmation states what will happen before it happens |
| Dry-run mode | Every action can be previewed as "here's what I would do" before it is armed |
| Audit log | Local, append-only record of every action taken, inspectable by the user |
| Coding-agent handoff | Voice → a coding agent session with the active project as context |

### Success Metrics

- **Action success rate:** ≥90% of voice-issued actions on the supported tool set complete as intended.
- **Unintended actions:** **0.** No action fires without the user's intent being confirmed at the required level.
- **Context accuracy:** ≥95% correct active-app and selection resolution across the P2 app matrix.
- **Auditability:** 100% of actions appear in the local log with enough detail to reconstruct what happened.

### 🚦 P4 → P5 Gate

- Zero unintended actions across a month of daily use, **and**
- ≥3 distinct MCP tool integrations working end-to-end from voice, **and**
- ≥10 external users have run the action layer on their own machines without a safety incident.

---

## P5: Reach

**Objective:** Turn a good tool into a project with gravity — contributors, users, and the seams that make the later hosted tier a slot-in rather than a rewrite.

### Key Deliverables

| Area | Deliverable |
|------|-------------|
| Distribution | Notarized signed builds, Homebrew cask, clean auto-update |
| Onboarding | First-run flow that gets a non-technical Mac user dictating in under two minutes |
| Contributor surface | Documented seams, a "add your own ASR engine" guide, and at least one community-contributed provider merged |
| Model registry | In-app model management: download, switch, remove — for ASR and TTS alike |
| Plugin/action ecosystem | Third parties can register actions without forking |
| Hosted-tier seams | `ASREngine` and `CleanupProvider` proven by an out-of-tree provider that the core knows nothing about |
| Benchmarks, published | Our latency and injection-success numbers, methodology included, against the OSS field |

### Success Metrics

- **Traction:** GitHub stars and, more meaningfully, **weekly active installs** (locally-counted, opt-in, aggregate-only — never per-user telemetry).
- **Contributors:** ≥5 external contributors with merged non-trivial PRs.
- **Seam proof:** an out-of-tree ASR provider works without core changes. This is the *only* honest test that the hosted tier will slot in.
- **Retention:** users who dictate in week 1 still dictating in week 4.

---

## The hosted tier: designed-for, not built

Nothing in P0–P5 builds cloud into the OSS core. What P0–P5 *do* build is the set of seams the hosted tier would use:

| Seam | Local implementations shipped | What hosted would slot in |
|------|------------------------------|---------------------------|
| `ASREngine` | Parakeet/FluidAudio, whisper.cpp | Our own trained ASR model, served |
| `CleanupProvider` | Rules, Ollama, BYOK | Our own trained cleanup/rewrite model |
| `SpeechSynthesizer` | Kokoro, `AVSpeechSynthesizer` | A higher-quality hosted voice |
| `ContextProvider` | macOS AX | (unchanged — context stays local by construction) |

**The rule that governs this table:** a hosted provider may only ever be *added* to a seam. No local implementation is removed, degraded, or feature-gated to make room for it. If that rule is ever violated, the open-core promise is broken and the project has lost the thing that made it worth building.

---

## Risks & Assumptions Register

| # | Risk / Assumption | Tied to | Likelihood | Impact | Mitigation / Test |
|---|-------------------|---------|-----------|--------|-------------------|
| R1 | **AX silently no-ops**: injection reports success and inserts nothing; user loses a long transcript | P0 injection | **High** (documented behavior) | **Fatal (trust)** | Clipboard-paste primary; AX only on a verified allowlist; widget failsafe terminates every path; transcript-loss metric gated at exactly 0% |
| R2 | **Secure Input blocks everything**: password fields and some terminals refuse event taps entirely | P0 injection | High | Med | Detect Secure Input explicitly, skip to failsafe, and *say why* — an honest message beats a mysterious no-op |
| R3 | **Latency ceiling is worse than expected** on older Apple Silicon | P2 | Med | High | Measure across M1–M4 early; ship the smaller model tier as default on constrained machines; treat p95 as the real number |
| R4 | **Dictation parity with FluidVoice/VoiceInk isn't reached** — we're late to a lane that filled up | P0/P2 gates | **Med** | **High** | Gates explicitly calibrated against those tools side-by-side; P2 gate requires external confirmation before any agent work begins |
| R5 | **Parakeet ecosystem is thin**: one maintained CoreML path; a break leaves us stranded | P0 ASR | Med | High | whisper.cpp shipped as a real second engine from week 2, not promised later |
| R6 | **Endpointing false cutoffs** make the voice loop infuriating | P3 | High | High | Hold-to-talk stays available forever as the escape hatch; false cutoffs weighted 5× in the metric; VAD deliberately deferred out of P0 |
| R7 | **Barge-in echo**: Vocca transcribes its own TTS output | P3 | Med | Med | Echo rejection as an explicit deliverable with a zero-tolerance metric; verified on speakers, not just headphones |
| R8 | **Actions do something destructive** the user didn't intend | P4 | Med | **Fatal (trust)** | Confirmation for destructive/outward-facing actions; dry-run mode; local audit log; zero-unintended-actions gate |
| R9 | **Notarization friction**: non-sandboxed + Accessibility + Input Monitoring draws review scrutiny | P0, P5 | Med | Med | Sign and notarize from week 1 — never discover this at ship time; document every permission and why it's needed |
| R10 | **Solo-founder bandwidth**: six phases is a lot of surface | All | High | Med | Phases are strictly sequential with hard gates; no phase starts before its predecessor's gate passes; scope discipline stated per phase |
| R11 | **Privacy promise erodes quietly** via a convenient BYOK default or an analytics "just this once" | P1, P5 | Med | **Fatal (positioning)** | Zero-network default asserted by a CI test that is a permanent release blocker; egress badged at point of use |
| R12 | **The agent layer never gets built** because dictation polish is infinite | P3 onward | Med | High | P2's gate is defined by *external* confirmation of parity, not by the founder's satisfaction — it's designed to be passable |

---

## One-line phase mantra

**P0:** never lose a word. **P1:** make the words right. **P2:** make it feel instant, everywhere. **P3:** make it talk back. **P4:** make it *do* things. **P5:** make it everyone's.
