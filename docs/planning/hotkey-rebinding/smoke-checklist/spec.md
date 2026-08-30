# Aspect: `smoke-checklist`

**Unit:** `hotkey-rebinding` · **Depends on:** `general-tab-recorder` · **Module:** docs only

## Problem slice

Nothing in this unit's user-visible half runs in CI. There is no window server, no TCC grant and no
event tap on a hosted runner, so the recorder, the real rebuild against a live tap, and the
`symbolichotkeys` read against a real user's preferences are all **executed by nothing** until
someone runs them. `docs/SMOKE_CHECKLIST.md` is where that is written down honestly, and it is
currently at step 110.

**User outcome:** none. This is the aspect that keeps the unit's claims true.

## In scope

- **S3 — new steps appended after 110**, in a new `### Hotkey rebinding` subsection, each in the
  house anatomy: bold claim → context → `*Gesture:*` → `*Pass:*` → `*Failure:*` → optional
  `*Void — not fail — if:*`. At minimum:
  1. **A real rebind takes effect on the next press** — rebind to `⌃⌥D`, dictate, and confirm the
     old `⌥Space` no longer starts a session.
  2. **It survives a relaunch** — quit, reopen, press the new chord.
  3. **A safe single key works unmodified** — bind `F13`, dictate with it. This is
     `PRODUCT_SPEC.md:322`'s accessibility requirement, executed for the first time.
  4. **A refused chord is refused** — attempt a bare letter and confirm the reason is shown and
     nothing is stored.
  5. **An Apple shortcut warns** — attempt `⌘Space` on a machine where Spotlight is enabled;
     confirm the warning names Spotlight, and that confirming still binds it (warn, never refuse).
  6. **A mid-dictation rebind is refused visibly** — start a toggle session, attempt a rebind,
     confirm the tab says so and the session is unharmed. **This is the C1-A guard's only real
     execution.**
  7. **The three surfaces agree** — after a rebind, the tab, the menu bar tooltip and a fresh
     onboarding run all show the new chord.
  8. **The rebuild leaves a live hotkey** — after several rebinds in a row, the hotkey still works.
     This is M4a's real execution, and the failure it guards is invisible: on an `LSUIElement` app
     a dead hotkey looks exactly like a working one.
- **S2 — the C1-E row updated** in `docs/planning/audio-capture-hotkey/prd.md:321`: M10 shipped,
  and the detection half **cannot cover the apps the risk names**. The row becomes true, with its
  limit stated.
- `CLAUDE.md`'s status block updated: "the hotkey is still not rebindable" has been repeated
  through three units and stops being true — with a matching "what this is NOT" paragraph naming
  what remains unexecuted.

## Out of scope

- Running the steps. They are the founder's, on hardware.
- The C8 matrix baseline run and `SMOKE_CHECKLIST` steps 62–68 — still unexecuted, still the
  actual blocker on three gates, and untouched by this unit.

## Acceptance criteria

1. Every new step names a **pass criterion an observer can check without inference**, per the
   file's own Rule 2.
2. Step 6 exists and is marked as the hot-mic guard's only real execution.
3. The C1-E row states both the mitigation **and** its limit — a row claiming full mitigation would
   repeat the original defect this unit exists to fix.
4. No claim is added to `CLAUDE.md` that a test or a smoke step does not support.

## Dependencies & sequencing

Last, after the surface exists. Docs only — no test floor change.

## Open questions / risks

- Step 5 depends on the founder's Spotlight being enabled and on its default binding; the step
  needs a `*Void — not fail — if:*` clause for a machine where Spotlight has been remapped or
  turned off.
