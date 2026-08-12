# Aspect spec — `audio-capture`

Parent PRD: [`../prd.md`](../prd.md) · Capability C1 · Phase P0
Depends on: `project-skeleton`, `session-lifecycle`, `hotkey-source` (all merged, `5c07884`)

---

## Problem slice

The session machine opens and closes a microphone it has never actually touched. `SessionAudioSource`
is driven by a test double in every one of the 324 tests. This aspect makes it real: an
`AVAudioEngine` graph that captures 16 kHz mono Float32 into a lock-free ring buffer, behind the seam
the machine already speaks to.

**User outcome:** holding the hotkey captures the user's voice. Releasing it hands over exactly what
was captured. Nothing else changes.

**Why it is the hardest aspect so far.** `hotkey-source` could not be tested by CI because
`CGEvent.tapCreate` needs a TCC grant. This one is worse: there is **no microphone on a runner**, and
**`AVAudioSinkNode` is unsupported in manual rendering mode**, so the realtime capture path has no
offline equivalent at all — not a permission problem, an architectural one. The seam must sit
*above* the node or that code is untestable forever.

---

## What this aspect inherits — decided, do not relitigate

| # | Constraint | Where it came from |
|---|---|---|
| 1 | **`AVAudioSinkNode`, not `installTap`.** `installTap`'s `bufferSize` has a documented range of [100, 400] ms and its block is not the realtime thread; the sink node's block **is**. A 100 ms floor would consume 25% of P2's 400 ms p50 budget. | `ARCHITECTURE.md` §7, corrected in `project-skeleton` |
| 2 | **The engine starts on demand and is never kept warm.** `AVAudioEngine.h:465-466`: any time a running engine has had input enabled, the mic-in-use indicator appears. A permanently-lit orange dot is the worst possible signal for this product. | `project-skeleton`, PRD M23 |
| 3 | **`endCapture()` must not return until the input device is released.** It is non-failable, so a conformance whose teardown fails has no way to say so — the machine goes `.idle`, the widget shows idle, and nothing ever looks again. **A conformance that can fail here must trap rather than return.** | `session-lifecycle` §5(f), on the seam itself |
| 4 | **The seam sits above the node.** `AVAudioSinkNode` cannot run in manual rendering mode, so anything below it is untestable. | `project-skeleton` |
| 5 | **The realtime thread does nothing but write samples.** No allocation, no locks, no logging, no ARC traffic, no `os_log` with dynamic args. | `ARCHITECTURE.md` §7 |
| 6 | **`VoccaAudio` becomes an adapter**: `dependencies: ["VoccaCore"]`, moved from `leafModules` to `adapterModules`. Two lines, now that the arrow is inverted. | `hotkey-source` |
| 7 | **`deinit` must not call an asserting entry point.** Use the non-asserting variant. This rule has now been needed three times; do not make it four. | `hotkey-source` final review |

---

## The first decision — RESOLVED in Phase 3

**The three-constraint tension on the tap callback was unresolved across two aspects. It is now
decided, on a measurement.**

The three constraints: the callback must return fast (a slow return earns
`kCGEventTapDisabledByTimeout`, which disables the tap **mid-session**); `AVAudioEngine.start()` is
slow; and the engine cannot be pre-warmed because that lights the microphone indicator permanently.

Both aspects wrote down the estimate they were working from — *"milliseconds"*. Measured:
**114 ms median / 119 ms p99 on the analog headphone-jack input, 42 ms median on the built-in
microphone array**, M4 Max, over 120 and 60 verified sessions. One to two orders of magnitude out,
with a 2.7× spread between devices on one machine.

**Decision: the capture start happens off the tap callback** — `CaptureStartTiming.whenTheOwnerAsks`.
The callback decides and returns; `ScheduledWatchdog` opens the microphone on a later turn of the
tap's own run loop. It rests on machinery `session-lifecycle` already built and tested for a slow
open (`isOpeningTheMicrophone`, the deferred-stop path); the hop widened that window from a few
instructions to ~114 ms, it did not add a rule.

The decision rests on two of the three grounds. The tap-timeout deadline is `prd.md` C1-G and is
still **[UNVERIFIED]**, so it is a real risk that cannot be quantified rather than an argument from
arithmetic. What carries it: the tap is a single serialization point in front of the whole keyboard,
so for 114 ms after every press whatever the user types next is held; and the main run loop stops,
overshooting the 150 ms watchdog poll that bounds the hot-mic window by 76%.

