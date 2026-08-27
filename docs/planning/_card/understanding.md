# Understanding — first-run + permissions onboarding (P0)

## What the work is really asking

Give a fresh Vocca install its first surface: a five-step first-run window
(WELCOME → PERMISSIONS → MODEL → TRY IT → DONE, `docs/product/PRODUCT_SPEC.md:207-244`)
so a cold install reaches "ready" in under 60 seconds (`docs/ROADMAP.md:80`) instead of
meeting the three silent gates (no Accessibility grant, no Microphone grant, and the
invisible `LSUIElement` launch — `CLAUDE.md:536`). This is the last unshipped P0
deliverable and the design pass's named highest-value unbuilt surface.

## What already exists (shipped, git-backed)

- The whole dictation loop is wired and tested (test floor 1114,
  `Scripts/test-with-floor.sh:1036`): tap → session machine → microphone → engine →
  ladder → failsafe → widget, driven end to end by the zero-network probe.
- The tap seam's one file (`Sources/VoccaHotkey/CGEventTapSource.swift:183-191`):
  `CGEvent.tapCreate` returning `nil` **is** the Accessibility permission check
  (`ARCHITECTURE.md:603`); the meaning is decided above the seam in `TapHealthPolicy`
  (`.permissionMissing`, `Sources/VoccaHotkey/TapHealthPolicy.swift:97-149`).
- Grant-change signalling already exists: `TapHealthTimer.accessibilityGrantChanged()`
  observes `com.apple.accessibility.api` (`Sources/VoccaHotkey/TapHealthTimer.swift:166-168`)
  — the route by which the PERMISSIONS step's live ✓/✗ and post-grant recovery work.
- The microphone's TCC story is implicit today: denial presents as
  `CaptureStart.unavailable`/`engineWouldNotStart`; there is **no authorization-status
  read anywhere in Sources** (no `AVCaptureDevice.authorizationStatus`, no
  `AVAudioApplication`). `NSMicrophoneUsageDescription` exists in `App/Info.plist:57-58`
  and the audio-input entitlement in `App/Vocca.entitlements`.
- The two system-settings pane paths the PERMISSIONS step's "direct button" needs already
  exist privately in `AppBootstrap.swift:441-446` (Accessibility, Microphone).
- The MODEL step's machinery is built but uncalled: `ModelDownloadSession` seam
  (`Sources/VoccaCore/ModelDownloadSession.swift`), `DownloadState` with the terminal
  `skipped` case (`Sources/VoccaUI/DownloadState.swift:21-51`), `DownloadWindow.present`
  (never called today), `StoreModelDownloadSession` constructed in `configure`
  (`AppBootstrap.swift:196-207`), `ModelStore.isPresent` + `DictationEngineResolver`
  readiness gate (`.modelUnavailable` refusal before the mic opens).
- The focus-taking window precedent: `SettingsWindow` — the one window allowed to take
  focus, `.regular` on `show()`, `.accessory` on `windowWillClose`
  (`Sources/VoccaUI/SettingsWindow.swift:47-76`). The onboarding window is the second
  such window (TRY IT needs a key field). The menu bar is built in `main()`, never
  `configure` (`AppBootstrap.swift:388-430`); onboarding launch must follow the same
  window-server discipline.
- The reducer+copy+thin-view pattern is the house style (MenuBar/EnginePicker/BadgeCopy,
  copy pinned byte-for-byte against PRODUCT_SPEC) — the PERMISSIONS flow and §6 copy
  follow it; the planning card names the `BadgeCopy` precedent explicitly.

## Design tensions to resolve (open questions for the PRD/interview)

1. **Mic request timing.** `ARCHITECTURE.md:593` says Microphone is requested at "first
   dictation attempt"; `PRODUCT_SPEC.md:216-220` and the C1 PRD M26
   (`audio-capture-hotkey/prd.md:201-203`) say it is requested in onboarding. The product
   spec is authoritative on user-visible behavior: onboard both permissions. The
   architecture table row is stale (already effectively overruled by M26).
2. **TRY IT without the model** (`PRODUCT_SPEC.md:349` open question 4). The pipeline
   refuses dictation with `.modelUnavailable` before the mic opens, so TRY IT cannot
   complete after "Skip for now". Needs a graceful story: e.g. TRY IT shows the honest
   model-unavailable state with a [Download now] affordance and is never a dead end —
   and the DONE step still completes.
3. **Completion flag.** Nothing is persisted today (no UserDefaults anywhere); the house
   idiom is JSON behind one-file FileManager seams, and the FileManager seam table is
   pinned at exactly three (`InjectionSeamBoundaryTests.swift:1288-1295`). Options: a
   fourth reviewed FileManager row, a first-of-its-kind UserDefaults seam, or folding the
   flag into an existing store. The read must be synchronous enough for `main()` to decide
   whether to show the window. Also: re-show policy (re-openable from the menu bar;
   re-shows until completed?).
4. **[Restart Vocca]** has no code precedent. Requires terminate + relaunch
   (`NSWorkspace`/`launchApplication` family — a new adapter surface that must be seam'd,
   or `NSApplication.terminate` + a relaunch path in `main`).
5. **TRY IT's target.** The transcript must land in the onboarding window's own text field,
   not the system-wide ladder. Decide: dedicated onboarding target that routes the
   pipeline's final transcript to the window's binding (real cycle, real engine) vs the
   system ladder pointed at Vocca itself.
6. **Time-to-ready target.** `ROADMAP.md:80` says under 60 s (P0); `PRODUCT_SPEC.md:209`
   and `ROADMAP.md:265` say under two minutes. P0's is the strict one — design for it.
7. **Stale R9** (`ROADMAP.md:308`) still names Input Monitoring; `ARCHITECTURE.md:597-599`
   corrected the doctrine (Accessibility covers hotkey + typing; Input Monitoring is
   listen-only and cannot swallow ⌥Space). The PRD's risk section must not repeat R9's
   stale text. Also note the §13 matrix tension on "never in a first-run wall of dialogs"
   vs the five-step flow — onboarding shows both permissions one at a time; that is not a
   wall.

## Scope guardrails

P0 scope discipline (`ROADMAP.md:74`): no cleanup, no VAD, no streaming, no TTS; settings
UI beyond permissions and one hotkey is out. The MODEL step and TRY IT step are the P0
path (they serve the loop), but the Cleanup/Speech settings surfaces are out. The
permission-status display in Settings (§7) is net-new and out unless cheap. No cloud,
local-only, macOS-only.