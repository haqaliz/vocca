# Card: C1 — Audio capture + global hotkey

- **Type:** feat
- **Id / slug:** `audio-capture-hotkey`
- **Branch:** `feat/audio-capture-hotkey/aliz`
- **Source:** inline brief (no GitHub issue — repo has Issues enabled but zero issues filed)
- **Capability:** C1 in `docs/technical/CAPABILITY_ROADMAP.md`
- **Phase:** P0 (core dictation loop), week 1

---

## Brief

C1 from `docs/technical/CAPABILITY_ROADMAP.md`: audio capture + global hotkey, the first
brick. Nothing has shipped yet, so this also bootstraps the SPM layout from
`ARCHITECTURE.md` §3 with Swift 6 strict concurrency on from commit one. Build the `⌥Space`
CGEvent tap (hold-to-talk, key-down starts / key-up ends), `AVAudioEngine` capture at 16 kHz
mono into a ring buffer per `ARCHITECTURE.md` §7 (realtime thread writes samples and nothing
else), the `AudioCapture` seam, the `SessionActor` lifecycle with the watchdog from §8, and
the floating SwiftUI widget's IDLE → RECORDING → TRANSCRIBING states per `PRODUCT_SPEC.md` §2.

Fold in `ROADMAP.md`'s other week-1 milestone — Developer ID signing, hardened runtime,
notarization, non-sandboxed entitlements — because it has no home in C1–C14 and R9 says not
to discover it at ship time.

### Caveat to design around from the start

The acceptance test as written (100 synthetic key-down/key-up pairs; a killed key-up
asserting watchdog closure; buffer contents asserted against known-length fixtures for
sample-rate/channel regressions) **cannot run headless** — CGEvent taps need Input Monitoring
and Accessibility grants CI lacks, and macOS disables taps unprompted
(`tapDisabledByTimeout` / `tapDisabledByUserInput`). Put the state machine behind a
`HotkeyMonitor` protocol so the 100-cycle and watchdog tests run against a fake, and keep the
real tap a thin adapter with its own re-arm handling.

Tests first, per the repo's test-first rule.

Also cover:
- Input Monitoring denial as an honest hard block (`PRODUCT_SPEC.md:173` — it is the one
  genuinely fatal permission).
- A toggle alternative to hold-to-talk — `PRODUCT_SPEC.md:251` calls it a real accessibility
  need, not a preference, and the C1 text ("hold-to-talk only") does not mention it.

---

## Acceptance, as written in CAPABILITY_ROADMAP.md (C1)

> A scripted harness fires 100 synthetic key-down/key-up pairs at varying durations (80 ms to
> 60 s) and asserts exactly 100 sessions started, 100 ended, zero overlapping, zero orphaned.
> A separate test kills the key-up mid-session and asserts the watchdog closes capture within
> its timeout. Buffer contents are asserted against known-length fixtures, so a sample-rate or
> channel-count regression fails loudly.

**Pluggable seam:** `AudioCapture` — yields `AudioBuffer` chunks and a session lifecycle.
**Dependencies:** none. This is the first brick.

---

## Related issues / PRs

None. The repository has no issues and no prior PRs; `master` carries two commits (planning
docs, then `.gitignore`).

---

## Known contradiction in the tooling (flagged, resolved)

The `vocca-worktrees` and `vocca-begin-fast` skill files assume a **Python/uv** core
(`pyproject.toml`, `uv sync`, `src/vocca/`, `uv run pytest`). `docs/technical/ARCHITECTURE.md`
declares itself authoritative on technical direction (line 3) and locks a **single-process
Swift 6 app with SPM targets** (§2, §3). The skills predate that lock and are not in the
precedence list. **Resolution: Swift 6 + SPM.** The `uv` steps are not applicable; the skill
files should be updated separately.
