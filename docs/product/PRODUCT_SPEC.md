# Vocca: Product Spec

> **Scope of this document:** what the user *sees, hears, and does*. `ARCHITECTURE.md` owns how it works; this owns how it behaves. Where the two disagree about user-visible behavior, this wins.

The product is one floating widget and one hotkey. Almost everything below is about making those two things unambiguous, because in a tool that types into other people's apps, **ambiguity is the failure mode** — not ugliness, not missing features.

---

## 1. Design principles

1. **The widget always tells the truth about the microphone.** If audio is being captured, that is visible from across the room. There is no state where Vocca is listening and doesn't look like it.
2. **Never lose the user's words, and never make them wonder if you did.** Every failure resolves to visible, copyable text with a plain-language reason.
3. **Mode is never ambiguous.** Dictate and converse look different enough to tell apart at a glance, peripherally, mid-sentence.
4. **Silence is the default aesthetic.** The widget is small, quiet, and out of the way. It earns attention only when something needs it.
5. **Say what's happening in words a person uses.** "This looks like a password field — press ⌘C to paste it yourself" beats "AXError -25204."
6. **No dark patterns around privacy.** Egress is badged at the moment it happens. Nothing that sends text off-device is ever on by default, and no setting quietly re-enables it.

---

## 2. The widget

A small floating pill, always-on-top, positioned bottom-center by default and draggable to any edge. It does not take focus — ever. Taking focus would defeat the entire product, because the whole point is that the *other* app keeps its cursor.

### States

```
IDLE            ·  a thin dormant pill, ~30% opacity
                   fades further after 10s of no interaction
                   ┌──────────┐
                   │    ●     │
                   └──────────┘

OPENING         ·  expanded, target app named, NO waveform yet
                   ┌────────────────────────────┐
                   │  ◌  → Slack                │
                   └────────────────────────────┘
                   entered on key-down, within one frame.
                   Lasts as long as the microphone takes to open.

RECORDING       ·  expanded, live waveform, unmistakable accent color
                   ┌────────────────────────────┐
                   │  ▁▃▅█▆▃▁▂▅█▇▄▂  0:04       │
                   └────────────────────────────┘

TRANSCRIBING    ·  waveform freezes, indeterminate progress
                   ┌────────────────────────────┐
                   │  ▁▃▅█▆▃▁▂▅█▇▄▂  ○○○        │
                   └────────────────────────────┘

DELIVERED       ·  brief confirmation, then collapse to IDLE (~600 ms)
                   ┌────────────────────────────┐
                   │  ✓ → Slack                 │
                   └────────────────────────────┘

FAILSAFE        ·  persists until dismissed. THE critical state.
                   ┌────────────────────────────┐
                   │  the transcribed text sits │
                   │  here, fully selectable    │
                   │  ─────────────────────────  │
                   │  Couldn't type into Slack. │
                   │  ⌘C to copy    ⏎ retry   ✕ │
                   └────────────────────────────┘

CONVERSING      ·  visually distinct from RECORDING — see §5
                   ┌────────────────────────────┐
                   │  ◈  listening…             │
                   └────────────────────────────┘
```

**The target indicator matters.** In `RECORDING` and `DELIVERED`, the widget names where text is going (`→ Slack`). The user confirms the destination *before* speaking rather than discovering it after. This is a two-word label that prevents the single most embarrassing possible failure.

---

## 3. The dictation interaction, frame by frame

```
t=0      ⌥Space down
         · widget expands IDLE → OPENING within one frame (16 ms)
         · target app name appears
         · optional soft tick sound (default ON, defeatable)

t≈42…122ms  the microphone opens
         · OPENING → RECORDING
         · waveform begins HERE — this is the "it heard me" signal

t=0…n    user speaks
         · waveform tracks input level, not a canned animation.
           A fake waveform is a lie about whether the mic works.
         · elapsed timer after 3s
         · at 110s: subtle warning that the 120s ceiling approaches

t=n      ⌥Space up
         · waveform freezes, TRANSCRIBING
         · IF this takes <150 ms the user never sees this state — correct.
           The state exists for the slow path, not the fast one.

t=n+Δ    text lands in the app
         · widget shows ✓ → Slack for ~600 ms, collapses
         · optional soft confirmation sound

         OR, if the ladder is exhausted:
         · FAILSAFE, persistent, text selectable, reason stated
```

### Why there is an `OPENING` state, and what it costs the user

**Amended after C1 `audio-capture` measured the engine start.** This section previously said the
widget goes `IDLE → RECORDING` in one frame and that *"waveform begins immediately"*. Both are
unachievable and the measurement is why: `AVAudioEngine.start()` takes **42 ms** on a Mac's built-in
microphone array and **114 ms** on the analog headphone-jack input, plus ~8 ms before the first
realtime callback. There is no audio to draw for the first 50–122 ms after the press, so a waveform
shown then would be a canned animation — which this section already forbids, in the next paragraph,
for exactly the right reason.

