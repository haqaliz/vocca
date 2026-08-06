// Copyright 2026 The Vocca Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// The measurement harness for `hotkey-source` phase 5.
//
// It is NOT a package target, and that is deliberate rather than convenient. Anything under
// `Sources/` or named in `Package.swift` is inside the zero-network coverage guard, which requires
// `VoccaNetworkProbe` to drive it — and driving a GUI measurement tool from the probe that asserts
// Vocca makes no network calls would be nonsense. It is also outside the H7 seam lint, which is why
// it may name `CFRunLoop*` where `Sources/` may not.
//
// Build and run it with `Scripts/measure-timers.sh`. It links the real `VoccaHotkey`, so the timer
// under test is the shipped `MainRunLoopTimer` and not a copy of it.
//
// Two measurements, one per subcommand:
//
//   runloop   Does a timer keep firing while the run loop is in event-tracking mode — which is the
//             mode a window drag and an open menu run in? Compares `.common` (the shipped
//             registration) against `.default` (the mutant) under the identical gesture.
//
//   menu      The same question under a REAL AppKit tracking session — `NSMenu.popUp` — with no
//             run-loop mode named anywhere in the measurement. It closes the "is entering the mode
//             directly a faithful proxy" gap that the `runloop` form has to assume.
//
//   appnap    Does App Nap throttle an LSUIElement app's timers, and does
//             `ProcessInfo.beginActivity(...)` change it?
//
// EVERY MEASUREMENT PRINTS THE PROCESS'S DARWIN SUPPRESSION STATE, and that is not decoration.
// The first version of this file measured App Nap without ever checking whether the process was in
// the state App Nap applies — so "1999 of 2000 fires" was a correct measurement of an unthrottled
// process and no evidence at all about a throttled one. See `darwinSuppressionState()`. The rule it
// cost: **a negative result about a state must verify the state was entered.**

import AppKit
import Darwin
import Foundation
import VoccaCore
import VoccaHotkey

// MARK: - Is this process actually suppressed?

/// Whether the kernel has this task in the **darwin-background / suppressed** state — the answer, or
/// why there is not one.
///
/// An enum rather than an `Int32` because the two cases genuinely collide: `getpriority` returns a
/// *priority*, so `-1` is a legitimate value, and the only way to detect failure is `errno`. A
/// function that returned `-1` for the error would hand a caller a number it could not tell apart
/// from an answer — in the one reading this whole measurement's credibility rests on.
///
/// The `errno` travels **with** the failure rather than being read at print time. Reading it later
/// reports whatever the most recent intervening call left there, which is a diagnostic that is wrong
/// precisely when it is needed.
enum DarwinSuppression {
    case notSuppressed
    case suppressed
    /// A priority that is neither 0 nor `PRIO_DARWIN_BG`. Unexpected rather than impossible.
    case other(Int32)
    case unreadable(errno: Int32)
}

/// Read the state, now.
///
/// `getpriority(PRIO_DARWIN_PROCESS, 0)` returns `PRIO_DARWIN_BG` when the task is suppressed and `0`
/// when it is not. It needs no privileges and no external tool, which matters: the first version of
/// this file reached for `taskinfo`, found it needs root, and concluded the state was unobservable.
/// It is not. Verified in both directions on this machine — `0` normally, `1` under `taskpolicy -b`.
///
/// **This is the control for the entire App Nap measurement.** Fire counts taken without it cannot
/// distinguish "the mechanism does not throttle" from "this process was never throttled", and those
/// are completely different findings.
func darwinSuppressionState() -> DarwinSuppression {
    // Cleared first, as `getpriority(2)` requires: the call does not set `errno` on success, so a
    // stale value from any earlier call would otherwise be read as this one's failure.
    errno = 0
    let value = getpriority(Int32(PRIO_DARWIN_PROCESS), 0)
    if value == -1 && errno != 0 { return .unreadable(errno: errno) }
    switch value {
    case 0: return .notSuppressed
    case 1: return .suppressed
    default: return .other(value)
    }
}

