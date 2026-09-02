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
# The semi-automated injection matrix — C8's measurement surface (`matrix-smoke/spec.md`).
#
# ROADMAP.md:172 judges P2 on >=95% first-method-success across a 20+ app matrix with the
# per-app strategy memory active, and ROADMAP.md:164 promises that matrix is "run as a
# semi-automated harness, tracked per release". This is that harness. It is deliberately
# *semi*: it brings each application to the front, prints what to expect, does the select-all
# and copy, byte-compares what came back, and tallies the number.
#
# WHAT IT CANNOT DO, AND DOES NOT PRETEND TO:
#
#   1. Press the hotkey. The tap needs the Accessibility grant and the session needs a real
#      microphone, so the dictation is the founder's — the script waits for it.
#   2. Read the ladder's log. Which rung landed is the founder's observation, confirmed per
#      row. A script that guessed the rung would produce exactly the number this whole exercise
#      exists to stop guessing.
#
# So a row passes on two independent facts: the field held the transcript byte-for-byte, AND
# the log named the expected rung. Either alone is not a pass — `.accessibility` named with
# nothing in the field is the read-back verification lying (SMOKE_CHECKLIST.md's own rule), and
# text in the field via a fallback rung is a delivery without first-method success.
#
# Every completed row appends one JSONL line to the run log — the machine half of the evidence,
# one file per run, alongside the tracked table. The default location is
# ~/Library/Application Support/Vocca/matrix-runs/<timestamp>.jsonl; `--run-log <path>` moves it.
#
# PRECONDITIONS the founder owns (the script checks what it can and states the rest):
#   - Vocca is running, armed (Accessibility granted, tap live) and its model is prepared.
#   - The terminal hosting this script has Automation grants for the target applications. A
#     denied ⌘A/⌘C is VOIDED, not failed: stale `pbpaste` output is the void signal, and
#     asserting a byte-compare failure without knowing the selection was made would break the
#     checklist's first preamble rule.
#   - For a baseline run, the memory is reset:
#     rm ~/Library/Application\ Support/Vocca/strategies.json
#
# Usage:
#   Scripts/injection-matrix.sh --self-check   # validate the row table + checklist sync (CI-safe)
#   Scripts/injection-matrix.sh --dry-run      # print the table with install status; touch nothing
#   Scripts/injection-matrix.sh --verify-bundle-ids  # plutil-confirm every installed row's id
#   Scripts/injection-matrix.sh --row <name>   # run one row
#   Scripts/injection-matrix.sh --run-log <path>   # custom evidence location (run log)
#   Scripts/injection-matrix.sh                # the full run, and the tally

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CHECKLIST="$REPO_ROOT/docs/SMOKE_CHECKLIST.md"

# The fixed phrase, inherited from the checklist's ladder matrix (SMOKE_CHECKLIST.md:398) rather
# than re-invented, so this harness's byte-compare is comparable to steps 22-35's.
PHRASE="the quick brown fox jumps over the lazy dog"