`Scripts/measure-engine-start.sh` is the instrument; `CaptureStartTiming` in `VoccaCore` carries the
full table and the argument. The machine reports this state as `SessionEffect.opening`.

**The two honest options, and why this one.** The alternative is to enter `RECORDING` optimistically
on key-down and let the waveform lag. That keeps the 16 ms promise and breaks the more important
one — principle 1, *the widget always tells the truth about the microphone* — by showing a recording
indicator over a microphone that is not yet open. A distinct state keeps both: the widget still
reacts within one frame, and it does not claim to be recording until it is.

**What it does not fix.** The user who starts talking on the press still loses their opening
syllable; no widget state changes that. Reducing the number is C7's, and `prd.md:280` asked for this
measurement so that C7 would optimise against data. Until then, `OPENING` is what makes the loss
*visible* rather than silent — the user sees that Vocca has not started listening yet.

**Cancel:** `Esc` during `OPENING`, `RECORDING` or `TRANSCRIBING` aborts and discards. In `OPENING` the cancellation is held and applied the instant the session exists, so the press is never lost — but note that the microphone is still opened and then immediately closed, which briefly lights the system indicator. That cost is recorded on `SessionMachine.stopDeferredByTheOpening`. This must be discoverable — the widget shows `esc to cancel` after 2 seconds of recording. The user needs an obvious way out of a dictation they've thought better of.

---

## 4. The failsafe — the most important screen in the product

Everything else is convenience. This is the promise.

**Rules:**
- **It never auto-dismisses.** It persists until the user copies, retries, or explicitly closes it. A failsafe that vanishes on a timer is the same as losing the text.
- **The text is real, selectable text.** Not an image, not truncated, not "click to expand." Long transcripts scroll.
- **⌘C works while it's showing**, without the widget taking focus.
- **The reason is stated in plain language**, specific to the cause:

| Cause | Message |
|-------|---------|
| Secure Input | "This looks like a password field. Vocca won't type into it — press ⌘C to paste it yourself." |
| Ladder exhausted | "Couldn't type into Notion. Press ⌘C to paste it manually, or ⏎ to try again." |
| No focused field | "Nothing was focused. Click where you want this, then press ⏎." |
| Accessibility revoked mid-session | "Vocca's permission to type was turned off. [Open Settings] — or ⌘C to paste manually." Reachable only by revocation *during* a dictation: without Accessibility the hotkey never fires in the first place (§6). The words captured before the revocation are still delivered here, because they are still the user's. |

- **Retry (⏎) re-runs the ladder** against the *current* focus, so the fix for "wrong window was focused" is: click the right one, hit enter.
- **Crash recovery:** transcripts unresolved at crash time reappear in the failsafe on next launch, with a note about when they were captured.

---

## 5. Dual mode (P3) — dictate vs converse

The failure this prevents: saying something to Vocca that lands in a Slack message to your boss. The defense is redundancy — **four** simultaneous differences, so no single missed cue causes confusion.

| | Dictate | Converse |
|---|---|---|
| **Hotkey** | `⌥Space` | `⌥⇧Space` |
| **Shape** | rounded rectangle | pill with a distinct notch |
| **Color** | primary accent | clearly different hue (not a tint of the same one) |
| **Label** | `→ Slack` (target named) | `◈ Vocca` (no target — nothing will be typed) |
| **Sound** | tick | different, lower tick |

**Non-negotiables:**
- **No implicit mode switching, ever.** Vocca never infers from what you said which mode you meant. Inference here is a coin flip with an unacceptable downside.
- In converse mode the widget **never shows a target app name**, because nothing will be injected. The absence of `→ AppName` is itself a mode signal.
- Switching mode mid-session is impossible. Release, switch, start again.

Colors must be distinguishable under the common color-vision deficiencies — which is exactly why shape and label carry the signal too, and color is the *third* cue rather than the only one.

---

## 6. First run

Target: **installed to first successful dictation in under two minutes**, with no terminal, no config file, no account.

```
1. WELCOME          "Vocca types what you say, into any app.
                     Everything runs on your Mac."
                     [ Get started ]

2. PERMISSIONS      Requested one at a time, each with a plain reason:

                    Accessibility — "so ⌥Space works everywhere, and so
                                     Vocca can type into other apps"
                    Microphone    — "to hear you. Audio never leaves this Mac."

                    Each shows live ✓/✗ and a direct button to the exact
                    settings pane. No hunting.

                    Two, not three: the same Accessibility grant covers both
                    the hotkey and the typing, so there is one fewer scary
                    dialog than a dictation tool usually asks for.
                    (Input Monitoring would only cover a listen-only hotkey,
                    which can't swallow ⌥Space — see ARCHITECTURE.md §13.)

3. MODEL            "Downloading the speech model (≈600 MB, one time)"
                    Progress, resumable, cancellable.
                    ↳ "Skip for now" available — the system voice and
                       clipboard rung work without it, so a stalled
                       download never blocks the whole product.

4. TRY IT           A live text field in the window itself.
                    "Hold ⌥Space and say something."
                    Success here = onboarding complete.

5. DONE             "Vocca lives in your menu bar. Hold ⌥Space anywhere."
```