func describeSuppression(_ state: DarwinSuppression) -> String {
    switch state {
    case .notSuppressed: return "0 (NOT suppressed)"
    case .suppressed: return "1 (SUPPRESSED — darwin background)"
    case .other(let value): return "\(value) (unexpected priority)"
    case .unreadable(let code): return "UNREADABLE (errno \(code)) — treat every number below as void"
    }
}

extension DarwinSuppression: Hashable {}

/// Ordering for the per-fire histogram, so the output is stable run to run.
extension DarwinSuppression: Comparable {
    private var sortKey: Int32 {
        switch self {
        case .notSuppressed: return 0
        case .suppressed: return 1
        case .other(let value): return value
        case .unreadable: return Int32.max
        }
    }

    static func < (lhs: DarwinSuppression, rhs: DarwinSuppression) -> Bool {
        lhs.sortKey < rhs.sortKey
    }
}

// MARK: - The ledger

/// Every fire of one timer, as intervals, so that "it kept firing" and "it fired late" are
/// different answers rather than the same count.
final class FireLedger {
    let name: String
    private var lastFire: Date?
    private(set) var fires = 0
    private(set) var longestGap: TimeInterval = 0

    /// Fires that landed inside a named window, counted separately. The window is what the gesture
    /// is; the total across the whole run says almost nothing on its own.
    private(set) var firesInWindow: [String: Int] = [:]

    /// The longest run with no fire inside each window.
    ///
    /// **This is the number the measurement is actually about**, and the first version of this file
    /// did not produce it: a timer that stops entirely records no interval at all, so a ledger that
    /// only measures gaps *between fires* reports its best score exactly when the timer is dead. The
    /// gap still open at the end of a window is folded in below, which is what turns "0 fires" into
    /// "5000 ms of nothing".
    private(set) var longestGapInWindow: [String: TimeInterval] = [:]
    private var currentWindow: String?

    /// The run-loop mode this timer's callback was actually running in, sampled per fire.
    ///
    /// Read with `CFRunLoopCopyCurrentMode` from **inside** the callback, so it is what the loop was
    /// doing rather than what the measurement asked it to do. This is what makes the `menu` form
    /// evidence instead of an assumption: nothing in that gesture names a mode, so observing
    /// `NSEventTrackingRunLoopMode` here is the proof that a real AppKit tracking session produces
    /// the mode the `runloop` form enters by hand.
    private(set) var modesObserved: Set<String> = []

    /// How many fires saw each darwin suppression state. A histogram rather than a start/end pair,
    /// because App Nap can engage part-way through a run and a two-sample reading would miss it.
    private(set) var suppressionSamples: [DarwinSuppression: Int] = [:]

    init(_ name: String) { self.name = name }

    func enterWindow(_ window: String?) {
        closeTheOpenGap()
        currentWindow = window
        // The gap clock restarts at a window boundary so that the gap attributed to a gesture is the
        // gesture's own, not the sum of it and whatever preceded it.
        lastFire = Date()
    }

    /// Fold the gap that is still open into the totals — at a window boundary, and at the end.
    func closeTheOpenGap() {
        guard let lastFire else { return }
        let open = Date().timeIntervalSince(lastFire)
        longestGap = max(longestGap, open)
        if let currentWindow {
            longestGapInWindow[currentWindow] = max(longestGapInWindow[currentWindow] ?? 0, open)
        }
    }

    func record() {
        fires += 1
        if let mode = CFRunLoopCopyCurrentMode(CFRunLoopGetMain()) {
            modesObserved.insert(mode.rawValue as String)
        }
        suppressionSamples[darwinSuppressionState(), default: 0] += 1
        let now = Date()
        if let lastFire {
            let gap = now.timeIntervalSince(lastFire)
            longestGap = max(longestGap, gap)
            if let currentWindow {
                longestGapInWindow[currentWindow] = max(longestGapInWindow[currentWindow] ?? 0, gap)
            }
        }
        lastFire = now
        if let currentWindow { firesInWindow[currentWindow, default: 0] += 1 }
    }
}