# The row table — DATA, not decisions (the `SeededInjectionAllowlist` pattern). Each row:
#
#   name|application|bundle-id|class|seeded|expected-rung|field to click into
#
# `expected-rung` is the closed vocabulary the ladder's log uses, plus `none` for the two
# refusal rows where no rung may be attempted at all. It is the STEADY-STATE expectation: the
# baseline run (checklist step 87) is what calibrates it, and a promotion candidate reads
# `clipboardPaste` until step 91 observes it flip.
#
# The class column is the invariant. A row whose application is not installed is swapped for a
# same-class one and the swap is recorded in the tracked table — the brand was never the point.
#
# THE BUNDLE ID COLUMN IS LOAD-BEARING, and it is why `--verify-bundle-ids` exists. The memory
# keys on it, the seeds are written in it, and a wrong-but-plausible identifier is invisible:
# it passes every test in the suite and silently seeds, learns and pins nothing at all. C8
# shipped with `com.google.docs` in its plan — an identifier no application has ever reported —
# and the only thing that caught it was reading a real Info.plist. So:
#
#   --verify-bundle-ids   reads CFBundleIdentifier from each installed application and compares
#   --self-check          cross-checks the `seeded` column against the shipped Swift seed files
#
# The second is the one that runs in CI. It cannot tell you an identifier is *correct* — only a
# real Info.plist can — but it can tell you the harness and the shipped seeds disagree about
# which applications are seeded, which is the same defect one step later.
ROWS=(
  "Notes|Notes|com.apple.Notes|native-appkit|allowlist|accessibility|a new note"
  "Mail|Mail|com.apple.mail|native-appkit|allowlist|accessibility|the body of a new message"
  "TextEdit|TextEdit|com.apple.TextEdit|native-appkit|allowlist|accessibility|a plain-text document (⌘⇧T)"
  "Xcode|Xcode|com.apple.dt.Xcode|native-appkit|no|clipboardPaste|a comment line in a source file"
  "Messages|Messages|com.apple.MobileSMS|native-appkit|no|clipboardPaste|the message compose field"
  "Telegram|Telegram|ru.keepcoder.Telegram|native-appkit|no|clipboardPaste|a chat input"
  "VSCode|Visual Studio Code|com.microsoft.VSCode|electron|no|clipboardPaste|an untitled text buffer"
  "Teams|Microsoft Teams|com.microsoft.teams2|electron|no|clipboardPaste|a message input"
  "Discord|Discord|com.hnc.Discord|electron|no|clipboardPaste|a message input"
  "ChatGPT|ChatGPT|com.openai.codex|electron|no|clipboardPaste|a conversation input"
  "Obsidian|Obsidian|md.obsidian|electron|no|clipboardPaste|a new note"
  "Safari|Safari|com.apple.Safari|browser|no|clipboardPaste|a plain web input"
  "Chrome|Google Chrome|com.google.Chrome|browser|hostile|clipboardPaste|a plain web input"
  "GoogleDocs|Google Chrome|com.google.Chrome|browser-custom-editor|hostile|clipboardPaste|a Google Docs document body"
  "Firefox|Firefox|org.mozilla.firefox|browser|no|clipboardPaste|a plain web input"
  "Terminal|Terminal|com.apple.Terminal|terminal|no|clipboardPaste|a shell prompt (do not press return)"
  "Warp|Warp|dev.warp.Warp-Stable|terminal|no|clipboardPaste|a shell prompt (do not press return)"
  "Ghostty|Ghostty|com.mitchellh.ghostty|terminal|no|clipboardPaste|a shell prompt (do not press return)"
  "IntelliJ|IntelliJ IDEA|com.jetbrains.intellij|java-awt|no|clipboardPaste|an editor buffer"
  "Zed|Zed|dev.zed.Zed|native-other|no|clipboardPaste|an untitled buffer"
  "Passwords|Passwords|com.apple.Passwords|known-hostile|—|none|a password field"
  "PasswordField|Safari|com.apple.Safari|known-hostile|—|none|a password field on any sign-in page"
)

# The shipped seed data, as files rather than as copies. The self-check greps these, so the
# harness cannot claim an application is seeded when the code says otherwise.
ALLOWLIST_SEED="$REPO_ROOT/Sources/VoccaInject/Allowlist/SeededInjectionAllowlist.swift"
HOSTILE_SEED="$REPO_ROOT/Sources/VoccaInject/Allowlist/SeededHostileApps.swift"

# The closed rung vocabulary a row may expect. `none` is the refusal rows'.
VALID_RUNGS=("accessibility" "clipboardPaste" "keystrokeSynthesis" "none")

# The run log: one JSONL line per completed row, created at run start. The default sits beside
# the strategy memory under Application Support; `--run-log <path>` overrides the file outright
# (PRD N1 — the custom evidence location).
RUN_LOG_DIR="${RUN_LOG_DIR:-$HOME/Library/Application Support/Vocca/matrix-runs}"
RUN_LOG=""

# The deliverable-row denominator (spec Decision 5): every row whose expected rung is not
# `none`. The refusal rows are excluded from numerator AND denominator and are recorded
# separately under the zero-loss invariant — a refusal is not a failed delivery.

field() { printf '%s' "$1" | cut -d'|' -f"$2"; }

