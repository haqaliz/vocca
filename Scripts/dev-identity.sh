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

# Creates (or reuses) a stable, self-signed codesigning identity named "Vocca Development", so
# that Microphone/Accessibility TCC grants — which macOS keys on the code signature, not just the
# bundle identifier — survive rebuilds. Ad-hoc signing (CODE_SIGN_IDENTITY = "-") mints a new
# identity on every build, which silently revokes those grants each time.
#
# Idempotent: running this twice reuses the existing identity rather than creating a second one.
# Never falls back to ad-hoc — any failure here is a hard exit, not a silent downgrade, because
# ad-hoc signing is precisely the problem this script exists to remove.
#
# The identity lives in a keychain this script creates and owns (~/Library/Keychains/
# vocca-dev.keychain-db), not the user's login keychain, so it can unlock itself with a password
# it generated rather than ever touching the user's login password.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/signing-env.sh
source "$SCRIPT_DIR/lib/signing-env.sh"

SIGNING_LOCAL_XCCONFIG="$REPO_ROOT/Config/Signing.local.xcconfig"

# Set by create_identity() while its scratch directory (private key material) is live; cleaned up
# here on any exit path, including `fail`'s `exit 1`.
WORKDIR=""
trap '[ -n "$WORKDIR" ] && rm -rf "$WORKDIR"' EXIT

log() { printf '%s\n' "$*"; }

fail() {
    printf 'dev-identity.sh: error: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "'$1' is required but not on PATH."
}

require_command security
require_command openssl

# How many certificates with our common name live in our keychain.
#
# Deliberately NOT `security find-identity -v`, which lists only identities the system considers
# *valid* — which for a self-signed certificate means "already trusted for code signing". That
# makes the -v form useless as an idempotency check, because the window this check has to close is
# exactly the one where a certificate has been imported but not yet trusted:
#
#   security import            <- certificate now in the keychain
#   security add-trusted-cert  <- if this fails, or the operator hits ^C here, ...
#   security set-key-partition-list
#
# ... then `find-identity -v` reports nothing, the next run concludes the identity is absent, and
# creates a SECOND certificate with the same common name. Reproduced: two "Vocca Development"
# certificates in one keychain. sign.sh's `grep -qF` check passes on either, so nothing complains —
# and `codesign` then picks between two leaf certificates. Which one it picks is what the
# certificate-leaf designated requirement is computed over, and therefore what every TCC grant
# (Microphone, Accessibility) is keyed on. Half the time the rebuild loses the grants, which is the
# precise failure this script exists to prevent.
#
# `find-certificate` asks the trust-independent question — is a certificate with this name in this
# keychain — which is the question idempotency actually turns on.
certificate_count_in_keychain() {
    if [ ! -f "$VOCCA_DEV_KEYCHAIN_PATH" ]; then
        printf '0'
        return 0
    fi
    security find-certificate -a -c "$VOCCA_DEV_IDENTITY_NAME" "$VOCCA_DEV_KEYCHAIN_PATH" 2>/dev/null \
        | grep -c '^keychain:' \
        | tr -d '[:space:]'
}

certificate_present_in_keychain() {
    [ "$(certificate_count_in_keychain)" -gt 0 ]
}

# Whether the certificate is not merely present but usable for signing: imported, trusted, and with
# an accessible private key. This is the -v question, and it is asked separately from presence so
# that "present but unusable" reports as the partial-failure it is instead of triggering a second
# creation.
valid_identity_in_keychain() {
    security find-identity -v -p codesigning "$VOCCA_DEV_KEYCHAIN_PATH" 2>/dev/null \
        | grep -qF "\"$VOCCA_DEV_IDENTITY_NAME\""
}

# Refuses to continue if this keychain has picked up more than one certificate with our name.
# Called after every path that could have created one, because a duplicate is silent everywhere
# else: both sign.sh and the xcconfig name the identity by string, and a string matches both.
require_exactly_one_certificate() {
    local count
    count="$(certificate_count_in_keychain)"
    if [ "$count" -gt 1 ]; then
        fail "$VOCCA_DEV_KEYCHAIN_NAME contains $count certificates named \
'$VOCCA_DEV_IDENTITY_NAME'. codesign would choose between them, and which leaf certificate signs \
the app is what every Microphone and Accessibility grant is keyed on — so rebuilds would drop TCC \
grants unpredictably, which is the exact failure this script exists to prevent. Reset and rerun:
  security delete-keychain \"$VOCCA_DEV_KEYCHAIN_PATH\"
  rm -f \"$VOCCA_DEV_KEYCHAIN_PASSWORD_FILE\"
  $0"
    fi
}

write_signing_local_xcconfig() {
    mkdir -p "$REPO_ROOT/Config"
    cat > "$SIGNING_LOCAL_XCCONFIG" <<EOF
// Generated by Scripts/dev-identity.sh. Not checked in (see .gitignore) — this is host-local
// dev state. Included by Config/Signing.xcconfig, which falls back to ad-hoc ("-") when this
// file is absent, so a fresh clone with no identity still builds.
CODE_SIGN_IDENTITY = $VOCCA_DEV_IDENTITY_NAME
EOF
    log "Wrote $SIGNING_LOCAL_XCCONFIG (CODE_SIGN_IDENTITY = $VOCCA_DEV_IDENTITY_NAME)."
}

