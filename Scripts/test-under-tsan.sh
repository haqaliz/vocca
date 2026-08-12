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

# Runs the concurrency suites under ThreadSanitizer.
#
# WHAT THIS PROVES, AND WHAT IT DOES NOT
#
# It proves that no two threads touched AudioRingBuffer's sample storage without a synchronising
# edge between them. That is worth having: the buffer is the one place in Vocca where the compiler
# is not checking anything, and its two concurrency tests drive two real threads through thousands
# of blocks.
#
# It does NOT prove the memory orderings are strong enough, and nobody should read a green run as
# saying so. Measured on this repository, on this toolchain:
#
#   - Weakening any of the four load-bearing orderings — or all four at once — leaves this run
#     completely clean, and leaves the whole suite clean too. Independently reproduced in review
#     across six such mutations. LLVM's ThreadSanitizer does not model orderings weaker than
#     sequentially consistent; it detects *missing synchronisation*, not *insufficient*
#     synchronisation.
#   - Publishing the write cursor before copying the samples in — a genuine ordering bug — is also
#     clean here, and correctly so: the consumer's own release of `readIndex` still orders the
#     producer's later write after the consumer's read, so there is no data race for TSan to see.
#     AudioRingBufferTests' value check does catch it, but **intermittently**: measured at 2 of 12
#     plain runs and 0 of 2 under this script. Do not read a single green run as clearing it. This
#     was first written down here as though the value check caught it reliably; it does not, and the
#     rate is the honest version.
#
# So the two mechanisms cover different failures and neither subsumes the other. The argument for
# the orderings themselves is the comment at the top of Sources/VoccaAudio/AudioRingBuffer.swift and
# the review of it. If that ever stops being true, it will be because someone built a check that
# reads the generated `ldar`/`stlr`, not because this script grew.
#
# The vacuity control is real and was run: a plain `var` incremented from two threads IS reported by
# this configuration, so the instrumentation is live rather than silently disabled.
#
# Not folded into Scripts/test-with-floor.sh: this runs a filtered subset, and that script's whole
# purpose is a floor under the *whole* suite. A filter and a floor do not belong in one command.

set -euo pipefail

# The suites that drive more than one thread. A suite added here must actually be concurrent —
# running single-threaded tests under TSan costs time and proves nothing.
FILTER="AudioRingBufferTests"

# The concurrency tests in that suite. Checked by name below, because `--filter` matching nothing
# exits 0 with "Executed 0 tests", which is the same silent green Scripts/test-with-floor.sh exists
# to prevent.
REQUIRED_TESTS=(
    "testASingleProducerAndSingleConsumerNeverLoseReorderOrDuplicateASample"
    "testUnderContentionEveryProducedSampleIsEitherReceivedOrCounted"
)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

log_file="$(mktemp -t vocca-tsan.XXXXXX)"
trap 'rm -f "$log_file"' EXIT

set +e
(cd "$REPO_ROOT" && swift test --sanitize=thread --filter "$FILTER") 2>&1 | tee "$log_file"
test_status="${PIPESTATUS[0]}"
set -e

if [ "$test_status" -ne 0 ]; then
    exit "$test_status"
fi

# A ThreadSanitizer report does not always fail the process: reports go to stderr and the default
# `halt_on_error=0` lets the run continue and exit 0. So the log is checked directly.
if grep -q "ThreadSanitizer:" "$log_file"; then
    printf '%s\n' \
        "::error::ThreadSanitizer reported above. AudioRingBuffer is the one type in this package the compiler is not checking; a report here means its SPSC discipline is broken, not that the test is flaky." >&2
    exit 1
fi

for name in "${REQUIRED_TESTS[@]}"; do
    if ! grep -q "$name" "$log_file"; then
        printf '%s\n' \
            "::error::$name did not run under ThreadSanitizer. Either it was renamed off the 'test' prefix or the FILTER in this script no longer matches it — and a filter that matches nothing exits 0 having measured nothing." >&2
        exit 1
    fi
done

printf '%s\n' "ThreadSanitizer: clean, and both concurrency tests ran."