usage() {
    sed -n '16,55p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# ---------------------------------------------------------------------------
# The run log: one JSONL line per completed row, appended where the verdict is known. The file
# is created at run start (`start_run_log`), and every return path of `run_row` logs exactly one
# line — including skips, voids and refusals — so a run's evidence is complete even when the run
# is not.
# ---------------------------------------------------------------------------
escape_json() {
    # JSON string escaping for the no-jq fallback. The note field carries only fixed script
    # text, so backslash and double-quote are the only bytes that could break the shape.
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

start_run_log() {
    # One file per run, created up front so the printed path is citable in the tracked table.
    # Append-only: reusing a `--run-log` path keeps the earlier run's lines.
    if [ -z "$RUN_LOG" ]; then
        RUN_LOG="$RUN_LOG_DIR/$(date +%Y%m%d-%H%M%S).jsonl"
    fi
    mkdir -p "$(dirname "$RUN_LOG")"
    [ -f "$RUN_LOG" ] || : > "$RUN_LOG"
    printf 'run log: %s\n' "$RUN_LOG"
}

log_run_row() {
    # One JSONL line per completed row: date, row name, observed rung (null when none was
    # observed), bytes matched (null when the byte-compare did not run), verdict, note.
    # `null`/`true`/`false` arrive as JSON literals; rung names and notes as plain strings.
    local row_name="$1" observed_rung="$2" bytes_matched="$3" verdict="$4" note="$5"
    [ -n "$RUN_LOG" ] || return 0
    local now rung_json bytes_json line
    now="$(date +%Y-%m-%dT%H:%M:%S)"
    if [ "$observed_rung" = "null" ]; then rung_json="null"; else rung_json="\"$observed_rung\""; fi
    if [ "$bytes_matched" = "null" ]; then bytes_json="null"; else bytes_json="$bytes_matched"; fi
    if command -v jq >/dev/null 2>&1; then
        line="$(jq -nc --arg date "$now" --arg row "$row_name" \
            --argjson rung "$rung_json" --argjson bytes_matched "$bytes_json" \
            --arg verdict "$verdict" --arg note "$note" \
            '{date: $date, row: $row, rung: $rung, bytes_matched: $bytes_matched, verdict: $verdict, note: $note}')"
    else
        line="{\"date\": \"$now\", \"row\": \"$row_name\", \"rung\": $rung_json, \"bytes_matched\": $bytes_json, \"verdict\": \"$verdict\", \"note\": \"$(escape_json "$note")\"}"
    fi
    printf '%s\n' "$line" >> "$RUN_LOG"
}

# ---------------------------------------------------------------------------
# --self-check: everything about this harness a machine can verify.
#
# It needs no application, no grant and no window server, which is what makes it the one half
# of this aspect that could ever run in CI. It fails loudly rather than warning: a row table
# that has drifted from the checklist is exactly the silent rot this check exists to catch.
# ---------------------------------------------------------------------------
self_check() {
    local failures=0
    local deliverable=0
    local seen=""

    if [ ! -f "$CHECKLIST" ]; then
        printf 'FAIL: the smoke checklist is missing at %s\n' "$CHECKLIST" >&2
        return 1
    fi

    for row in "${ROWS[@]}"; do
        local name application bundle class seeded rung target
        name="$(field "$row" 1)"
        application="$(field "$row" 2)"
        bundle="$(field "$row" 3)"
        class="$(field "$row" 4)"
        seeded="$(field "$row" 5)"
        rung="$(field "$row" 6)"
        target="$(field "$row" 7)"

        for value in "$name" "$application" "$bundle" "$class" "$seeded" "$rung" "$target"; do
            if [ -z "$value" ]; then
                printf 'FAIL: row "%s" has an empty column\n' "$row" >&2
                failures=$((failures + 1))
            fi
        done

        case " $seen " in
            *" $name "*)
                printf 'FAIL: duplicate row name "%s"\n' "$name" >&2
                failures=$((failures + 1))
                ;;
        esac
        seen="$seen $name"

        local known=0
        for valid in "${VALID_RUNGS[@]}"; do
            [ "$rung" = "$valid" ] && known=1
        done
        if [ "$known" -eq 0 ]; then
            printf 'FAIL: row "%s" expects rung "%s", which the ladder never names\n' \
                "$name" "$rung" >&2
            failures=$((failures + 1))
        fi

        if [ "$class" = "known-hostile" ] && [ "$rung" != "none" ]; then
            printf 'FAIL: known-hostile row "%s" expects a rung. Secure Input refuses before\n' \
                "$name" >&2
            printf '      any rung is attempted — expecting one would make the row a pass for\n' >&2
            printf '      the failure it exists to forbid.\n' >&2
            failures=$((failures + 1))
        fi
        if [ "$class" != "known-hostile" ] && [ "$rung" = "none" ]; then
            printf 'FAIL: row "%s" expects no rung but is not a known-hostile row\n' "$name" >&2
            failures=$((failures + 1))
        fi

        [ "$rung" != "none" ] && deliverable=$((deliverable + 1))

        case "$bundle" in
            *.*) ;;
            *)
                printf 'FAIL: row "%s" has "%s" where a reverse-DNS bundle identifier belongs.\n' \
                    "$name" "$bundle" >&2
                failures=$((failures + 1))
                ;;
        esac
        case "$bundle" in
            *" "*)
                printf 'FAIL: row "%s" has a display name, not a bundle identifier: "%s"\n' \
                    "$name" "$bundle" >&2
                failures=$((failures + 1))
                ;;
        esac

        # The seed cross-check. This is the half that runs in CI, and the defect it is aimed at
        # is the one C8 actually shipped in its plan: an identifier that looks right, seeds
        # nothing, and passes every test in the suite. It cannot tell you an identifier is
        # correct — only `--verify-bundle-ids` against a real Info.plist can — but it can tell
        # you the harness and the shipped Swift seeds disagree about what is seeded.
        local in_allowlist=0 in_hostile=0
        grep -q "\"$bundle\"" "$ALLOWLIST_SEED" && in_allowlist=1
        grep -q "\"$bundle\"" "$HOSTILE_SEED" && in_hostile=1
        case "$seeded" in
            allowlist)
                if [ "$in_allowlist" -eq 0 ]; then
                    printf 'FAIL: row "%s" claims the accessibility allowlist seeds %s, but\n' \
                        "$name" "$bundle" >&2
                    printf '      SeededInjectionAllowlist.swift does not name it.\n' >&2
                    failures=$((failures + 1))
                fi
                ;;
            hostile)
                if [ "$in_hostile" -eq 0 ]; then
                    printf 'FAIL: row "%s" claims %s is seeded hostile, but\n' "$name" "$bundle" >&2
                    printf '      SeededHostileApps.swift does not name it. The row expects a\n' >&2
                    printf '      first attempt the memory will not actually produce.\n' >&2
                    failures=$((failures + 1))
                fi
                ;;
            no)
                if [ "$in_allowlist" -eq 1 ] || [ "$in_hostile" -eq 1 ]; then
                    printf 'FAIL: row "%s" claims %s is unseeded, but a shipped seed file\n' \
                        "$name" "$bundle" >&2
                    printf '      names it. The expected rung is calibrated against the wrong\n' >&2
                    printf '      starting state.\n' >&2
                    failures=$((failures + 1))
                fi
                ;;
        esac

        if ! grep -q "matrix-row: $name\b" "$CHECKLIST"; then
            printf 'FAIL: row "%s" is not named in the smoke checklist. The table here and the\n' \
                "$name" >&2
            printf '      rows there are one artifact in two files; a row that exists in only\n' >&2
            printf '      one of them is a row nobody runs or a row nobody defined.\n' >&2
            failures=$((failures + 1))
        fi
    done

    if [ "$deliverable" -lt 20 ]; then
        printf 'FAIL: %d deliverable rows. ROADMAP.md:172 judges P2 on a 20+ app matrix.\n' \
            "$deliverable" >&2
        failures=$((failures + 1))
    fi

    if [ "$failures" -ne 0 ]; then
        printf '\n%d self-check failure(s).\n' "$failures" >&2
        return 1
    fi

    printf 'self-check passed: %d rows, %d deliverable, all named in the checklist.\n' \
        "${#ROWS[@]}" "$deliverable"
    printf 'first-method-success bar: %d of %d deliverable rows (>=95%%).\n' \
        "$(( (deliverable * 95 + 99) / 100 ))" "$deliverable"
}