ensure_keychain_exists() {
    if [ -f "$VOCCA_DEV_KEYCHAIN_PATH" ]; then
        return 0
    fi

    log "Creating keychain $VOCCA_DEV_KEYCHAIN_PATH ..."
    mkdir -p "$VOCCA_DEV_SUPPORT_DIR"
    chmod 700 "$VOCCA_DEV_SUPPORT_DIR"

    local keychain_password
    keychain_password="$(openssl rand -base64 32)"
    # 600 before writing content, not after: umask alone is not a guarantee on every system.
    (umask 077 && : > "$VOCCA_DEV_KEYCHAIN_PASSWORD_FILE")
    printf '%s' "$keychain_password" > "$VOCCA_DEV_KEYCHAIN_PASSWORD_FILE"

    security create-keychain -p "$keychain_password" "$VOCCA_DEV_KEYCHAIN_PATH"
    # No arguments disables both lock-on-sleep and the idle-lock timeout, so codesign can use the
    # identity across a normal dev session without re-prompting.
    security set-keychain-settings "$VOCCA_DEV_KEYCHAIN_PATH"
}

ensure_keychain_on_search_list() {
    # An array, not a word-split string: keychain paths can contain spaces (e.g. a home directory
    # under "Application Support"-style paths), and `-s` takes the whole replacement list as
    # separate arguments.
    local existing=()
    while IFS= read -r line; do
        [ -n "$line" ] && existing+=("$line")
    done < <(security list-keychains -d user | sed 's/^[[:space:]]*"//; s/"$//')

    # `${existing[@]+"${existing[@]}"}`, not `"${existing[@]}"`: macOS ships bash 3.2, where an
    # empty array expanded under `set -u` is an unbound-variable error rather than zero words. The
    # `+` form expands to nothing at all when the array is unset/empty. An empty user search list
    # is unusual but reachable (a `security list-keychains -s` with no arguments earlier in the
    # session), and the failure would be an obscure "unbound variable" from a script whose whole
    # job is to be reliably rerunnable.
    for path in ${existing[@]+"${existing[@]}"}; do
        [ "$path" = "$VOCCA_DEV_KEYCHAIN_PATH" ] && return 0
    done

    log "Adding $VOCCA_DEV_KEYCHAIN_NAME to the user keychain search list ..."
    security list-keychains -d user -s ${existing[@]+"${existing[@]}"} "$VOCCA_DEV_KEYCHAIN_PATH"
}

unlock_or_fail() {
    if [ ! -f "$VOCCA_DEV_KEYCHAIN_PASSWORD_FILE" ]; then
        fail "$VOCCA_DEV_KEYCHAIN_PATH exists but $VOCCA_DEV_KEYCHAIN_PASSWORD_FILE does not, so \
it cannot be unlocked non-interactively. This keychain is orphaned — most likely the support \
directory was deleted after the keychain was created. Delete the keychain and rerun this script: \
  security delete-keychain \"$VOCCA_DEV_KEYCHAIN_PATH\""
    fi
    vocca_unlock_dev_keychain_if_present \
        || fail "Could not unlock $VOCCA_DEV_KEYCHAIN_PATH with the stored password. The \
password file may be stale relative to the keychain. Delete both and rerun: \
  security delete-keychain \"$VOCCA_DEV_KEYCHAIN_PATH\" && rm \"$VOCCA_DEV_KEYCHAIN_PASSWORD_FILE\""
}

