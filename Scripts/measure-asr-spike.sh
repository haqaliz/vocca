#!/bin/bash
# Builds (and optionally runs) the F1 spike probe (Tools/ASRSpike) — the repository's first
# FluidAudio consumer, deliberately not a package target so nothing in `swift build`/`swift test`
# compiles it. This script is the only thing that does, which is why test-with-floor.sh calls it
# with --build-only after every suite run: a FluidAudio API rename must break here first, not at
# the moment the model is needed.
#
# Usage:
#   Scripts/measure-asr-spike.sh --build-only     # compile, stop (the CI/local hook)
#   Scripts/measure-asr-spike.sh --audio <wav> ...  # build and run the probe (developer or runner)
#
# The probe runs under strict concurrency: one of the spike's findings is whether the SDK's
# types are holdable in a Swift 6 actor.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_PATH="$REPO_ROOT/Tools/ASRSpike"

if [ "${1:-}" = "--build-only" ]; then
    swift build --package-path "$PACKAGE_PATH" -Xswiftc -strict-concurrency=complete
    exit 0
fi

swift build --package-path "$PACKAGE_PATH" -Xswiftc -strict-concurrency=complete
swift run --package-path "$PACKAGE_PATH" ASRSpike "$@"
