# Card: speech-engine-switch

**Type:** feat · **Branch:** `feat/speech-engine-switch/aliz` · **Owner:** aliz
**Source:** no GitHub issue — inline brief (from the `vocca-next` handoff, 2026-08-28).

## Brief

Wire the ASR engine choice into the Speech settings tab and persist it, closing the unshipped
P0 milestone at `docs/ROADMAP.md:97` ("Second ASR engine — whisper.cpp large-v3-turbo behind the
same protocol, **switchable in settings**").

Today:
- `Sources/VoccaBootstrap/AppBootstrap.swift:206,208,355,937` all read the hardcoded
  `EngineSelection.defaultSelection`. There is **no store** behind it anywhere.
- `EnginePickerState` / `EnginePickerCopy` / `EnginePickerView` were built and tested in C3 and
  are referenced from `Sources/` only inside doc comments — **nothing constructs them**.
- `Sources/VoccaUI/SettingsView.swift:160` says so in its own words: *"Read-only: switching
  engines is the picker's own surface and is not wired into this window yet."*

## What the work is

- A persisted selection behind a one-file seam (the `CompletionFlagStore` UserDefaults
  precedent), read by the bootstrap at every one of those four sites, with tolerant decode
  falling back **loudly** to Parakeet (the `cleanup-config.json` precedent).
- The Speech page made live over the existing reducer, with an honest restart-to-apply note
  (`DictationEngineResolver` resolves once at launch) and the download step for whichever
  engine is unprovisioned.

## Caveat to dig into first

**The whisper GGUF manifests in `Sources/VoccaASR/Models/Manifests/` have never been
downloaded.** `CLAUDE.md` records that the Parakeet manifest shipped a placeholder digest
(`config.json`, 2 bytes, the SHA-256 of the literal `{}`) that made the default engine
unprovisionable on **every** machine from `ac381d0` until 2026-08-25, and that *"the whisper
manifests were generated the same way and have still never been downloaded — the same defect
may be sitting in them."* Shipping a switch without verifying them can take a user from a
working app to an unprovisionable one.

## Acceptance (test-first, per house discipline)

1. The resolver's selection comes from the store; `defaultSelection` is reached **only** on an
   empty/invalid stored value.
2. A settings write never swaps an in-flight session's engine (the
   `EngineSelectionConsumptionTests` never-auto-switch precedent).
3. A stored selection whose model is absent refuses the dictation with `.modelUnavailable`
   before the mic opens, rather than failing mid-session.
4. The whisper manifest verification runs env-gated (`VOCCA_MODEL_DIR`, visible skip) with a
   `SMOKE_CHECKLIST.md` step — the page itself is executed by nothing in CI (window-server rule).

## Why this, why now (from `vocca-next`)

- Unshipped **P0** milestone, not a P2 one.
- Retires **R5** (`docs/ROADMAP.md` risk register: "Parakeet ecosystem is thin… a break leaves
  us stranded", Med/High) for real — a second engine nobody can select is the mitigation on
  paper only, and `CAPABILITY_ROADMAP.md:400` guardrail 7 says "one implementation and a
  promise is not a seam".
- Everything downstream is gated (C9+ barred by guardrail 6 until the P2 gate), blocked
  (notarization needs a Developer ID), or founder-machine work (smoke steps 62–68, 87).