/// A timer registered in `RunLoop.Mode.default` only — **the mutant**, and the control this whole
/// measurement is against. `MainRunLoopTimer` is the same code with `.common` in its place.
final class DefaultModeTimer: RepeatingTimer {
    private var timer: Timer?

    var interval: Duration? {
        guard let timer, timer.isValid else { return nil }
        return .seconds(timer.timeInterval)
    }

    func start(every interval: Duration, _ fire: @escaping () -> Void) {
        stop()
        let seconds =
            TimeInterval(interval.components.seconds)
            + TimeInterval(interval.components.attoseconds) / 1e18
        let timer = Timer(timeInterval: seconds, repeats: true) { _ in fire() }
        RunLoop.main.add(timer, forMode: .default)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// This mutant asserts no isolation in ``stop()``, so it may forward — the one-line case
    /// `RepeatingTimer.stopWithoutAssertingIsolation()` describes. The mutation this class exists to
    /// be is the run-loop mode on the line above `stop()`, and nothing else.
    func stopWithoutAssertingIsolation() {
        stop()
    }
}

func report(_ ledgers: [FireLedger], windows: [String]) {
    for ledger in ledgers { ledger.closeTheOpenGap() }
    let width = max(ledgers.map(\.name.count).max() ?? 10, 14)
    let cell = { (text: String) in text.padding(toLength: 20, withPad: " ", startingAt: 0) }
    print("")
    print(
        "  \("timer".padding(toLength: width, withPad: " ", startingAt: 0))  total  "
            + windows.map { cell("\($0): fires/gap") }.joined())
    for ledger in ledgers {
        let cells = windows.map {
            cell(String(
                format: "%d / %.0f ms", ledger.firesInWindow[$0] ?? 0,
                (ledger.longestGapInWindow[$0] ?? 0) * 1000))
        }
        print(
            "  \(ledger.name.padding(toLength: width, withPad: " ", startingAt: 0))  "
                + String(format: "%5d  ", ledger.fires) + cells.joined())
    }
    print("")
    for ledger in ledgers where !ledger.modesObserved.isEmpty {
        print("  \(ledger.name): run-loop modes seen from inside the callback — "
            + ledger.modesObserved.sorted().joined(separator: ", "))
    }
    // Printed for every measurement, not only the App Nap one. A fire count is uninterpretable
    // without it: "the timer kept up" means nothing until you know whether anything was trying to
    // slow it down.
    for ledger in ledgers where !ledger.suppressionSamples.isEmpty {
        let histogram = ledger.suppressionSamples.sorted { $0.key < $1.key }
            .map { "\(describeSuppression($0.key)) x\($0.value)" }.joined(separator: ", ")
        print("  \(ledger.name): darwin suppression state per fire — \(histogram)")
    }
    print("")
}

// MARK: - Measurement 1: the run loop's mode

/// Enter `RunLoop.Mode.eventTracking` for `seconds`, which is what AppKit does for the whole of a
/// window drag and an open menu.
///
/// Driving the mode directly rather than asking a human to drag is the difference between a number
/// and an anecdote — the mode is the *mechanism*, and a real drag is the same mechanism plus a hand.
/// The gesture version is `runloop --window`, and the smoke checklist has it.
func runInEventTracking(for seconds: TimeInterval) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        // A bounded turn, so the loop is genuinely serviced in this mode rather than blocked in it.
        RunLoop.main.run(mode: .eventTracking, before: Date().addingTimeInterval(0.02))
    }
}

func runInDefaultMode(for seconds: TimeInterval) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
}

