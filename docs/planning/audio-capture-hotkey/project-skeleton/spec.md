# Aspect spec — `project-skeleton`

Parent PRD: [`../prd.md`](../prd.md) · Capability C1 · Phase P0, week 1

---

## Problem slice

There is no code in this repository. Before any capture logic can be written or tested, there
must be a Swift 6 project that (a) compiles under strict concurrency, (b) runs tests on a plain
CI runner with no permissions and no network, and (c) can be assembled into a **signed `.app`
bundle** — because TCC identity is bound to bundle ID + code signature, and a bare SPM
executable cannot durably hold the Accessibility and Microphone grants C1 depends on.

**User outcome:** none directly. This aspect exists so every later aspect can be built
test-first and so R9 (`ROADMAP.md:308` — notarization friction) is retired in week 1 rather
than discovered at ship time.

---

## In scope

### Package structure
- SPM package with targets per `ARCHITECTURE.md:51-90`, plus **`VoccaHotkey`** (new — the
  architecture has no home for the event tap).
- Swift 6 language mode with **strict concurrency on from the first commit**
  (`ARCHITECTURE.md:43` — retrofitting it onto an actor graph + realtime thread is materially
  harder than starting with it).
- Dependency graph strictly acyclic, pointing inward: `VoccaUI → VoccaCore → {leaf modules}`.
  Leaf modules never import `VoccaCore` and never import each other.
- Minimum deployment target **macOS 15** — required for `Synchronization.Atomic`, which the
  lock-free ring buffer in `audio-capture` depends on.

### App bundle
- Thin **Xcode app target** consuming the local SPM package. It owns only: `Info.plist`,
  entitlements, signing settings, and bundle assembly. **No logic.**
- `Info.plist`: `NSMicrophoneUsageDescription`, `LSUIElement = true`, stable
  `CFBundleIdentifier`, `LSMinimumSystemVersion`.
- Entitlements: **`com.apple.security.device.audio-input`**. Explicitly **not**
  `com.apple.security.app-sandbox`. Explicitly **not**
  `com.apple.security.cs.disable-library-validation`.
- Hardened runtime enabled.
- App launches as `.accessory` (no Dock icon) showing nothing.

### Signing
- A **stable local development signing identity**, documented in the README, never ad-hoc.
  Re-signing creates a new code identity and TCC grants silently stop applying — and the
  symptom is not an error, it's a tap that looks healthy and never fires.
- A signing/notarization script (`codesign --options runtime --timestamp` → `notarytool
  submit --wait` → `stapler staple`), wired but **credential-gated** (see Open Questions).

### CI and the privacy invariant
- `swift test` runs green on a plain runner: no Xcode project required, no TCC grants, no
  microphone, no network.
- **Zero-network test** (`CLAUDE.md:108-110`, a permanent release blocker): a network
  interposer asserts zero outbound connections across the default path. At this aspect it
  trivially passes — that is the point. It guards every later capability from commit one.

### Licence
- Apache-2.0 `LICENSE` file and source headers (`CLAUDE.md`, `ROADMAP.md:49`).

---

## Out of scope

- Any hotkey, audio, widget, or permission logic. Empty target stubs only.
- Actual notarization **submission** if Developer ID credentials are unavailable — the script
  ships and is exercised up to the credential boundary.
- CI hosted-runner configuration for anything requiring TCC. It is impossible: `swift test`
  covers everything above the seams, and that is the design constraint, not a limitation.

---

## Acceptance criteria (tests written first)

| # | Criterion | How verified |
|---|---|---|
| A1 | `swift test` passes on a clean checkout | CI, plain runner |
| A2 | Package builds under Swift 6 strict concurrency with **zero warnings** | `swift build -Xswiftc -strict-concurrency=complete` |
| A3 | **Zero outbound network connections** on the default path | Network interposer test — release blocker |
| A4 | Module dependency graph is acyclic and inward-pointing | Test asserting no leaf module imports `VoccaCore` or another leaf |
| A5 | App bundle builds, is signed, and passes `codesign --verify --strict` | Build script |
| A6 | Launched app is `.accessory` — no Dock icon, no menu bar, no window | Manual smoke, one line in the checklist |
| A7 | `Info.plist` carries `NSMicrophoneUsageDescription` and `LSUIElement` | Test reading the built bundle's plist |
| A8 | Entitlements include `audio-input` and **exclude** `app-sandbox` | Test parsing `codesign -d --entitlements` |
| A9 | Apache-2.0 `LICENSE` present; all sources carry the header | Lint test over `Sources/` |

A3, A7 and A8 are the load-bearing ones. A7/A8 catch the silent-denial failure mode where a
missing entitlement means the microphone prompt **never appears** and the app just gets no audio.

---

## Dependencies and sequencing

**Depends on:** nothing. First aspect.
**Blocks:** all six others.

Keep this aspect deliberately thin. Its risk is scope creep — every hour here is an hour not
spent on `session-lifecycle`, which is the aspect that can actually lose the user's words
(PRD §8 G1).

---

## Open questions / risks

1. **🔴 Developer ID credentials.** Notarization requires an Apple Developer Program membership
   ($99/yr) and a Developer ID Application certificate. `CLAUDE.md` states the founder has "no
   dependency on proprietary data or credentials today" — a Developer ID is exactly such a
   dependency. **If it isn't available yet, R9 cannot actually be retired in week 1.** Fallback:
   ship the script, sign locally with a stable self-signed identity (sufficient for TCC grants
   to persist across debug builds), and gate the notarization step behind credential presence.
   This needs an answer before A5 is claimed complete.
2. Does `VoccaHotkey` get added to `ARCHITECTURE.md:51-90` here, or in the `doc-amendments`
   aspect? Recommend here — the directory listing and the doc should not disagree at any commit.
3. Xcode project files are notoriously merge-hostile. With a solo founder this is tolerable;
   worth noting before a second contributor arrives.
