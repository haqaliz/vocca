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

# Signs Vocca.app: inner binaries first (frameworks, if any are ever embedded), then the bundle
# itself, then verifies. Run Scripts/dev-identity.sh once beforehand — this script does not
# create an identity, it only uses one.
#
# Usage: Scripts/sign.sh [path/to/Vocca.app]
#   Defaults to .build/xcode/Build/Products/Debug/Vocca.app, matching the xcodebuild invocation
#   documented in Tests/HarnessTests/BundleConfigurationTests.swift.
#
# The identity is overridable:
#   VOCCA_DEV_IDENTITY_NAME="Developer ID Application: ..." Scripts/sign.sh path/to/Vocca.app

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/signing-env.sh
source "$SCRIPT_DIR/lib/signing-env.sh"

BUNDLE_PATH="${1:-$REPO_ROOT/.build/xcode/Build/Products/Debug/Vocca.app}"

log() { printf '%s\n' "$*"; }
fail() {
    printf 'sign.sh: error: %s\n' "$*" >&2
    exit 1
}

[ -d "$BUNDLE_PATH" ] || fail "No app bundle at $BUNDLE_PATH. Build it first, e.g.:
  xcodebuild -project Vocca.xcodeproj -scheme Vocca -configuration Debug -derivedDataPath .build/xcode build"

# Best-effort: if this is our own dev keychain and it has relocked (e.g. after a reboot), unlock
# it with the password we stashed when we created it. A no-op for any other identity/keychain.
vocca_unlock_dev_keychain_if_present || true

security find-identity -v -p codesigning 2>/dev/null | grep -qF "\"$VOCCA_DEV_IDENTITY_NAME\"" \
    || fail "No codesigning identity named '$VOCCA_DEV_IDENTITY_NAME' is available \
('security find-identity -v -p codesigning' does not list it). Run Scripts/dev-identity.sh \
first, or set VOCCA_DEV_IDENTITY_NAME to an identity that does exist."

# codesign does NOT carry entitlements forward when re-signing something that is already signed
# — omit --entitlements here and the new signature has none at all, silently. That is what
# CODE_SIGN_ENTITLEMENTS at build time supplies for xcodebuild's own signing pass, and it must be
# passed again explicitly for this one.
APP_ENTITLEMENTS="$REPO_ROOT/App/Vocca.entitlements"

sign_one() {
    local target="$1"
    local entitlements_args=()
    if [ "$target" = "$BUNDLE_PATH" ]; then
        entitlements_args=(--entitlements "$APP_ENTITLEMENTS")
    fi
    local stderr_file
    stderr_file="$(mktemp)"
    log "Signing $target"
    if codesign --force --options runtime "${entitlements_args[@]}" --timestamp \
        --sign "$VOCCA_DEV_IDENTITY_NAME" "$target" 2>"$stderr_file"; then
        rm -f "$stderr_file"
        return 0
    fi
    # --timestamp calls out to Apple's timestamp authority; offline, or against some self-signed
    # setups, that call itself is what fails — not the code signing. A secure timestamp is
    # required for notarization but not for local TCC, so retry without it rather than treat this
    # as a hard failure.
    log "  --timestamp failed, retrying without it (a secure timestamp is not required for local TCC):"
    sed 's/^/    /' "$stderr_file" >&2
    rm -f "$stderr_file"
    codesign --force --options runtime "${entitlements_args[@]}" \
        --sign "$VOCCA_DEV_IDENTITY_NAME" "$target"
}

# Inner binaries before the bundle: codesign requires nested frameworks, XPC services, and
# plug-ins to be signed before the outer bundle's seal is computed over them. The main executable
# under Contents/MacOS is never signed separately — signing the bundle directory signs it as part
# of the bundle's own signature. Vocca embeds none of these today —
# BuiltBundleTests.testNoTestOnlyTargetLeakedIntoTheBundle pins Contents/MacOS to exactly one
# executable and the app links no frameworks — but this is written to keep working the moment
# that changes, rather than silently signing only the outer bundle.
for nested_dir in "Frameworks" "PlugIns" "XPCServices"; do
    dir="$BUNDLE_PATH/Contents/$nested_dir"
    [ -d "$dir" ] || continue
    while IFS= read -r -d '' inner; do
        sign_one "$inner"
    done < <(find "$dir" -depth \
        \( -name "*.framework" -o -name "*.dylib" -o -name "*.xpc" -o -name "*.appex" \) \
        -print0)
done

sign_one "$BUNDLE_PATH"

log "Verifying $BUNDLE_PATH"
codesign --verify --strict --verbose=2 "$BUNDLE_PATH"

log "Signed and verified: $BUNDLE_PATH"
codesign -dv "$BUNDLE_PATH" 2>&1 | sed 's/^/  /'