func measureRunLoopModes(gesture: TimeInterval, withWindow: Bool) {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    // AppKit is what adds `NSEventTrackingRunLoopMode` to the common set. Without an NSApplication
    // there is nothing to measure: `.common` would be `.default` alone and the two columns would
    // agree for the wrong reason. `finishLaunching` is what actually performs that registration.
    application.finishLaunching()

    let common = FireLedger("common  150ms")
    let deflt = FireLedger("default 150ms")
    let commonPoll = FireLedger("common  1s")
    let defltPoll = FireLedger("default 1s")

    let shipped = MainRunLoopTimer()
    let mutant = DefaultModeTimer()
    let shippedPoll = MainRunLoopTimer()
    let mutantPoll = DefaultModeTimer()

    shipped.start(every: WatchdogPolicy.pollInterval) { common.record() }
    mutant.start(every: WatchdogPolicy.pollInterval) { deflt.record() }
    shippedPoll.start(every: TapHealthPolling.interval) { commonPoll.record() }
    mutantPoll.start(every: TapHealthPolling.interval) { defltPoll.record() }

    let ledgers = [common, deflt, commonPoll, defltPoll]

    var window: NSWindow?
    if withWindow {
        let created = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 480, height: 140),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        created.title = "Vocca timer probe — drag me"
        created.makeKeyAndOrderFront(nil)
        application.activate(ignoringOtherApps: true)
        window = created
    }
    _ = window

    print("  Timers: \(milliseconds(WatchdogPolicy.pollInterval)) ms (watchdog) and "
        + "\(milliseconds(TapHealthPolling.interval)) ms (tap-health poll), one pair per run-loop mode.")

    for ledger in ledgers { ledger.enterWindow("idle") }
    print("  [1/3] baseline: \(Int(gesture)) s in the default mode, nothing happening.")
    runInDefaultMode(for: gesture)

    for ledger in ledgers { ledger.enterWindow("gesture") }
    if withWindow {
        print("  [2/3] DRAG THE WINDOW NOW, or hold a menu open — \(Int(gesture)) s.")
        runInDefaultMode(for: gesture)
    } else {
        print("  [2/3] gesture: \(Int(gesture)) s in .eventTracking — the mode a drag runs the loop in.")
        runInEventTracking(for: gesture)
    }

    for ledger in ledgers { ledger.enterWindow("after") }
    print("  [3/3] after: \(Int(gesture)) s in the default mode again.")
    runInDefaultMode(for: gesture)

    report(ledgers, windows: ["idle", "gesture", "after"])

    let commonHeld = (common.firesInWindow["gesture"] ?? 0) > 0
    let defaultHeld = (deflt.firesInWindow["gesture"] ?? 0) > 0
    print("  VERDICT: .common kept firing through the gesture: \(commonHeld).")
    print("           .default kept firing through the gesture: \(defaultHeld).")
    if commonHeld && !defaultHeld {
        print(
            "           H10 CONFIRMED — the mode is load-bearing. A session running through this\n"
                + "           gesture would have had no ceiling and no physical-key poll for its duration.")
    } else if commonHeld && defaultHeld {
        print(
            "           H10 NOT REPRODUCED here — both modes were serviced. Either .eventTracking\n"
                + "           is not in this process's common set, or the loop never really entered it.")
    }
}

// MARK: - Measurement 1b: a real AppKit tracking session

