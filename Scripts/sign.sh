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
#   The default is the *Debug* bundle because that is the daily dev loop. A release build lives
#   somewhere else and must be named explicitly — Scripts/notarize.sh defaults to the Release path
#   and expects a bundle signed by this script, so the release flow is:
#     xcodebuild ... -configuration Release -derivedDataPath .build/xcode-release build
#     Scripts/sign.sh .build/xcode-release/Build/Products/Release/Vocca.app
#     Scripts/notarize.sh
#   Running a bare `Scripts/sign.sh` before `Scripts/notarize.sh` signs the Debug bundle and
#   notarizes an unrelated Release one. See docs/SMOKE_CHECKLIST.md, which spells the order out.
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

# But App/Vocca.entitlements is not the whole entitlement set of a *Debug* bundle, and re-signing
# with it alone is a silent regression.
#
# Xcode injects com.apple.security.get-task-allow into Debug builds (CODE_SIGN_INJECT_BASE_
# ENTITLEMENTS, which the project turns off for Release only). It is what lets a debugger attach.
# Re-signing a Debug bundle against the checked-in file drops it, `codesign` succeeds, the app
# still launches — and then LLDB and Xcode's own debugger attach with a permission error that says
# nothing about signing. Measured before this fix: xcodebuild left the bundle with
# {audio-input, get-task-allow}; a bare `Scripts/sign.sh` — the exact flow the README documents —
# left it with {audio-input}.
#
# The suite did not catch it and structurally cannot: BuildConfiguration.permittedInjectedEntitle-
# ments *permits* get-task-allow on Debug, it does not require it. Requiring it there would be
# wrong too, since a Debug bundle signed by a flow that never injected it is not broken, just not
# debuggable.
#
# So the configuration is read from the bundle itself — the same VoccaBuildConfiguration marker the
# suite trusts, written by the build system during Process Info.plist — and a Debug bundle is
# signed against a temporary copy of the entitlements with get-task-allow added.
DEBUG_ONLY_INJECTED_ENTITLEMENT="com.apple.security.get-task-allow"

bundle_build_configuration() {
    local plist="$BUNDLE_PATH/Contents/Info.plist"
    [ -f "$plist" ] || fail "No Contents/Info.plist inside $BUNDLE_PATH — that is not an app bundle this script built."

    local value
    value="$(plutil -extract VoccaBuildConfiguration raw -o - "$plist" 2>/dev/null)" \
        || fail "$plist has no VoccaBuildConfiguration key, so which configuration built this \
bundle cannot be determined — and the Debug and Release entitlement sets differ. Rebuild from this \
checkout (App/Info.plist declares the key) rather than signing a bundle of unknown provenance."

    case "$value" in
        Debug | Release) printf '%s' "$value" ;;
        *'$('*)
            fail "VoccaBuildConfiguration in $plist is still the unexpanded literal '$value', so \
Xcode did not substitute it. Signing would have to guess the entitlement set; it will not."
            ;;
        *)
            fail "VoccaBuildConfiguration in $plist is '$value', which has no entitlement policy \
here (known: Debug, Release). A third configuration must state its policy in this script and in \
Tests/HarnessTests/BundleConfigurationTests.swift before a bundle built from it can be signed."
            ;;
    esac
}

BUILD_CONFIGURATION="$(bundle_build_configuration)"

# Set to a temp file for Debug; cleaned up on every exit path including `fail`.
EFFECTIVE_ENTITLEMENTS="$APP_ENTITLEMENTS"
TEMP_ENTITLEMENTS=""
trap '[ -n "$TEMP_ENTITLEMENTS" ] && rm -f "$TEMP_ENTITLEMENTS"' EXIT

if [ "$BUILD_CONFIGURATION" = "Debug" ]; then
    TEMP_ENTITLEMENTS="$(mktemp -t vocca-debug-entitlements.XXXXXX)"
    cp "$APP_ENTITLEMENTS" "$TEMP_ENTITLEMENTS"
    # PlistBuddy, not `plutil -insert`: plutil treats `.` in a key path as a nesting separator, and
    # every entitlement name is dotted. PlistBuddy separates path components with `:`, so a dotted
    # key is addressed literally.
    /usr/libexec/PlistBuddy -c "Add :$DEBUG_ONLY_INJECTED_ENTITLEMENT bool true" "$TEMP_ENTITLEMENTS" >/dev/null \
        || fail "Could not add $DEBUG_ONLY_INJECTED_ENTITLEMENT to the temporary Debug entitlements."
    EFFECTIVE_ENTITLEMENTS="$TEMP_ENTITLEMENTS"
    log "Debug bundle: signing with App/Vocca.entitlements + $DEBUG_ONLY_INJECTED_ENTITLEMENT (so a debugger can still attach)."
else
    log "Release bundle: signing with App/Vocca.entitlements exactly — $DEBUG_ONLY_INJECTED_ENTITLEMENT is deliberately absent."
fi

sign_one() {
    local target="$1"
    local entitlements_args=()
    if [ "$target" = "$BUNDLE_PATH" ]; then
        entitlements_args=(--entitlements "$EFFECTIVE_ENTITLEMENTS")
    fi
    local stderr_file
    stderr_file="$(mktemp)"
    log "Signing $target"
    # The ${var[@]+"${var[@]}"} form: the plain "${entitlements_args[@]}" expansion under `set -u`
    # is "unbound variable" on bash 3.2 (the macOS default) whenever the array is empty — which it
    # is for every nested binary, since only the outer bundle gets entitlements. This form expands
    # to nothing for an empty array and to the quoted elements otherwise.
    if codesign --force --options runtime "${entitlements_args[@]+"${entitlements_args[@]}"}" --timestamp \
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
    codesign --force --options runtime "${entitlements_args[@]+"${entitlements_args[@]}"}" \
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

# Read the entitlements back out of the signature rather than trusting that codesign applied what
# it was handed. This is the same principle as testBuiltBundleIsSignedWithTheHardenedRuntime:
# passing a flag and the flag taking effect are two different claims, and the whole reason this
# script needed fixing is that the second one failed silently.
embedded_entitlements="$(codesign -d --entitlements :- --xml "$BUNDLE_PATH" 2>/dev/null || true)"

if [ "$BUILD_CONFIGURATION" = "Debug" ]; then
    case "$embedded_entitlements" in
        *"$DEBUG_ONLY_INJECTED_ENTITLEMENT"*) ;;
        *)
            fail "This is a Debug bundle but the signature it now carries has no \
$DEBUG_ONLY_INJECTED_ENTITLEMENT, so no debugger will be able to attach to it. The signature was \
applied; the entitlement was not. Embedded entitlements:
$embedded_entitlements"
            ;;
    esac
else
    case "$embedded_entitlements" in
        *"$DEBUG_ONLY_INJECTED_ENTITLEMENT"*)
            fail "This is a Release bundle and its signature carries \
$DEBUG_ONLY_INJECTED_ENTITLEMENT, which lets any same-user process read this process's memory — \
live audio and transcripts — and which notarization rejects outright. Embedded entitlements:
$embedded_entitlements"
            ;;
    esac
fi

log "Signed and verified: $BUNDLE_PATH"
codesign -dv "$BUNDLE_PATH" 2>&1 | sed 's/^/  /'
log "Embedded entitlements:"
printf '%s\n' "$embedded_entitlements" | sed 's/^/  /'
