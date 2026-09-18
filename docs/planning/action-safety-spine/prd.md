# PRD — `action-safety-spine`

> **C13 slice 1 of N · Phase P4 · machinery-only, no user-visible surface.**
> Ships the safety spine of Actions/MCP over a stub provider. **No MCP wire, no
> transport, no intent layer, no real tool execution, no `AppBootstrap` wiring.**
>
> Source: `docs/planning/_card/issue.md` (brief), `docs/planning/_card/understanding.md`
> (Phase 2 dig). Founder decisions settled 2026-09-19: PENDING seam row with a recorded
> reason; machinery-only; transport prohibition lint in scope; blind spot recorded as a
> deviation. **The audit-log payload policy was delegated to the implementer and is marked
> as such in §5 — it is not a founder decision.**

---

## 1. Problem Statement

C13 is the wedge — the capability that turns Vocca from a transcription front-end into
something that *does things*. It is also, by a wide margin, the capability with the largest
blast radius. `ROADMAP.md:307` states it plainly:

```
| R8 | **Actions do something destructive** the user didn't intend | P4 | Med | **Fatal (trust)** |
     Confirmation for destructive/outward-facing actions; dry-run mode; local audit log;
     zero-unintended-actions gate |
```

Today the capability is entirely a paper reservation:
`grep -rn "ActionProvider\|VoccaActions\|MCP" Sources/ Package.swift` returns **zero hits**.
The docs commit to the shape twice — `CLAUDE.md:327` ("gated on confirmation + a local
audit log") and `README.md:205` — and `ARCHITECTURE.md` reserves both the module
(`VoccaActions/  # P4 — ActionProvider, MCP client`) and the seam row
(`| Actions | ActionProvider | MCPProvider, ShellProvider | No |`).

**Two things make "gate first, capability second" the correct order rather than a
preference:**

**(a) A confirmation gate retrofitted onto a working client is not a gate.** C13's own entry
says the capability "ships gated on safety rather than on capability," and its acceptance
demands that a destructive action without confirmation be *structurally impossible* —
asserted by attempting the call and requiring refusal, not by observing that no prompt
appeared. That property is cheap to build when nothing can execute yet and expensive to
retrofit once something can.

**(b) The Phase 2 dig found a structural hazard that arrives with the transport, not with
the gate.** Vocca's permanent release blocker is a zero-network CI test driven by a `dyld`
interposer. It counts **loopback as NETWORK on purpose** (`interposer.c:69-73`), so an MCP
server on `127.0.0.1` is a violation, not a local convenience — stdio is the only transport
the invariant permits. But a stdio server is a *spawned child*, and the interposer goes
**blind** through almost every realistic spawn shape (measured, §6/D2). The failure mode is
not a red test; it is a **green test while a child egresses** — a false green in the
blocker. Building the spine first lets the structural guard land *before* the hazard exists.

**Who has the problem.** The founder, who will be the first person to point this at a real
tool; and the reviewer or contributor who must be able to verify — from the tests, not from
prose — that the gate cannot be bypassed.

---

## 2. Goals & Success Metrics

This unit is **machinery**. Its metrics are structural assertions in CI, not measurements.

| # | Success criterion | How it is judged |
|---|---|---|
| G1 | A destructive action without confirmation is **refused**, asserted by attempting it | Test, C13 acceptance leg 1 |
| G2 | Dry-run produces **zero** side effects, asserted by a stub that **fails the test if invoked** | Test, C13 acceptance leg 2 |
| G3 | Every executed action is reconstructible from the audit log | Test, C13 acceptance leg 3 |
| G4 | A disabled tool is **never callable** — declined before any provider call | Test, C13 acceptance leg 4 |
| G5 | No production file in `VoccaActions` names a transport or a subprocess | Prohibition lint, both directions + planted control |
| G6 | The G5 digest pin is **untouched** — all three dictation digests unchanged | Existing pin test stays green with no re-anchor |
| G7 | The floor ratchets 2475 → N in its own commit | `Scripts/test-with-floor.sh` |

### What this unit explicitly does NOT achieve

- **No gate passes.** This is the **fifth unit built ahead of the uncleared P2/P3 gates**
  under the recorded posture. It does not meet the P4 gate.
- **No "zero unintended actions" number exists**, and none may be quoted — nothing executes,
  so there is nothing to count. R8 is *mitigated in structure*, not *measured*.
- **The seam is not proven.** Guardrail 7 ("a seam with one implementation is not a seam;
  it's an assertion") is **not met** by this unit. See §6/D3.
- Nothing is measured on a real machine. No SMOKE row in this unit produces a percentage.

---

## 3. Personas & Scenarios

Vocca's ICP is the Mac user who lives in dictation all day and won't send audio to a cloud.
For this unit two narrower readers matter more:

- **The founder, arming the first real tool (later slice).** Needs to know that the thing
  standing between a voice command and an irreversible action is a type, not a habit.
- **The reviewer / contributor adding `MCPProvider` (later slice).** Must hit the
  prohibition lint the moment they reach for a transport, and must find the blind-spot
  deviation recorded rather than rediscover it by shipping a false green.

---

## 4. Requirements

### Must-have

| # | Requirement |
|---|---|
| M1 | `ActionProvider` protocol in `VoccaCore/Actions/`, **Foundation-free** (`CoreBoundaryTests.swift:116` enforces an empty import allow-list — no `Data`, `URL`, or `Date`) |
| M2 | The plain-data vocabulary: an action descriptor carrying provider id, tool id, blast radius, and the **concrete summary sentence** |
| M3 | `BlastRadius` — `readOnly` / `destructive` / `outwardFacing`. Read-only may run directly; the other two require confirmation |
| M4 | **The structural refusal.** An unconfirmed destructive action cannot reach invocation — enforced by a confirmation token whose initializer only the gate can call (the epoch-minted `ModeSession` precedent), so bypass is a compile error or a refusal, never a convention |
| M4a | **Confirmation is per-invocation.** No "don't ask me again", no per-tool or per-session carry-over, in this slice. See §6 — this is the door R8 walks through |
| M5 | **Dry-run.** Preview renders what would happen and performs **zero side effects**: `describe` may be called, `invoke` is called **zero** times (see M5a) |
| M5a | **The seam separates `describe` from `invoke`.** `describe(invocation) -> Summary` is pure, side-effect-free and is what renders the concrete sentence; `invoke(confirmed:)` is the only operation that acts. Without this split, "dry-run never touches the provider" and "the confirmation states concretely what will happen" are contradictory requirements |
| M6 | **Append-only audit log** in `VoccaActions/` — one file per event, zero-padded 8-digit ordinal, `.tmp` mid-commit, monotonic `Duration` instant (the `FileSystemJournalStore` shape) |
| M7 | **Per-tool enablement, default off.** A disabled tool is declined **before any provider call** — never called-then-discarded (the `ContextConsentGate` never-read precedent). **In-memory in this slice**; see §6/N1 |
| M8 | **Transport prohibition lint**: no file in `VoccaActions` may name `URLSession`, `NW*`, `Network`, or `Process`. Both directions, planted control, comment-strip control, non-empty assertions |
| M9 | `NullActionProvider` — the shipped default. Exposes zero tools, refuses everything |
| M10 | **A test-only executing stub provider.** Without one, G2 and G3 assert over an empty domain and pass vacuously — see §6/C1 |

### Should-have

- The audit log is clearable, and bounded by a cap with oldest-first eviction by ordinal.
- Permit-table rows for the new store's `FileManager` surface
  (`InjectionSeamBoundaryTests.swift:1186` and `:1201`).

### Out of scope — explicitly

MCP client; **any transport of any kind**; `ShellProvider`; the intent layer (utterance →
tool call); reply-text rendering; **any user-visible surface** (no widget state, no Settings
tab, no menu row); `AppBootstrap` wiring and therefore any G5 pin re-anchor; real tool
execution; coding-agent handoff; any dependency addition.

---

## 5. Data Model — the audit entry

> **⚠️ This section is the implementer's call, delegated by the founder on 2026-09-19. It is
> the one substantive design decision in this PRD that was not founder-made, and it is
> flagged here so it can be overridden cheaply.**

`ActionAuditEntry` persists:

| Field | Why |
|---|---|
| `id: Int` | The write ordinal — eviction key, and the reason lexicographic order is numeric |
| `instantSeconds` / `instantAttoseconds` | The monotonic `Duration` components. **Never a wall clock** — `JournalEntry`'s stated reason: a wall-clock reading lies across an NTP step or a DST change. Independently forced by `VoccaCore`'s ban on `Foundation.Date` |
| `providerID`, `toolID` | Which provider, which tool |
| `blastRadius` | The classification the gate applied |
| `decision` | `.autoRanReadOnly` / `.confirmed` / `.refused` / `.dryRun` |
| `outcome` | `.succeeded` / `.failed(reasonKey)` / `.notInvoked` |
| `summary: String` | **The exact concrete sentence the gate rendered** — bounded to 1 KB UTF-8 |

**Raw tool arguments are NOT persisted.** The reasoning:

1. C13 requires the confirmation to state *"what will happen before it happens, in concrete
   terms ('send this message to #general') rather than abstract ones ('execute
   slack_post')"*. That rendered sentence **is** the concrete record — it reconstructs the
   decision the user actually faced, which is the trust-relevant fact when R8 fires.
2. Raw arguments are unbounded, arbitrary user text. The `README.md:39` BYOK precedent —
   *"a confirmation naming exactly what gets sent"* — is about the human-readable naming,
   not a wire dump.
3. Bounds have precedent: the `ContextGrantGate` owns a ≤4 KB payload bound in exactly one
   place; the consent store caps at 512 entries; the journal evicts by ordinal.

**The honest tradeoff, stated rather than buried:** if you later need to prove *exactly*
which argument value was transmitted, the summary is a **rendering, not the raw value** —
this is a deliberate loss of fidelity bought for a bounded, human-reviewable file. It is
cheaply reversible: the entry is versioned, and adding a bounded raw-argument field later is
an additive change that **fails the key-set byte-pin loudly on the day it is added**, which
is exactly what that pin is for.

**The entry gets its own byte-level pin** (the `PersistentConsentStoreTests.swift:469`
pattern): exact key-set equality, and no `HH:MM` / ISO-8601 / Zulu / epoch-shaped values —
while permitting `summary`, since a summary with no content would defeat the log's purpose.

---

## 6. Risks, Deviations & Open Questions

### Recorded deviations

**D2 — the zero-network invariant is blind through a spawned child.**
Measured empirically in the Phase 2 dig, not read from docs. `DYLD_INSERT_LIBRARIES` is
inherited, but a *restricted* child (Apple platform binary, or hardened-runtime lacking
`com.apple.security.cs.allow-dyld-environment-variables`) ignores it **and purges `DYLD_*`
from the environment it passes on** — laundering the insertion for the whole descendant
tree. Measured: direct absolute-path spawn of a locally built binary → **SEEN**; `node`
carrying the dyld-env entitlement → **SEEN**; `/usr/bin/python3`, `/usr/bin/curl`,
`/usr/bin/tar`, any `/bin/sh -c` wrapper, and `#!/usr/bin/env node` → **BLIND**.

Consequence: the day a stdio MCP server is spawned, the permanent release blocker **stops
covering the actions path while still reporting green**. This unit cannot fix that. It
records it, and ships M8 so that reaching for a transport is a reviewed edit.

**D3 — the seam ships PENDING, guardrail 7 unmet.**
`ARCHITECTURE.md`'s row names `MCPProvider` and `ShellProvider`; neither is built, and
`ShellProvider` is the highest-blast-radius component in the roadmap — building it in slice
1 would contradict this unit's entire premise. The row therefore ships as **PENDING with a
reason**, the `ParakeetEOU` Branch B precedent. No test enforces the two-implementation
doctrine (confirmed in the dig), so this is an honesty obligation, not a CI fight.
`NullActionProvider` is a shipped default, **not** a second implementation, and must not be
described as one.

### Risks

| Risk | Mitigation |
|---|---|
| **R8** (roadmap) — destructive action the user didn't intend | This unit is the structural half of its mitigation. Unmeasured by construction |
| The confirmation token is forgeable, making M4 decorative | The token's initializer is unreachable outside the gate; a test attempts construction and the bypass path and requires refusal |
| The prohibition lint passes vacuously once files move | Both-directions assertion + planted control + non-empty file-list assertion, per `ModelDownloaderSeamTests.swift:190` |
| The audit log grows unbounded | Cap + oldest-first ordinal eviction |

### Open questions

- **Is `ShellProvider` still the right second implementation?** It is the highest-blast-radius
  thing in the roadmap. A read-only introspection provider may be the safer pair for proving
  the seam. Deferred to the MCP slice; the `ARCHITECTURE.md` row is not amended here.
- **Blast radius may not be ours to assign.** MCP tools carry their own annotations
  (`readOnlyHint` and friends). Our classification may need to *derive* from a provider's
  declaration rather than be assigned locally — and a provider's self-declaration is not
  trustworthy input for a safety gate. This is unresolved and belongs to the MCP slice.

### Self-critique (Phase 4) — corrections already applied

**C1 🔴 — G2 and G3 were vacuous as first drafted.** `NullActionProvider` exposes zero
tools and nothing else executes, so "every executed action is reconstructible" and "dry-run
invokes the provider zero times" both asserted over an **empty domain** and would have
passed while proving nothing — the failure this repo names explicitly elsewhere ("the gate
that cannot fail proves nothing"; the planted 2-miss corpus that must fail loudly).
**Fixed by M10:** a test-only executing stub gives both assertions a non-empty domain, and
the dry-run stub fails the test *if invoked*, per C13's own wording.

**C2 🔴 — `describe` vs `invoke` was a latent contradiction.** M5 demanded dry-run never
touch the provider; M2/M4 demanded the confirmation state concretely what will happen
("send this message to #general"). Only something that understands the tool can render that
sentence. As drafted, those requirements could not both hold. **Fixed by M5a:** the seam
splits a pure `describe` from the acting `invoke`, and "zero side effects" is scoped to
`invoke`. Had this survived to implementation it would have surfaced as a redesign mid-unit.

**C3 🔴 — M7's persistence was unspecified**, which silently changed the unit's size: a
persisted enablement set implies a second store, a file, a byte-pin and permit rows.
**Resolved as in-memory for this slice** (N1), because no tools exist to enable yet and
persisting an empty set is premature. Recorded as a named follow-on rather than left open.

**C4 🟡 — `destructive` vs `outwardFacing` is currently decorative.** Both require
confirmation and behave identically, so the distinction earns nothing today. Kept because
the audit entry records it and the two diverge the moment a policy needs "outward-facing
always confirms even if the user disabled prompts" — but flagged: if the MCP slice does not
give them different behavior, collapse them.

**C5 🟡 — no SMOKE rows.** Every prior unit shipped founder-run rows. This one ships
**none**, and that is deliberate rather than an omission: nothing executes, so there is no
real-machine observation to make. The `record` aspect states this explicitly instead of
reserving numbers from 144 that no one can run.

**C6 🟡 — no effort signal.** Five aspects, test-first, one floor ratchet. No estimate is
given and none is claimed.

### Named follow-ons

**N2 — bind an approval to the invocation and sentence it was given for.**
`confirmation-gate` shipped `ActionApproval` as a payload-free public enum defaulting to
`.withheld`. Two properties are structural and good: the approval is an **argument**, so it
lives for exactly one call and there is nowhere to remember it — *"don't ask me again" has no
representation in the type*, which answers §8 for this slice — and a caller that forgot to ask
has, correctly, not asked.

The irreducible boundary, recorded rather than hidden: **`.granted` is publicly constructible,
so the type asserts that a human approved; it cannot verify it.** No type can. The structural
guarantee this slice actually delivers is narrower and should be stated as such — *there is
exactly one path to `invoke`, it runs through the gate, and the gate applies the policy*. Whether
a human really saw the sentence is a fact the UI layer asserts when it constructs `.granted`.

The tightening, when a surface exists: bind the approval to the exact invocation **and the exact
sentence the person was shown**, so an approval cannot be replayed against a different action
than the one it was given for. This is the same class as the provider-asserted radius (`d1db69d`)
— an unavoidable trust dependency made visible and bounded rather than pretended away.

**N1 — persisted per-tool enablement.** In-memory in this slice; the persisted store
(file, tolerant decode, byte-pin, permit rows, the `PersistentConsentStore` shape) lands
with the slice that introduces real tools to enable.

### The challenge question this PRD is obliged to keep

**Is the safety spine genuinely useful shipped alone, or is it scaffolding that gets
rewritten when the first real provider lands?**

The case for shipping it now: the gate's contract — blast radius, a confirmation token,
dry-run, an audit record — is provider-independent, and retrofitting "structurally
impossible" onto a working client is the kind of change that quietly becomes "prompted by
convention." The case against, stated honestly: a stub-only seam can encode assumptions a
real transport breaks, and the open question above is a live example — if blast radius turns
out to be provider-declared rather than locally assigned, M3 and part of M4 get reworked.
**The risk is real and is accepted, not dismissed.** The mitigation is that the vocabulary
stays plain data with no transport concepts in it, so a rework is a change of *classifier*,
not of *architecture*.

---

## 7. Aspect decomposition

| Aspect | Boundary |
|---|---|
| `action-seam` | `VoccaCore/Actions/`: the protocol, the plain-data vocabulary, `BlastRadius`, `NullActionProvider`. Foundation-free |
| `confirmation-gate` | The structural refusal (M4), the read-only direct path, dry-run (M5), per-tool enablement (M7) |
| `audit-log` | The `VoccaActions` module + the append-only store, its byte-pin, permit rows |
| `transport-prohibition` | The lint (M8) and its planted/comment-strip controls |
| `record` | Docs sync (`ARCHITECTURE.md` reservation → SHIPPED, seam row PENDING), STATUS head entry, `CLAUDE.md` paragraph, floor ratchet, the D2/D3 deviations and N1. **No SMOKE rows** — see §6/C5 |

---

## 8. The question to answer before greenlighting

> **When the user says yes once, what exactly did they say yes to?**

This PRD sets M4a — confirmation is strictly per-invocation, with no "don't ask me again."
That is the safe answer, and it is also the answer users abandon first. Every confirmation
gate that has ever failed in production failed through this door: the prompt becomes
frequent, the user asks for a way to silence it, and the silencing mechanism becomes the
bypass that R8 ("Fatal (trust)") describes.

So the question is not whether per-invocation is right for slice 1 — it is. The question is
**what the eventual escape valve looks like**, because it will be demanded, and designing it
after the prompts get annoying is how it ends up as a checkbox that disables the gate
wholesale. Plausible shapes worth deciding early: time-boxed scoping ("this tool, next 10
minutes"), a blast-radius floor that can never be silenced (outward-facing always confirms),
or per-tool trust that decays. **Nothing here is decided, and this unit does not need it
decided — but the MCP slice must not be the first place it is thought about.**