/// **The same hazard, with no run-loop mode named anywhere in the gesture.**
///
/// `runloop` enters `.eventTracking` by hand, which measures the mechanism but has to *assume* that
/// a real AppKit gesture produces it. This does not assume it: it opens a real window, opens a real
/// `NSMenu` through `popUp(positioning:at:in:)` — AppKit's own modal tracking session, the same
/// machinery a window drag uses — and reads `CFRunLoopCopyCurrentMode` from inside the timer
/// callbacks. The mode is *observed*, not requested.
///
/// It runs unattended, which is what makes it worth having: it takes menu tracking off the manual
/// smoke list and leaves only the window drag itself as a gesture needing a hand.
func measureMenuTracking(seconds: TimeInterval) {
    let application = NSApplication.shared
    application.setActivationPolicy(.regular)
    application.finishLaunching()

    let window = NSWindow(
        contentRect: NSRect(x: 200, y: 200, width: 420, height: 120),
        styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.title = "Vocca timer probe"
    window.makeKeyAndOrderFront(nil)
    application.activate(ignoringOtherApps: true)

    let common = FireLedger("common  150ms")
    let deflt = FireLedger("default 150ms")
    let shipped = MainRunLoopTimer()
    let mutant = DefaultModeTimer()
    shipped.start(every: WatchdogPolicy.pollInterval) { common.record() }
    mutant.start(every: WatchdogPolicy.pollInterval) { deflt.record() }
    let ledgers = [common, deflt]

    for ledger in ledgers { ledger.enterWindow("idle") }
    print("  [1/2] baseline: 2 s with no menu open.")
    runInDefaultMode(for: 2)

    let menu = NSMenu(title: "Probe")
    for index in 1...5 {
        menu.addItem(withTitle: "Item \(index)", action: nil, keyEquivalent: "")
    }

    // Cancelled from a timer in the *common* modes, because a timer in the default mode alone could
    // not fire during the tracking session it is meant to end — which would hang the probe on
    // exactly the hazard it is measuring.
    let cancel = Timer(timeInterval: seconds, repeats: false) { _ in menu.cancelTracking() }
    RunLoop.main.add(cancel, forMode: .common)

    for ledger in ledgers { ledger.enterWindow("tracking") }
    print("  [2/2] opening a real NSMenu for \(Int(seconds)) s — AppKit's own tracking session.")
    let started = Date()
    menu.popUp(
        positioning: nil, at: NSPoint(x: 40, y: 80), in: window.contentView)
    let tracked = Date().timeIntervalSince(started)
    cancel.invalidate()
    for ledger in ledgers { ledger.enterWindow(nil) }

    print(String(format: "  menu tracking lasted %.2f s", tracked))
    report(ledgers, windows: ["idle", "tracking"])

    let sawTracking = common.modesObserved.contains("NSEventTrackingRunLoopMode")
    print("  The main run loop entered NSEventTrackingRunLoopMode during the gesture: \(sawTracking).")
    if sawTracking {
        print(
            "  So `runloop` is not a simulation of the hazard — a genuine AppKit tracking session\n"
                + "  produces the same mode, and the .default timer's silence below is under that gesture.")
    } else {
        print(
            "  NOT OBSERVED. Either the menu never tracked (no window server session?) or this OS\n"
                + "  no longer uses that mode — in which case the `runloop` form's premise needs revisiting.")
    }
}

// MARK: - Measurement 2: App Nap

/// Which activity assertion to hold, if any.
enum ActivityChoice: String {
    case none
    /// `.userInitiated`, which **contains** `.idleSystemSleepDisabled` — it keeps the machine awake.
    case userInitiated
    /// `.userInitiatedAllowingIdleSystemSleep` — the same App Nap prevention **without** the
    /// keep-awake bit. Verified on this SDK: `userInitiated = 0xffffff`,
    /// `userInitiatedAllowingIdleSystemSleep = 0xefffff`, `idleSystemSleepDisabled = 0x100000`.
    ///
    /// It exists, and the first version of this measurement did not know that: it chose the heavier
    /// set and then used its weight as the reason not to adopt the countermeasure at all.
    case allowingIdleSleep

    var options: ProcessInfo.ActivityOptions? {
        switch self {
        case .none: return nil
        case .userInitiated: return .userInitiated
        case .allowingIdleSleep: return .userInitiatedAllowingIdleSystemSleep
        }
    }
}

func measureAppNap(seconds: TimeInterval, activity choice: ActivityChoice) {
    let application = NSApplication.shared
    // `.accessory` is what `LSUIElement` gives the shipped app, and it is the condition under
    // question: an accessory app with no visible window is what App Nap is for.
    application.setActivationPolicy(.accessory)
    application.finishLaunching()

    var token: NSObjectProtocol?
    if let options = choice.options {
        token = ProcessInfo.processInfo.beginActivity(
            options: options, reason: "Vocca is recording a dictation session")
    }
    defer { if let token { ProcessInfo.processInfo.endActivity(token) } }

    let watchdog = FireLedger("watchdog 150ms")
    let poll = FireLedger("poll 1s")
    let watchdogTimer = MainRunLoopTimer()
    let pollTimer = MainRunLoopTimer()

    var intervals: [TimeInterval] = []
    var last = Date()
    watchdogTimer.start(every: WatchdogPolicy.pollInterval) {
        let now = Date()
        intervals.append(now.timeIntervalSince(last))
        last = now
        watchdog.record()
    }
    pollTimer.start(every: TapHealthPolling.interval) { poll.record() }

    let stateAtStart = darwinSuppressionState()
    print("  pid \(ProcessInfo.processInfo.processIdentifier), activation policy "
        + "\(application.activationPolicy() == .accessory ? ".accessory" : "other"), "
        + "activity: \(choice.rawValue).")
    print("  darwin suppression state at start: \(describeSuppression(stateAtStart))")
    print("  Running \(Int(seconds)) s with no window. Put another app in front and leave it there.")

    for ledger in [watchdog, poll] { ledger.enterWindow("run") }
    runInDefaultMode(for: seconds)

    report([watchdog, poll], windows: ["run"])

    let expected = Int(seconds / 0.150)
    let sorted = intervals.sorted()
    let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    let p99 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.99))]
    print(String(
        format: "  watchdog fires: %d observed vs %d expected (%.1f%%).",
        watchdog.fires, expected, 100.0 * Double(watchdog.fires) / Double(max(expected, 1))))
    print(String(
        format: "  interval: median %.1f ms, p99 %.1f ms, max %.1f ms (nominal 150 ms).",
        median * 1000, p99 * 1000, (sorted.last ?? 0) * 1000))
    print("  darwin suppression state at end: \(describeSuppression(darwinSuppressionState()))")

    // The control that makes the fire count mean anything at all.
    let everSuppressed = watchdog.suppressionSamples.keys.contains(.suppressed)
    if !everSuppressed {
        print("""
              READ THIS BEFORE BELIEVING THE NUMBER ABOVE: the process was never suppressed, so this
              is a measurement of an UNTHROTTLED process. It says nothing about what App Nap would
              do — only that App Nap did not engage. Re-run under `--taskpolicy-bg` to see the
              throttle itself.
            """)
    }
}