# ---------------------------------------------------------------------------
# --dry-run: the table, with install status. Touches nothing, never fails on a missing app —
# a machine without the matrix applications is not a broken script.
# ---------------------------------------------------------------------------
dry_run() {
    printf '%-14s %-24s %-22s %-10s %s\n' ROW APPLICATION CLASS EXPECTED INSTALLED
    for row in "${ROWS[@]}"; do
        local name application class rung status
        name="$(field "$row" 1)"
        application="$(field "$row" 2)"
        class="$(field "$row" 4)"
        rung="$(field "$row" 6)"
        if open -Ra "$application" >/dev/null 2>&1; then
            status="yes"
        else
            status="SKIP (not installed)"
        fi
        printf '%-14s %-24s %-22s %-10s %s\n' "$name" "$application" "$class" "$rung" "$status"
    done
}

# ---------------------------------------------------------------------------
# --verify-bundle-ids: the only check that can tell a *correct* identifier from a plausible one.
#
# Reads CFBundleIdentifier out of each installed application's Info.plist and compares it to the
# table. Not runnable in CI — it needs the applications — but it needs no grant, no window
# server and no dictation, so it is the cheapest real verification in this file, and the one
# that catches the defect the seeds are most exposed to.
#
# Exit 1 on any MISMATCH. A missing application is not a failure: it is unverified, and says so.
# ---------------------------------------------------------------------------
verify_bundle_ids() {
    local mismatches=0 confirmed=0 unverified=0
    printf '%-14s %-26s %-30s %s\n' ROW EXPECTED-ID FOUND STATUS
    for row in "${ROWS[@]}"; do
        local name application bundle path found
        name="$(field "$row" 1)"
        application="$(field "$row" 2)"
        bundle="$(field "$row" 3)"

        found=""
        for dir in /Applications /System/Applications /System/Applications/Utilities \
            "$HOME/Applications"; do
            if [ -d "$dir/$application.app" ]; then
                path="$dir/$application.app"
                found="$(plutil -extract CFBundleIdentifier raw "$path/Contents/Info.plist" \
                    2>/dev/null || true)"
                break
            fi
        done

        if [ -z "$found" ]; then
            printf '%-14s %-26s %-30s %s\n' "$name" "$bundle" "—" "UNVERIFIED (not installed)"
            unverified=$((unverified + 1))
        elif [ "$found" = "$bundle" ]; then
            printf '%-14s %-26s %-30s %s\n' "$name" "$bundle" "$found" "CONFIRMED"
            confirmed=$((confirmed + 1))
        else
            printf '%-14s %-26s %-30s %s\n' "$name" "$bundle" "$found" "MISMATCH"
            mismatches=$((mismatches + 1))
        fi
    done

    printf '\n%d confirmed, %d unverified (not installed), %d mismatched.\n' \
        "$confirmed" "$unverified" "$mismatches"
    if [ "$mismatches" -ne 0 ]; then
        printf 'A mismatched identifier seeds, learns and pins nothing while passing every\n' >&2
        printf 'test in the suite. Fix the table — and the shipped seed, if the row is seeded.\n' >&2
        return 1
    fi
    if [ "$unverified" -ne 0 ]; then
        printf 'Unverified rows are guesses until the application is installed and re-checked.\n'
    fi
}

