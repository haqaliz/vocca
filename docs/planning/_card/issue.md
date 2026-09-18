# Card: feat/context-provider

> Inline brief — no GitHub issue exists (`gh issue list` for `haqaliz/vocca` is empty).
> Source: the `vocca-next` handoff (2026-09-18) + `CAPABILITY_ROADMAP.md` C12 entry +
> the C11 unit records (STATUS.md dual-mode entry).

## Brief

Build **C12 — Context provider — active app and selection** (`CAPABILITY_ROADMAP.md:345-359`):
a `ContextProvider` seam yielding the active bundle ID, window title, and current selected
text via AX. Per-app opt-in — **default off for every app**; the user grants each app
deliberately, no blanket "allow all". A **visible indicator whenever context is being read**,
plus a **global kill switch reachable in one action**. Context is **never persisted** beyond
the current turn and **never leaves the machine** — including when a BYOK cleanup provider is
active, where context is excluded from the payload unless separately and explicitly permitted.

Dependencies are met: C4's AX infrastructure ships (the injection ladder's
`kAXSelectedTextAttribute` read/verify machinery — `AXSource.swift`); C13 (Actions and MCP)
blocks on this capability (`CAPABILITY_ROADMAP.md:379`); the P3 gate's conversational leg
stays formally unmet until C13 (`docs/STATUS.md:97-99`). C12 is the lowest unshipped
capability in the roadmap.

Acceptance, written first (per `CAPABILITY_ROADMAP.md:353-355`):
1. A test asserts correct app/selection resolution across the C8 app matrix at ≥95%.
2. A privacy test asserts that with context capture off for an app, **no AX read of that
   app's content occurs at all** — not read-then-discard, but never read.
3. A second privacy test asserts context **never appears in a BYOK request payload**
   without the separate explicit grant.
These two privacy tests are the ones that make the privacy claim auditable rather than
promised.

Seam: `ContextProvider`. Notably, **this seam has no hosted counterpart by design** — context
is read locally, always, and the hosted tier never sees it (`CAPABILITY_ROADMAP.md:357`).

## Caveats (binding)

- The P2 and P3 gates stay **uncleared**; this is the fourth unit built ahead of them under
  the recorded posture (kokoro-binding, turn-taking, dual-mode — each recorded "No gate
  passes"), not a drift.
- The privacy contract is load-bearing: the never-read test and the never-in-BYOK-payload
  test are the auditable core. Per-app opt-in default-off and the one-action kill switch are
  requirements, not preferences.
- The zero-network invariant and the transcript-never-lost invariant stay untouched: context
  adds AX *reads* only — no injection-path changes, no new egress surface, nothing handed to
  a URL.
- The seam-doctrine two-implementation rule (`CAPABILITY_ROADMAP.md:414`) **is met**: the
  architecture record names `ContextProvider` → `AccessibilityContext`, `NullContext` —
  hosted tier **No — by design** (`ARCHITECTURE.md:281`). `NullContext` is the honest
  shipped default (nothing read); `AccessibilityContext` is the real AX adapter. (This
  caveat supersedes the original handoff's "record the exemption" note — the understanding
  note corrects it.)
- The dictate path is digest-pinned (`SessionMachine.swift`, `DictationPipeline.swift`) —
  C12 must not touch the dictation pipeline; its reads share AX infrastructure but add no
  writes.