// MARK: - Entry

func milliseconds(_ duration: Duration) -> Int64 {
    let components = duration.components
    return components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000
}

let arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.first ?? "runloop"
let duration = arguments.compactMap { Double($0) }.first ?? 5

switch command {
case "runloop":
    print("== Hazard 1: the run loop's mode during a drag / menu tracking ==")
    measureRunLoopModes(gesture: duration, withWindow: arguments.contains("--window"))

case "menu":
    print("== Hazard 1, under a real AppKit tracking session ==")
    measureMenuTracking(seconds: duration)

case "appnap":
    print("== Hazard 2: App Nap on an LSUIElement app ==")
    let choice: ActivityChoice =
        arguments.contains("--activity-allowing-idle-sleep")
        ? .allowingIdleSleep : (arguments.contains("--activity") ? .userInitiated : .none)
    measureAppNap(seconds: duration, activity: choice)

case "--build-only":
    // CI compiles the harness and stops. `Tools/` is not a package target, so `swift build` never
    // sees it — which means it bit-rots silently the first time `RepeatingTimer`, `WatchdogPolicy`
    // or `TapHealthPolling` changes shape, and the next person to reach for the hazard measurement
    // finds it does not build. Reaching this line at all is the assertion.
    print("timer-probe built and links the shipped VoccaHotkey.")

default:
    print("""
        usage: timer-probe <command> [seconds] [flags]
          runloop [--window]   .common vs .default through event tracking (--window: drag it yourself)
          menu                 the same, under a real NSMenu tracking session, unattended
          appnap [--activity | --activity-allowing-idle-sleep]
          --build-only         compile check only
        """)
    exit(2)
}