# ---------------------------------------------------------------------------
# The live run. One row at a time, the founder in the loop for the two things a script cannot
# honestly do.
# ---------------------------------------------------------------------------
run_row() {
    local row="$1"
    local name application rung target
    name="$(field "$row" 1)"
    application="$(field "$row" 2)"
    rung="$(field "$row" 6)"
    target="$(field "$row" 7)"

    printf '\n=== %s (%s) — expecting %s ===\n' "$name" "$application" "$rung"

    if ! open -Ra "$application" >/dev/null 2>&1; then
        printf 'SKIP: %s is not installed. Swap in a same-class application and record the\n' \
            "$application"
        printf '      swap in the tracked table — the class is the invariant, not the brand.\n'
        log_run_row "$name" null null skipped "not installed: $application"
        return 2
    fi
    open -a "$application"

    if [ "$rung" = "none" ]; then
        printf 'Refusal row. Get a transcript into the FAILSAFE, then focus %s.\n' "$target"
        printf 'PASS needs all four: the log records attempted: [] (no rung — not even\n'
        printf 'clipboard), the failsafe shows the password-field copy, the transcript is still\n'
        printf 'copyable, and strategies.json gained nothing for this app.\n'
        read -r -p 'Did all four hold? [y/N] ' answer
        if [ "$answer" = "y" ]; then
            log_run_row "$name" null null refusal ""
            return 0
        fi
        log_run_row "$name" null null failed "refusal checks did not all hold"
        return 1
    fi

    printf 'Click into %s, then dictate: "%s"\n' "$target" "$PHRASE"
    printf '(The script cannot press ⌥Space — the tap needs the Accessibility grant and the\n'
    printf 'session needs a microphone.)\n'
    read -r -p 'Press return once the text has landed. '

    # The comparison half, which is the part worth automating. A denied Automation grant shows
    # up as stale clipboard content, and that is a VOID rather than a failure — asserting a
    # byte mismatch without knowing the selection was made would break the checklist's first
    # preamble rule.
    printf '%s' "vocca-matrix-void-sentinel" | pbcopy
    osascript -e 'tell application "System Events" to keystroke "a" using command down' \
        >/dev/null 2>&1 || true
    osascript -e 'tell application "System Events" to keystroke "c" using command down' \
        >/dev/null 2>&1 || true
    sleep 1
    local captured
    captured="$(pbpaste)"

    if [ "$captured" = "vocca-matrix-void-sentinel" ]; then
        printf 'VOID: the copy never happened — the sentinel is still on the clipboard, so this\n'
        printf '      terminal has no Automation grant for %s. Grant it and re-run the row;\n' \
            "$application"
        printf '      a byte-compare asserted here would be a failure about the wrong thing.\n'
        log_run_row "$name" null null voided "no Automation grant"
        return 3
    fi

    if [ "$captured" != "$PHRASE" ]; then
        printf 'FAIL (bytes): the field does not hold the transcript.\n'
        printf '  expected: %s\n' "$PHRASE"
        printf '  captured: %s\n' "$captured"
        printf 'If the log named .accessibility, this is the read-back verification lying —\n'
        printf 'a bug, not a fallback.\n'
        log_run_row "$name" null false failed "byte mismatch"
        return 1
    fi

    read -r -p "Did the ladder's log name .$rung as the landing rung? [y/N] " answer
    if [ "$answer" != "y" ]; then
        printf 'MISS: delivered, but not by the memory-chosen first rung. That is a\n'
        printf '      demote-on-fail signal for the memory and a miss for first-method-success.\n'
        log_run_row "$name" null true failed "log did not name .$rung"
        return 1
    fi
    log_run_row "$name" "$rung" true pass ""
    printf 'PASS: bytes match and the log names .%s.\n' "$rung"
    return 0
}