create_identity() {
    # Second line of defence, independent of the caller. `main` only calls this when it believes no
    # certificate is present; this refuses regardless of what the caller believed, because the cost
    # of being wrong is a duplicate leaf certificate that nothing else in the toolchain complains
    # about. Cheap check, silent and expensive failure.
    if certificate_present_in_keychain; then
        fail "Refusing to create a second certificate named '$VOCCA_DEV_IDENTITY_NAME': \
$VOCCA_DEV_KEYCHAIN_NAME already contains one. If it is unusable (imported but never trusted, \
because an earlier run failed or was interrupted between 'security import' and \
'security add-trusted-cert'), reset rather than stacking another on top:
  security delete-keychain \"$VOCCA_DEV_KEYCHAIN_PATH\"
  rm -f \"$VOCCA_DEV_KEYCHAIN_PASSWORD_FILE\"
  $0"
    fi

    # Not a function-local `trap ... RETURN`: bash's RETURN trap is not scoped to the function
    # that set it — it re-fires on every subsequent function return in the same shell, including
    # main()'s, by which point $workdir is out of scope. Explicit cleanup at every exit path
    # (below, and via the top-level EXIT trap on WORKDIR set in main) avoids that.
    local workdir
    workdir="$(mktemp -d)"
    WORKDIR="$workdir"

    local key_pem="$workdir/key.pem"
    local cert_pem="$workdir/cert.pem"
    local ext_cnf="$workdir/ext.cnf"
    local p12="$workdir/identity.p12"

    cat > "$ext_cnf" <<EOF
[req]
distinguished_name = dn
prompt = no
x509_extensions = v3_ext

[dn]
CN = $VOCCA_DEV_IDENTITY_NAME

[v3_ext]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

    log "Generating a self-signed code-signing certificate for '$VOCCA_DEV_IDENTITY_NAME' ..."
    openssl req -new -x509 -newkey rsa:2048 -nodes \
        -keyout "$key_pem" -out "$cert_pem" -days 3650 \
        -config "$ext_cnf" -extensions v3_ext >/dev/null 2>&1 \
        || fail "openssl could not generate the self-signed certificate."

    local p12_password
    p12_password="$(openssl rand -base64 24)"
    openssl pkcs12 -export -out "$p12" -inkey "$key_pem" -in "$cert_pem" \
        -passout "pass:$p12_password" \
        || fail "openssl could not package the certificate as a PKCS#12 bundle."

    # -T grants codesign and security direct access to the private key without a per-use
    # "<tool> wants to use your confidential information" prompt.
    security import "$p12" -k "$VOCCA_DEV_KEYCHAIN_PATH" -P "$p12_password" \
        -T /usr/bin/codesign -T /usr/bin/security \
        || fail "security import failed."

    # A self-signed certificate is untrusted by default; without this, codesign finds the
    # identity but 'security find-identity -p codesigning' excludes it as invalid, and codesign
    # itself fails with "no identity found". Scoped to the codeSign policy only — not blanket
    # trust — and to the user trust-settings domain, so it needs no admin/root privilege.
    security add-trusted-cert -p codeSign -k "$VOCCA_DEV_KEYCHAIN_PATH" "$cert_pem" \
        || fail "security add-trusted-cert failed."

    # Post-Sierra ACL requirement: without this, the *first* codesign invocation against a
    # freshly imported key still prompts (once) despite the -T grants above.
    local keychain_password
    keychain_password="$(cat "$VOCCA_DEV_KEYCHAIN_PASSWORD_FILE")"
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
        -k "$keychain_password" "$VOCCA_DEV_KEYCHAIN_PATH" >/dev/null \
        || fail "security set-key-partition-list failed."

    rm -rf "$workdir"
    WORKDIR=""
}

main() {
    ensure_keychain_exists
    ensure_keychain_on_search_list
    unlock_or_fail

    # Presence, not validity, decides whether to create — see certificate_count_in_keychain.
    if certificate_present_in_keychain; then
        require_exactly_one_certificate
        valid_identity_in_keychain \
            || fail "A certificate named '$VOCCA_DEV_IDENTITY_NAME' is in \
$VOCCA_DEV_KEYCHAIN_NAME but is not a valid codesigning identity — it does not appear in \
'security find-identity -v -p codesigning'. That is what a previous run interrupted or failed \
between 'security import' and 'security add-trusted-cert' leaves behind. This script will not \
create a second certificate on top of it (duplicate leaf certificates make codesign's choice, and \
therefore TCC grant persistence, a coin flip). Reset and rerun:
  security delete-keychain \"$VOCCA_DEV_KEYCHAIN_PATH\"
  rm -f \"$VOCCA_DEV_KEYCHAIN_PASSWORD_FILE\"
  $0"
        log "Identity '$VOCCA_DEV_IDENTITY_NAME' already exists in $VOCCA_DEV_KEYCHAIN_NAME — nothing to create."
    else
        create_identity
        require_exactly_one_certificate
        valid_identity_in_keychain \
            || fail "Identity '$VOCCA_DEV_IDENTITY_NAME' was imported but does not appear in \
'security find-identity -v -p codesigning'. Refusing to fall back to ad-hoc signing — that is \
the failure mode this script exists to remove. Inspect the keychain manually: \
  security find-identity -v -p codesigning \"$VOCCA_DEV_KEYCHAIN_PATH\""
        log "Created identity '$VOCCA_DEV_IDENTITY_NAME'."
    fi

    write_signing_local_xcconfig

    cat <<EOF

Summary
-------
Keychain:  $VOCCA_DEV_KEYCHAIN_PATH
Identity:  $VOCCA_DEV_IDENTITY_NAME
Wired via: Config/Signing.local.xcconfig -> CODE_SIGN_IDENTITY

This is a self-signed, local-only identity: it proves nothing to anyone else, and codesign
accepts it only because this script explicitly trusted it for code signing on this machine. It
exists so TCC grants (Microphone, Accessibility) survive rebuilds instead of resetting every time
Xcode picks a fresh ad-hoc identity.

If you later get a real Apple Developer ID certificate:
  1. Import it the normal way (double-click the .p12, or Xcode > Settings > Accounts).
  2. Find its exact identity string: security find-identity -v -p codesigning
  3. Edit Config/Signing.local.xcconfig to read:
       CODE_SIGN_IDENTITY = Developer ID Application: Your Name (TEAMID)
This script only ever manages the self-signed "$VOCCA_DEV_IDENTITY_NAME" identity and will not
touch a Developer ID identity you've wired in by hand.
EOF
}

main "$@"
