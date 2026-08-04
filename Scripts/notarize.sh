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

# Submits Vocca.app to Apple's notary service and staples the ticket.
#
# THIS SCRIPT HAS NEVER BEEN RUN END TO END. This machine has no Apple Developer ID and no
# notarytool credentials, and notarization requires both: the bundle must be signed with a real
# Developer ID Application identity (a self-signed identity is rejected outright), and notarytool
# needs an App Store Connect API key or an Apple ID app-specific password. Neither exists yet.
# What is verified is only the credential-detection-and-skip path below.
#
# Usage: Scripts/notarize.sh [path/to/Vocca.app]
#   Defaults to .build/xcode-release/Build/Products/Release/Vocca.app — the path
#   docs/SMOKE_CHECKLIST.md and .github/workflows/ci.yml both use for a Release build. It was
#   previously .build/xcode/Build/Products/Release/… , which is the *Debug* derived-data directory
#   with a Release product path glued on: a location nothing in this repository ever writes.
#
#   THE RELEASE FLOW, IN ORDER. Scripts/sign.sh defaults to the Debug bundle, so a bare
#   `Scripts/sign.sh` before this script signs one bundle and notarizes a different one. Pass the
#   path:
#     xcodebuild -project Vocca.xcodeproj -scheme Vocca -configuration Release \
#                -derivedDataPath .build/xcode-release build
#     Scripts/sign.sh .build/xcode-release/Build/Products/Release/Vocca.app
#     Scripts/notarize.sh
#
# Credentials: this script uses a previously stored notarytool keychain profile (see
# `xcrun notarytool store-credentials --help`). Configure one with:
#   xcrun notarytool store-credentials "vocca-notary" \
#     --apple-id "you@example.com" --team-id TEAMID --password "app-specific-password"
# and set VOCCA_NOTARY_PROFILE to its name if not "vocca-notary".

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

BUNDLE_PATH="${1:-$REPO_ROOT/.build/xcode-release/Build/Products/Release/Vocca.app}"
NOTARY_PROFILE="${VOCCA_NOTARY_PROFILE:-vocca-notary}"

log() { printf '%s\n' "$*"; }
fail() {
    printf 'notarize.sh: error: %s\n' "$*" >&2
    exit 1
}

skip() {
    cat <<EOF
notarize.sh: SKIPPING — $1

Nothing is broken; this is expected until a Developer ID and notarytool credentials exist.
To configure them:
  1. Enroll in the Apple Developer Program and create a "Developer ID Application" certificate.
  2. xcrun notarytool store-credentials "$NOTARY_PROFILE" \\
       --apple-id "you@example.com" --team-id TEAMID --password "app-specific-password"
  3. Build Release, then sign it with that identity:
       xcodebuild -project Vocca.xcodeproj -scheme Vocca -configuration Release \\
                  -derivedDataPath .build/xcode-release build
       VOCCA_DEV_IDENTITY_NAME="Developer ID Application: ..." \\
         Scripts/sign.sh "$BUNDLE_PATH"
     then rerun this script.
EOF
    exit 0
}

command -v xcrun >/dev/null 2>&1 || fail "'xcrun' is required but not on PATH."

# Credential detection, and why it is not just `notarytool history`.
#
# The obvious probe — run `notarytool history` and treat any failure as "no credentials" — is
# wrong, because `history` is a call to Apple's notary *service*. On a machine with perfectly good
# credentials and no network it fails, and the script then prints "no notarytool credentials found"
# and exits 0. That is the worst possible answer: a false statement about the machine's
# configuration, delivered as a successful run, sending whoever reads it to re-create credentials
# that already exist.
#
# The two cases are separated. Missing credentials is a *local* fact and is asked locally:
# `store-credentials` saves a generic-password keychain item under the notary tool's service name,
# so its absence is decidable offline with no network call at all. Only if that item exists is the
# service contacted, and a failure at that point is reported as what it is — reachability or
# authorisation — rather than silently rewritten into "no credentials".
NOTARY_KEYCHAIN_SERVICE="com.apple.gke.notary.tool"

credential_item_present() {
    security find-generic-password -s "$NOTARY_KEYCHAIN_SERVICE" -a "$NOTARY_PROFILE" \
        >/dev/null 2>&1
}

if ! credential_item_present; then
    # Corroborate before claiming it. The keychain service name above is Apple's, not ours, and it
    # is not contractual — if a future notarytool stores its profiles somewhere else, the local
    # probe would report "no credentials" for a machine that has them. So the offline answer is
    # only trusted when the service agrees, and a network failure here is surfaced rather than
    # folded into the skip.
    probe_output="$(xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" 2>&1)" \
        && probe_status=0 || probe_status=$?

    if [ "$probe_status" -eq 0 ]; then
        log "notarize.sh: no keychain item under service '$NOTARY_KEYCHAIN_SERVICE' for profile \
'$NOTARY_PROFILE', but notarytool authenticated anyway — the local probe is out of date. \
Continuing; update NOTARY_KEYCHAIN_SERVICE in this script."
    elif printf '%s' "$probe_output" | grep -qiE \
        'could not connect|network|timed out|timeout|unreachable|offline|no route to host|nsurlerror|connection (refused|reset|lost)'; then
        fail "Cannot determine whether notarytool credentials exist for profile \
'$NOTARY_PROFILE': the notary service is unreachable. This is a network failure, NOT a missing \
credential — do not re-run 'store-credentials' on the strength of this message. Retry when \
online. notarytool said:
$probe_output"
    else
        skip "no notarytool credentials found for the keychain profile '$NOTARY_PROFILE' (no \
item under service '$NOTARY_KEYCHAIN_SERVICE', and notarytool rejected the profile). notarytool \
said:
$probe_output"
    fi
fi

[ -d "$BUNDLE_PATH" ] || fail "No app bundle at $BUNDLE_PATH. Build and sign it first — note that \
Scripts/sign.sh defaults to the DEBUG bundle, so the Release path has to be passed to it \
explicitly:
  xcodebuild -project Vocca.xcodeproj -scheme Vocca -configuration Release \\
             -derivedDataPath .build/xcode-release build
  Scripts/sign.sh \"$BUNDLE_PATH\"
  Scripts/notarize.sh"

ARCHIVE_PATH="$(mktemp -d)/Vocca.zip"
trap 'rm -rf "$(dirname "$ARCHIVE_PATH")"' EXIT

log "Archiving $BUNDLE_PATH for submission ..."
ditto -c -k --keepParent "$BUNDLE_PATH" "$ARCHIVE_PATH"

log "Submitting to notarytool (profile: $NOTARY_PROFILE) ..."
xcrun notarytool submit "$ARCHIVE_PATH" --keychain-profile "$NOTARY_PROFILE" --wait

log "Stapling the notarization ticket ..."
xcrun stapler staple "$BUNDLE_PATH"

log "Notarized and stapled: $BUNDLE_PATH"