full_run() {
    local passed=0 failed=0 skipped=0 voided=0 refusals_ok=0 refusals_bad=0
    for row in "${ROWS[@]}"; do
        local rung
        rung="$(field "$row" 6)"
        set +e
        run_row "$row"
        local status=$?
        set -e
        case "$status" in
            0) if [ "$rung" = "none" ]; then refusals_ok=$((refusals_ok + 1));
               else passed=$((passed + 1)); fi ;;
            2) skipped=$((skipped + 1)) ;;
            3) voided=$((voided + 1)) ;;
            *) if [ "$rung" = "none" ]; then refusals_bad=$((refusals_bad + 1));
               else failed=$((failed + 1)); fi ;;
        esac
    done

    local deliverable=$((passed + failed))
    printf '\n--- matrix summary ---\n'
    printf 'deliverable rows run: %d (passed %d, missed %d)\n' "$deliverable" "$passed" "$failed"
    printf 'skipped (not installed): %d   voided (no Automation grant): %d\n' "$skipped" "$voided"
    printf 'refusal rows: %d correct, %d wrong\n' "$refusals_ok" "$refusals_bad"
    if [ "$deliverable" -gt 0 ]; then
        printf 'first-method-success: %d/%d (%d%%)\n' \
            "$passed" "$deliverable" "$((passed * 100 / deliverable))"
    fi
    printf '\nA skipped or voided row is not a pass. Append one row to the tracked table in\n'
    printf 'docs/SMOKE_CHECKLIST.md with the release, the date, the counts above and any swaps.\n'
}

MODE="run"
ROW_NAME=""
while [ $# -gt 0 ]; do
    case "$1" in
        --self-check) MODE="self-check" ;;
        --dry-run) MODE="dry-run" ;;
        --verify-bundle-ids) MODE="verify-bundle-ids" ;;
        --row)
            MODE="row"
            shift
            ROW_NAME="${1:-}"
            if [ -z "$ROW_NAME" ]; then
                printf 'error: --row needs a row name (see --dry-run for the list)\n' >&2
                exit 2
            fi
            ;;
        --run-log)
            shift
            RUN_LOG="${1:-}"
            if [ -z "$RUN_LOG" ]; then
                printf 'error: --run-log needs a path\n' >&2
                exit 2
            fi
            ;;
        -h|--help) usage; exit 0 ;;
        *)
            printf 'error: unknown argument "%s"\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
    shift
done

case "$MODE" in
    self-check) self_check ;;
    dry-run) dry_run ;;
    verify-bundle-ids) verify_bundle_ids ;;
    row)
        for row in "${ROWS[@]}"; do
            if [ "$(field "$row" 1)" = "$ROW_NAME" ]; then
                start_run_log
                run_row "$row"
                exit $?
            fi
        done
        printf 'error: no row named "%s" (see --dry-run for the list)\n' "$ROW_NAME" >&2
        exit 2
        ;;
    run) start_run_log; full_run ;;
esac