Full reasoning and both tables: `CaptureStartTiming` in `VoccaCore`, and `plan_20260806.md`
§"Result, written after Phase 3". Instrument: `Scripts/measure-engine-start.sh`.

---

## In scope

- `AVAudioEngine` + `AVAudioSinkNode` capture graph, connected at the input node's **own** output
  format (the sink node does not convert).
- A **single-producer/single-consumer lock-free ring buffer**, preallocated, using
  `Synchronization.Atomic` with explicit acquire/release ordering. This is the **one** type in the
  codebase permitted `@unchecked Sendable`, and it must carry a comment stating the invariant the
  compiler cannot verify.
- `AVAudioConverter` to 16 kHz mono Float32, running **on the consumer side, off the realtime
  thread** — it allocates.
- `SessionAudioSource` conformance satisfying constraint 3.
- Handling `AVAudioEngineConfigurationChangeNotification`: a device switch invalidates the graph. If
  it fires mid-session, end the session via the existing trigger and **keep the audio**.
- The engine-start latency measurement the PRD requires.

## Out of scope

- ASR (C2). The buffer is handed over; nothing transcribes it.
- Permissions UI, onboarding, the widget.
- Bluetooth/HFP device selection beyond noting what it does to the format.
- **HFP engine-start latency.** Phase 3 measured `AVAudioEngine.start()` on three inputs and found a
  2.7× spread between them (42 ms built-in array, 114 ms headphone-jack input). No HFP-capable device
  was reachable on the measuring machine, and HFP is the configuration most likely to be *worse* than
  any of those. It is out of scope here and it is **unmeasured, not assumed fine** —
  `./Scripts/measure-engine-start.sh warm --device "<name>"` is one command for whoever has the
  hardware.

---

## Acceptance criteria (tests written first)

| # | Criterion | Testable headlessly? |
|---|---|---|
| A1 | Ring buffer: SPSC correctness, wraparound, overrun policy, capacity bounds — two real threads under TSan, thousands of iterations | ✅ |
| A2 | `AVAudioConverter` resampling: a synthetic 48 kHz sine converts to 16 kHz mono with the expected length and frequency | ✅ no device needed |
| A3 | The realtime block allocates nothing — asserted by construction and by a source lint over the block's body | ✅ lint |
| A4 | `endCapture()` releases the device before returning; a conformance that cannot, traps | ⚠️ partly |
| A5 | A configuration change mid-session ends the session **with** the audio | ✅ over the seam |
| A6 | The engine is not running between sessions — the mic indicator is dark when idle | ❌ manual |
| A7 | Engine-start latency, measured and recorded | ❌ manual, but **required** — **done in Phase 3**: `Scripts/measure-engine-start.sh`, numbers on `CaptureStartTiming` and in `plan_20260806.md`. HFP remains unmeasured |
| A8 | 16 kHz mono Float32 at the seam boundary; a sample-rate or channel-count regression fails loudly | ✅ |

**A6 and A7 go in `SMOKE_CHECKLIST.md`** with pass criteria tighter than the failures they guard —
the rule `hotkey-source` earned when a looser one would have accepted a broken poll.

---

## Open questions

1. Ring buffer capacity. The 120 s ceiling at 48 kHz Float32 mono is ~23 MB preallocated. Acceptable,
   or is the ceiling the lever? (PRD open question 2, still unanswered.)
2. What happens when the engine fails to start — `CaptureStart.unavailable` exists and the machine
   handles it, but what does the user see?
3. ~~Does `prepare()` after every stop measurably reduce start latency, and does it cost anything
   while idle?~~ **Answered in Phase 3, and the answer is negative.** Measured
   (`Scripts/measure-engine-start.sh prepare-matrix`, 30 rows per cell, `start()` median): with any
   realistic gap between sessions it saves **7.6 ms** (120.7 → 113.1 ms at a 1 s gap) and **costs
   ~55 ms of idle CPU per session** to do it. Back to back it saves 49 ms, but back to back is not a
   user pattern, and whatever it warms is torn down within one second. On the built-in microphone
   array `prepare()` costs 11.8 ms rather than 55 — a materially different trade, so the verdict is
   device-dependent and the number must be re-taken per device. `prd.md` M23 mandates it as a
   must-have; Phase 4 implements it as written and flags it, or the PRD is amended. See
   `plan_20260806.md` §"Result, written after Phase 3".
