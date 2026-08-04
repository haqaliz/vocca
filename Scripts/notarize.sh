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
#   Defaults to .build/xcode/Build/Products/Release/Vocca.app.
#
# Credentials: this script uses a previously stored notarytool keychain profile (see
# `xcrun notarytool store-credentials --help`). Configure one with:
#   xcrun notarytool store-credentials "vocca-notary" \
#     --apple-id "you@example.com" --team-id TEAMID --password "app-specific-password"
# and set VOCCA_NOTARY_PROFILE to its name if not "vocca-notary".

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

BUNDLE_PATH="${1:-$REPO_ROOT/.build/xcode/Build/Products/Release/Vocca.app}"
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
  3. Re-sign the Release build with that identity (see Config/Signing.local.xcconfig / README),
     then rerun this script.
EOF
    exit 0
}

command -v xcrun >/dev/null 2>&1 || fail "'xcrun' is required but not on PATH."

if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    skip "no notarytool credentials found under the keychain profile '$NOTARY_PROFILE'."
fi

[ -d "$BUNDLE_PATH" ] || fail "No app bundle at $BUNDLE_PATH. Build and sign it first \
(see Scripts/sign.sh)."

ARCHIVE_PATH="$(mktemp -d)/Vocca.zip"
trap 'rm -rf "$(dirname "$ARCHIVE_PATH")"' EXIT

log "Archiving $BUNDLE_PATH for submission ..."
ditto -c -k --keepParent "$BUNDLE_PATH" "$ARCHIVE_PATH"

log "Submitting to notarytool (profile: $NOTARY_PROFILE) ..."
xcrun notarytool submit "$ARCHIVE_PATH" --keychain-profile "$NOTARY_PROFILE" --wait

log "Stapling the notarization ticket ..."
xcrun stapler staple "$BUNDLE_PATH"

log "Notarized and stapled: $BUNDLE_PATH"
