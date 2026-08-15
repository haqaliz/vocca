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
#
# Generates the stand-in cleanup-pair corpus from checked-in goldens
# (eval-harness/plan_20260815.md §2.2): each golden is the clean text of one pair; the script
# applies deterministic ASR-ish error injection (class-specific plus a light common degradation —
# the exact matrix is documented in Tests/CleanupPairs/FIXTURES.md, never assumed) and writes the
# <name>.raw.txt / <name>.clean.txt / <name>.class.txt triples.
#
# Deterministic by construction: one fixed python seed (--seed, default constant) — two runs
# over the same goldens produce byte-identical output. A goldens tree the script cannot classify
# fails loudly (unknown class directory: exit 2 naming it; nothing to generate: exit 1) and a
# rejected run never creates the output directory.
#
# The planted raw-preferred pair (`*-planted-raw-preferred`) is emitted with NO injection —
# raw == clean — the can-lose proof for the scorer. It is one of its class's pairs, so a second
# golden whose content duplicates the planted golden is that same utterance, not another pair:
# the duplicate is skipped (the planted name wins).
#
# Usage:
#   Scripts/provision-cleanup-fixtures.sh [--goldens <dir>] [--output <dir>] [--seed <hex>]
#
# --goldens: the goldens tree (default Tests/CleanupPairs/goldens) — one golden per pair at
#            <goldens>/<class>/<name>.txt, classes: fillers, punctuation, capitalization,
#            numbers-units, dictionary, token-protection.
# --output:  the directory the triples land in (default Tests/CleanupPairs).
# --seed:    the python seed as hex (default 0x5EED_C0DE).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

goldens_dir="$REPO_ROOT/Tests/CleanupPairs/goldens"
output_dir="$REPO_ROOT/Tests/CleanupPairs"
seed="0x5EED_C0DE"

while [ $# -gt 0 ]; do
    case "$1" in
        --goldens) goldens_dir="$2"; shift 2 ;;
        --output) output_dir="$2"; shift 2 ;;
        --seed) seed="$2"; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

if [ ! -d "$goldens_dir" ]; then
    echo "goldens directory not found: $goldens_dir" >&2
    exit 1
fi

# Validation first — a rejected run must never create the output directory.
classes=(fillers punctuation capitalization numbers-units dictionary token-protection)

for entry in "$goldens_dir"/*; do
    [ -d "$entry" ] || continue
    name="$(basename "$entry")"
    case " ${classes[*]} " in
        *" $name "*) ;;
        *) echo "unknown class directory: $name" >&2; exit 2 ;;
    esac
done

golden_count="$(find "$goldens_dir" -type f -name '*.txt' | wc -l | tr -d ' ')"
if [ "$golden_count" -eq 0 ]; then
    echo "nothing to generate: no golden .txt files under $goldens_dir" >&2
    exit 1
fi

mkdir -p "$output_dir"

python3 - "$goldens_dir" "$output_dir" "$seed" <<'PY'
import os
import random
import re
import sys

goldens_dir, output_dir, seed_text = sys.argv[1], sys.argv[2], sys.argv[3]
seed = int(seed_text, 16)

CLASSES = [
    "fillers",
    "punctuation",
    "capitalization",
    "numbers-units",
    "dictionary",
    "token-protection",
]

ONES = {
    1: "one", 2: "two", 3: "three", 4: "four", 5: "five", 6: "six", 7: "seven",
    8: "eight", 9: "nine", 10: "ten", 11: "eleven", 12: "twelve", 13: "thirteen",
    14: "fourteen", 15: "fifteen", 16: "sixteen", 17: "seventeen", 18: "eighteen",
    19: "nineteen", 20: "twenty",
}
TENS = {
    20: "twenty", 30: "thirty", 40: "forty", 50: "fifty", 60: "sixty",
    70: "seventy", 80: "eighty", 90: "ninety",
}


def spell(number: int) -> str:
    if number in ONES:
        return ONES[number]
    if number in TENS:
        return TENS[number]
    tens = (number // 10) * 10
    ones = number % 10
    return TENS[tens] + " " + ONES[ones]


def spell_digits(text: str) -> str:
    return re.sub(r"\d+", lambda m: spell(int(m.group(0))), text)


def common_degrade(text: str) -> str:
    """The light degradation every class shares: lowercase the first letter and drop the
    terminal period — both recovered by capitalizeSentences + segmentAndTerminate."""
    stripped = text.rstrip("\n")
    if stripped.endswith("."):
        stripped = stripped[:-1]
    return stripped[0].lower() + stripped[1:]


def inject(golden: str, class_name: str, rng: random.Random) -> str:
    text = common_degrade(golden)
    if class_name == "fillers":
        filler = rng.choice(["um", "uh", "hmm"])
        text = filler + " " + text
    elif class_name == "numbers-units":
        text = spell_digits(text)
    return text


def pair_name(class_name: str, file_name: str) -> str:
    return file_name[:-len(".txt")]


goldens = []  # (class_name, name, content)
for class_name in CLASSES:
    class_dir = os.path.join(goldens_dir, class_name)
    if not os.path.isdir(class_dir):
        continue
    for file_name in sorted(os.listdir(class_dir)):
        if not file_name.endswith(".txt"):
            continue
        with open(os.path.join(class_dir, file_name), encoding="utf-8") as handle:
            content = handle.read().rstrip("\n")
        goldens.append((class_name, pair_name(class_name, file_name), content))

planted = [g for g in goldens if g[1].endswith("-planted-raw-preferred")]

# The planted pair is one of its class's pairs: a golden whose content duplicates the planted
# golden is the same utterance, and only the planted name survives.
if planted:
    planted_class, planted_name, planted_content = planted[0]
    goldens = [
        g for g in goldens
        if not (
            g[0] == planted_class
            and g[1] != planted_name
            and g[2] == planted_content
        )
    ]

rng = random.Random(seed)

for class_name, name, golden in goldens:
    if name.endswith("-planted-raw-preferred"):
        raw = golden
    else:
        raw = inject(golden, class_name, rng)
    with open(os.path.join(output_dir, name + ".raw.txt"), "w", encoding="utf-8") as handle:
        handle.write(raw)
    with open(os.path.join(output_dir, name + ".clean.txt"), "w", encoding="utf-8") as handle:
        handle.write(golden)
    with open(os.path.join(output_dir, name + ".class.txt"), "w", encoding="utf-8") as handle:
        handle.write(class_name)

print("provisioned %d cleanup pairs under %s" % (len(goldens), output_dir))
PY
