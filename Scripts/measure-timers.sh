#!/bin/bash
# Copyright 2026 The Vocca Authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Builds and runs the phase 5 timer measurement harness.
#
# WHY THIS EXISTS
#
# Two hazards on the timer that drives the 120 s ceiling, the physical-key poll and the ~1 s
# tap-health poll are not discoverable from CI, and both were carried as explicitly unverified
# through two merged aspects:
#
#   1. A timer registered in the run loop's default mode alone stops being serviced while a window
#      is being dragged or a menu is open. If that is true, a session running through such a gesture
#      has no ceiling and no poll for its duration, with the widget still showing it as recording.
#
#   2. Vocca is LSUIElement. App Nap may throttle a background accessory app's timers, and
#      `ProcessInfo.beginActivity(...)` is the usual countermeasure.
#
# `swift test` cannot answer either: a hosted runner has no window server session, and App Nap is a
# property of a real, backgrounded, GUI-session process.
#
# WHAT IT MEASURES
#
#   ./Scripts/measure-timers.sh runloop [seconds]
#       Runs the SHIPPED MainRunLoopTimer (.common) beside a deliberate mutant (.default), at the
#       watchdog's own 150 ms and the tap-health poll's 1 s, through a window in which the main run
#       loop is driven in `.eventTracking` — the mode AppKit uses for the whole of a drag. Prints
#       fires per timer per window and the longest gap.
#
#   ./Scripts/measure-timers.sh runloop --window [seconds]
#       The same, with a real window to drag by hand. This is the smoke-checklist form: it confirms
#       that a human gesture produces the mode the automated form enters directly.
#
#   ./Scripts/measure-timers.sh menu [seconds]
#       The same hazard under a REAL AppKit tracking session — an NSMenu opened with popUp(...) —
#       with no run-loop mode named anywhere in the gesture. Runs unattended, and reads back the mode
#       the loop was actually in, so it is evidence rather than an assumption.
#
#   ./Scripts/measure-timers.sh appnap [seconds] [--activity | --activity-allowing-idle-sleep]
#       An accessory app with no window, left running while another app is in front.
#
#   ./Scripts/measure-timers.sh appnap [seconds] --taskpolicy-bg
#       The same, launched under `taskpolicy -b` — the supported CLI for the darwin-background
#       suppression App Nap applies. THIS IS THE ROW THAT MEASURES THE THROTTLE ITSELF. Without it,
#       an appnap run on an unsuppressed process measures nothing about App Nap at all, which is the
#       error the first version of this measurement made.
#
#   ./Scripts/measure-timers.sh --build-only
#       Compile the harness and stop. CI runs this: `Tools/` is not a package target, so nothing else
#       in the build ever compiles it, and it would bit-rot silently.
#
# EVERY RUN PRINTS THE PROCESS'S DARWIN SUPPRESSION STATE, per fire. A fire count taken without it
# cannot distinguish "the mechanism is not throttled" from "this process was never throttled".
#
# It is not a package target: everything under Sources/ is inside the zero-network coverage guard,
# which would require VoccaNetworkProbe to drive it. It links the built package instead, so the
# timer under test is the shipped one.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

configuration="${VOCCA_TIMER_PROBE_CONFIGURATION:-debug}"
build_dir=".build/$configuration"
binary=".build/timer-probe"

echo "Building the package ($configuration) so the probe links the shipped timer..."
swift build --configuration "$configuration" >/dev/null

echo "Building the probe..."
# The package's library targets are linked from their object files rather than from a static
# archive: SwiftPM emits no `.a` for a library target that no executable product names, so
# `-lVoccaHotkey` has nothing to find. Naming the objects keeps the probe running the SHIPPED code —
# a re-implementation of the timer here would measure the re-implementation.
objects=$(find "$build_dir/VoccaCore.build" "$build_dir/VoccaHotkey.build" -name '*.swift.o')

xcrun swiftc \
    -O \
    -target "$(uname -m)-apple-macos15" \
    -I "$build_dir/Modules" \
    -o "$binary" \
    Tools/TimerProbe/main.swift \
    $objects

if [[ " $* " == *" --build-only "* ]]; then
    "$binary" --build-only
    exit 0
fi

echo ""

# `--taskpolicy-bg` launches the probe in the darwin-background state — the same task suppression
# App Nap applies — via the supported `taskpolicy(8)` CLI. It is the only way found to observe the
# throttle on demand: a real backgrounded LSUIElement app was never *put* into that state in any
# observation here, and a measurement of an unsuppressed process says nothing about a suppressed one.
if [[ " $* " == *" --taskpolicy-bg "* ]]; then
    filtered=()
    for argument in "$@"; do
        [[ "$argument" == "--taskpolicy-bg" ]] || filtered+=("$argument")
    done
    echo "Launching under taskpolicy -b (darwin background)."
    exec taskpolicy -b "$binary" "${filtered[@]}"
fi

# `--bundle` runs the probe as a real LSUIElement .app launched through Launch Services, rather than
# as a child of this shell.
#
# THE DISTINCTION IS THE MEASUREMENT, not packaging fussiness. App Nap is a decision Launch Services
# and the window server make about an *application* — whether it is frontmost, whether its windows
# are occluded, when it last did user-initiated work. A binary started from a terminal is a child of
# the terminal's own app, and there is a real possibility it inherits an exemption the shipped
# Vocca.app would not have. Running both forms and reporting both is the only honest way to say
# whether an accessory app's timers are throttled.
if [[ " $* " == *" --bundle "* ]]; then
    app=".build/TimerProbe.app"
    rm -rf "$app"
    mkdir -p "$app/Contents/MacOS"
    cp "$binary" "$app/Contents/MacOS/timer-probe"
    cat >"$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>timer-probe</string>
    <key>CFBundleIdentifier</key><string>dev.vocca.TimerProbe</string>
    <key>CFBundleName</key><string>Vocca timer probe</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <!-- The condition under test. Vocca ships with this key, which is what makes it a background
         accessory app and therefore a candidate for App Nap in the first place. -->
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
    log=".build/timer-probe-bundle.log"
    rm -f "$log"
    echo "Running as $app (LSUIElement), output to $log"
    # `open --stdout` routes the app's output back to a file we can read; `--args` passes the
    # measurement's own arguments through. `--wait-apps` blocks until it exits.
    # `-n` forces a NEW instance. Without it, `open` returns immediately if any instance of
    # dev.vocca.TimerProbe is already alive and the script then prints a log belonging to the other
    # process — or an empty one. Latent rather than observed, and one flag closes it.
    #
    # The arguments are filtered rather than substituted: `"${@/--bundle/}"` replaced the flag with an
    # EMPTY STRING and passed it through, leaving a blank positional in the app's argv. Harmless for
    # today's parsing and a landmine for the next argument added.
    forwarded=()
    for argument in "$@"; do
        [[ "$argument" == "--bundle" ]] || forwarded+=("$argument")
    done
    open -n --wait-apps --stdout "$log" --stderr "$log" "$app" --args "${forwarded[@]}"
    cat "$log"
    exit 0
fi

"$binary" "$@"
