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

# Builds and runs the engine-start measurement harness (`Tools/EngineStartProbe`).
#
# WHY THIS EXISTS
#
# `prd.md:280` requires the engine-start cost to be measured in C1 so that C7 optimises against data,
# and `spec.md` A7 records it as manual-but-required. Two merged aspects shipped on top of the
# unmeasured assumption that `AVAudioEngine.start()` costs "milliseconds"; the tap-callback decision
# in `HotkeyEventSource.receive(_:)` was left open pending this number.
#
# `swift test` cannot answer it: there is no microphone on a hosted runner, and a test that opened one
# would light the indicator M23 exists to keep dark.
#
# SUBCOMMANDS
#
#   ./Scripts/measure-engine-start.sh devices
#       List the input devices this machine offers, marking the system default. Run this first: the
#       numbers below mean nothing without knowing which device produced them.
#
#   ./Scripts/measure-engine-start.sh warm [extra probe flags]
#       The steady-state measurement — a graph built once and started/stopped per press, which is the
#       shape M23 mandates. Defaults to 120 iterations with a 1 s idle gap, because the gap is what
#       makes it a measurement of the user's pattern rather than of a tight loop.
#
#   ./Scripts/measure-engine-start.sh cold [count] [extra probe flags]
#       The FIRST start in a fresh process, `count` times, one process per sample — the number a user
#       pays on the first press after launching Vocca. It cannot be obtained from a loop, so it is
#       one process per row.
#
#       It runs at `--idle 0`, so the row it is comparable to is `warm --idle 0` and NOT the default
#       warm run. That distinction is load-bearing and was nearly missed: the first reading of this
#       data had cold (~70 ms) looking *faster* than warm (~114 ms), which is nonsense until you
#       notice the gap. What the two rows together actually show is that there is no cold-start
#       penalty at all — cold ~70 ms against warm-at-the-same-gap ~71 ms — and that the whole of the
#       variation is **how long the microphone has been closed**, which saturates within a second.
#
#   ./Scripts/measure-engine-start.sh prepare-matrix
#       `spec.md` open question 3 — *"does prepare() after every stop measurably reduce start
#       latency, and does it cost anything while idle?"* — as a factorial over prepare placement and
#       idle gap. Answering it takes about ten minutes.
#
#   ./Scripts/measure-engine-start.sh --build-only
#       Compile and stop. `Scripts/test-with-floor.sh` runs this: `Tools/` is not a package target,
#       so nothing else in a local run or in CI compiles it, and it would bit-rot silently — which is
#       precisely what happened to `Tools/TimerProbe` once already.
#
# EVERY RUN REFUSES TO REPORT A NUMBER IT DID NOT VERIFY. The probe exits non-zero if any row failed
# its checks, and prints why. See the header of `Tools/EngineStartProbe/main.swift`.
#
# It is not a package target: everything under `Sources/` is inside the zero-network coverage guard,
# and — more directly — this opens the microphone, which nothing in `swift test` may do.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

binary=".build/engine-start-probe"

echo "Building the engine-start probe..." >&2
mkdir -p .build
xcrun swiftc \
    -O \
    -target "$(uname -m)-apple-macos15" \
    -o "$binary" \
    Tools/EngineStartProbe/main.swift

if [[ " $* " == *" --build-only "* ]]; then
    "$binary" --build-only
    exit 0
fi

subcommand="${1:-warm}"
[[ $# -gt 0 ]] && shift

# Guarded expansion throughout — macOS /bin/bash is 3.2.57, where an EMPTY array expanded under
# `set -u` is an unbound variable and aborts the script. `Scripts/measure-timers.sh` records the same
# hazard after being bitten by it.
case "$subcommand" in
devices)
    "$binary" --devices
    ;;

warm)
    "$binary" ${@+"$@"}
    ;;

cold)
    count="${1:-40}"
    if [[ "$count" =~ ^[0-9]+$ ]]; then shift; else count=40; fi
    echo "Cold start: the first start() in a fresh process, $count processes." >&2
    echo "iteration,start_ms,stop_ms,prepare_ms,first_audio_ms,frames,callbacks,validity,note"
    for ((i = 0; i < count; i++)); do
        # `--idle 0` because the gap that matters here is the process launch itself, and
        # `--iterations 1` because every iteration after the first is warm by definition.
        "$binary" --iterations 1 --idle 0 --csv ${@+"$@"} || {
            echo "error: cold sample $i failed verification (see the row above)." >&2
            exit 6
        }
    done
    ;;

prepare-matrix)
    # spec.md open question 3, as a factorial. The idle gap is the second factor because whatever
    # `prepare()` warms is torn down again over a gap, and a matrix taken at idle=0 alone reports a
    # saving the user never sees.
    for idle in 0 1 3; do
        for placement in none after before; do
            "$binary" --iterations 30 --idle "$idle" --prepare "$placement" \
                --label "prepare=$placement idle=${idle}s" ${@+"$@"} || exit $?
            echo ""
        done
    done
    ;;

*)
    echo "error: unknown subcommand '$subcommand'." >&2
    echo "       Try: devices | warm | cold [count] | prepare-matrix | --build-only" >&2
    exit 2
    ;;
esac
