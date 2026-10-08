# Brief (no GitHub issue; inline brief, 2026-10-07)

Source: the `composite-intent-resolver` unit's recorded finding (PR #57; docs/STATUS.md "shipped voice leg is unwired")
and its recommendation: wire the intent leg into the shipped converse path.

**The gap (verified 2026-10-04):** `AppBootstrap.configure` calls `composeConverseWiring` WITHOUT
`intentProvider` / `intentActionHandler` (ConverseWiring.swift defaults return nil). `root.intentWiring`
is read only by the probe. So in the real app neither `PhraseIntentResolver` nor the opt-in
`CompositeIntentResolver` is reached by voice: every utterance gets the echo reply, and "the shipped
configuration can voice-act" (phrase-intent-resolver, 2026-09-25) is true only in tests/probes.

**Goal:** pass the composed `IntentWiring`'s resolve and perform legs into the converse driver so a spoken
phrase (an enabled tool + a phrase row, the two-step opt-in) reaches the shared executor, the confirmation
card, the audit record and the spoken ack — in the real app.

**Why it needs care:** first time voice can trigger an action in a shipped build. Trust invariants:
destructive/outward-facing always confirms (approval .withheld → card), every decision audited, shell never
voice-reachable, the default (no phrase file / no enabled tool) must behave exactly as the echo default
does today, the dictation path untouched, zero network and no child process by default. G5 will re-anchor
(AppBootstrap.swift edit).

Known context to verify in the dig: ConverseLoopDriver's intent step (card-up guard, bounded re-ask = 2,
`auditRecorded == false` → failure copy), WidgetConfirmationSignal / card confirm-decline closures already
exist, `intentActionHandler` signature `(ActionInvocation, String) async -> String?`, the probe
(`ConverseLoopDrive.swift:196`) wires nil for these, SMOKE rows 148-165 are VOID until this ships.