**Permission denial is never a dead end.** Every denial screen explains what still works without it and how to grant it later. Microphone denied → nothing can be heard, but the screen says exactly which toggle to flip and Vocca picks up where it left off. **Accessibility is the one genuinely fatal permission** — without it `⌥Space` can't be captured at all, so there is no way to start a dictation — and that's stated plainly rather than dressed up. Granting it afterwards requires a restart, so that screen offers a **[Restart Vocca]** button instead of leaving the user to wonder why the hotkey still does nothing.

---

## 7. Settings

One window, few tabs, everything on one screen per tab. No nested panels.

**General** — hotkeys (both modes, with conflict detection against system shortcuts), widget position, launch at login, sounds.

**Speech** — engine picker with the tradeoff stated honestly:

```
◉ Parakeet v3      Fastest. 25 European languages.        [ installed ]
○ Whisper turbo    Slower, broader language coverage.     [ download ]

  Model management: disk used, remove, re-download.
```

**Cleanup** — the three rungs, plainly labelled:

```
◉ Basic            Removes fillers, adds punctuation.  Instant, on-device.
○ Local AI         Better rewriting. Needs Ollama.     On-device.
○ Cloud (BYOK)     Your own API key.  ⚠️ Text leaves your Mac.

  [ Custom dictionary… ]   names, jargon, replacements
```

Selecting the cloud rung shows a one-time confirmation naming exactly what gets sent. Not a checkbox buried in a paragraph — a dialog the user has to read.

**Apps** — per-app injection strategy and overrides, with a plain-language health column (`typing directly` / `pasting` / `manual only`) and a "reset what Vocca learned" button.

**Privacy** — the honest page: what's stored, where, and a one-click "open the folder." Local metrics viewer. Recovery-journal retention control. A single prominent line: **"Vocca has made 0 network connections."** with a counter that is real.

---

## 8. The egress badge

Whenever an active provider has `requiresNetwork == true`, the widget carries a persistent marker:

```
┌────────────────────────────┐
│  ▁▃▅█▆▃▁▂▅█▇▄▂  0:04   ☁︎ │   ← always visible while recording
└────────────────────────────┘
```

- **Non-dismissable** while the cloud provider is active.
- Hovering states plainly: "Cleanup runs on api.example.com. Your text is sent there."
- It appears in the moment text would leave the machine, not only in a settings page nobody revisits.

This is the difference between a tool that is private and a tool that says it is.

---

## 9. Sound

Default on, individually defeatable, all sub-100 ms and quiet.

| Event | Sound |
|-------|-------|
| Recording start | soft tick |
| Delivered | softer, higher tick |
| Failsafe | distinct, non-alarming — noticeable, not startling |
| Converse start | lower tick, clearly different from dictate |

Sound is the cue that works when the widget is off-screen or the user is looking at their keyboard. It's an accessibility feature as much as a polish one.

---

## 10. Accessibility

The irony of an inaccessible accessibility-adjacent tool is not lost on us.

- Full VoiceOver labelling of every widget state, including live announcement of state transitions.
- Every mode/state distinction carries **shape and text**, never color alone.
- Respects Reduce Motion (waveform → static level meter) and Increase Contrast.
- Every action reachable by keyboard; the failsafe is fully keyboard-operable.
- Hotkeys fully rebindable, including to single keys or non-modifier combinations, for users who can't hold chords. **Hold-to-talk always has a toggle alternative** for users who can't hold a key — this is a real accessibility need, not a preference, and it's the one place the toggle model earns its keep.

---

## 11. Menu bar

Minimal by design: current state, mode toggle, "show last transcript" (re-opens the failsafe with the previous text — a small feature that saves a lot of retyping), Settings, Quit. Recording state is reflected in the menu bar icon as a second always-visible mic indicator.

---

## 12. Deliberately not in the product

- **No transcript history browser.** A searchable archive of everything you've ever said is a liability, not a feature, in a privacy-first tool. The recovery journal is bounded, purposeful, and purged.
- **No account, no login, no sync.** Nothing to sign into. Settings are a JSON file the user can sync themselves if they want to.
- **No usage analytics.** Metrics are local and inspectable. P5's install counting is opt-in and aggregate-only.
- **No floating "AI suggestions."** Vocca acts when asked. It does not volunteer.
- **No auto-updating models.** Model changes alter output; the user decides when that happens.

---

## 13. Open questions

1. **Widget default position.** Bottom-center is the safe default, but it collides with Dock-adjacent UI in some apps. May need per-app position memory.
2. **Long-transcript failsafe.** A 500-word transcript in a small pill needs a real scroll/expand treatment; the shape above assumes short ones.
3. **Converse-mode transcript surface.** Where the agent's replies render — inside the widget, or an expanded panel — is a genuine P3 design question that deserves its own pass with mockups.
4. **Onboarding without the model.** "Skip download" is right, but the try-it step needs a graceful story when no ASR model is present yet.
