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

# Runs `swift test` and fails the run unless it actually executed tests.
#
# WHY THIS EXISTS
#
# `swift test` exits 0 when it discovers nothing. Measured on this repository: renaming every
# `func testX` to `func checkX` — the shape of a careless refactor, not of sabotage — produces
#
#     Test Suite 'All tests' passed
#          Executed 0 tests, with 0 failures (0 unexpected) in 0.000 seconds
#     swift test EXIT=0
#
# and every CI job goes green having measured nothing. The same happens if `.testTarget` is
# dropped from Package.swift, or if a `--filter` matches nothing.
#
# That matters more here than in most repositories, because *every* gate on this project is
# delivered by `swift test`: the zero-network invariant (a permanent release blocker), the module
# boundary lint, the licence-header lint, the entitlement set-equality check, and the build
# configuration detector. Without a floor under the test count there is no floor under any of them.
#
# The floor is deliberately well below the current count and well above zero. It is a check against
# wholesale disappearance of the suite, not against removing an individual test — that is what code
# review is for, and a floor tight enough to catch it would fail on every legitimate refactor and be
# lowered within a week.
#
# Not overridable by an environment variable on purpose: a floor a caller can set to 0 is not a
# floor. Raising it as the suite grows is a deliberate edit to this line, visible in review.
#
# Usage: Scripts/test-with-floor.sh [extra swift test arguments...]
#   Environment (VOCCA_APP_BUNDLE, VOCCA_EXPECTED_CONFIGURATION, CI, ...) is inherited by
#   `swift test` unchanged, so this is a drop-in replacement for it in any context.

set -euo pipefail

# Deliberate, reviewed constant — not derived from the current run (see below for why). Raised to
# 52 by task 2 of session-lifecycle, which added sixteen tests: six in CoreBoundaryTests and ten in
# SessionVocabularyTests. (It passed through 48 and 51 mid-task; review round 1 added the transitive
# re-export rule with its positive control and the autoclosure check, round 2 the CapturedAudio
# constraint.) It was 36 after the package-root-helper consolidation (task 1), and 33 before that.
# Raise it by hand, in the commit that changes the count, whenever the suite grows on purpose.
MINIMUM_EXECUTED_TESTS=52

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

log_file="$(mktemp -t vocca-swift-test.XXXXXX)"
trap 'rm -f "$log_file"' EXIT

set +e
(cd "$REPO_ROOT" && swift test "$@") 2>&1 | tee "$log_file"
test_status="${PIPESTATUS[0]}"
set -e

if [ "$test_status" -ne 0 ]; then
    # The suite itself failed. That is a real, loud failure and needs no help from this script;
    # exit with swift test's own status so the reason in the log is the reason in the exit code.
    exit "$test_status"
fi

# XCTest prints "Executed N tests" once per suite and once for the whole run. The largest number
# is the run total, which is what the floor is about. `sort -n | tail -1` rather than parsing the
# "All tests" line specifically, because that line's exact wording is XCTest's, not ours.
executed="$(grep -oE 'Executed [0-9]+ tests' "$log_file" | grep -oE '[0-9]+' | sort -n | tail -1 || true)"
: "${executed:=0}"

if [ "$executed" -lt "$MINIMUM_EXECUTED_TESTS" ]; then
    printf '%s\n' \
        "::error::swift test executed $executed tests (floor: $MINIMUM_EXECUTED_TESTS). swift test exits 0 when it discovers nothing, so a green run proves nothing without this check. Either test discovery broke (methods renamed off the 'test' prefix, the test target dropped from Package.swift, a --filter matching nothing), or the suite genuinely shrank and the floor in Scripts/test-with-floor.sh needs a deliberate, reviewed edit." >&2
    exit 1
fi

printf '%s\n' "swift test executed $executed tests (floor: $MINIMUM_EXECUTED_TESTS)."
