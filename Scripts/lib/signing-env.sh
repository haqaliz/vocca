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

# Shared constants for dev-identity.sh and sign.sh. Sourced, not executed.
#
# Why a dedicated keychain rather than the login keychain: the login keychain's password is the
# user's own login password, which this script has no business asking for or storing. A keychain
# this script creates has a password *it* generates and controls, so it can unlock itself
# non-interactively without ever touching a secret that belongs to the user.

: "${VOCCA_DEV_IDENTITY_NAME:=Vocca Development}"

VOCCA_DEV_KEYCHAIN_NAME="vocca-dev.keychain-db"
VOCCA_DEV_KEYCHAIN_PATH="$HOME/Library/Keychains/$VOCCA_DEV_KEYCHAIN_NAME"

# PASSWORDS ON THE COMMAND LINE — acceptable here, and why
#
# `security unlock-keychain -p`, `security create-keychain -p`, `security import -P` and
# `security set-key-partition-list -k` all take the secret as an argv element, which is readable
# via `ps` by any process running as the same user for as long as the call lasts. That is a real
# exposure and it is stated here rather than left to be rediscovered.
#
# It is accepted because there is no alternative that closes it and no attacker it would stop:
#
#   - No stdin form exists for the two calls that matter. `security import` without `-P` obtains
#     the passphrase "via GUI" (its own man page), not from stdin, which is unusable from a script;
#     `set-key-partition-list` has no form other than `-k password`. Moving only `unlock-keychain`
#     to a prompt would leave the same keychain password on argv a few lines later, so it would buy
#     the appearance of a fix and nothing else.
#   - The bound: this protects a *self-signed, local-only, disposable* code-signing identity that
#     proves nothing to anyone but this Mac. It signs nothing anyone else trusts and can be
#     recreated in seconds by deleting the keychain and rerunning Scripts/dev-identity.sh.
#   - The threat model it is inside: an attacker who can run `ps` as this user can already read
#     $VOCCA_DEV_KEYCHAIN_PASSWORD_FILE below — a 0600 file owned by this user — without racing
#     anything. argv is the weaker of two paths to the same secret, not a new one.
#
# What would change this judgement: this file being reused for a real Developer ID identity, whose
# private key is not disposable and whose compromise is not local. Do not extend these scripts to
# manage one without moving the secrets off argv first.
#
# Where the keychain's own (script-generated) unlock password is stashed, so future runs — and
# `sign.sh` on a later day, after the keychain has auto-relocked — can unlock it without a prompt.
# Deliberately outside the repository: this is host-local dev state, not project state, and it
# must never be committed even by accident.
VOCCA_DEV_SUPPORT_DIR="$HOME/Library/Application Support/Vocca"
VOCCA_DEV_KEYCHAIN_PASSWORD_FILE="$VOCCA_DEV_SUPPORT_DIR/dev-keychain.pass"

# Unlocks $VOCCA_DEV_KEYCHAIN_PATH using the stashed password, if both the keychain and the
# password file exist. Silent no-op otherwise — callers decide what an absent keychain means.
# Returns non-zero only if the keychain exists, the password file exists, and unlocking still
# failed (e.g. the password file is stale) — a real problem worth the caller surfacing.
vocca_unlock_dev_keychain_if_present() {
    if [ ! -f "$VOCCA_DEV_KEYCHAIN_PATH" ]; then
        return 0
    fi
    if [ ! -f "$VOCCA_DEV_KEYCHAIN_PASSWORD_FILE" ]; then
        return 0
    fi
    security unlock-keychain -p "$(cat "$VOCCA_DEV_KEYCHAIN_PASSWORD_FILE")" "$VOCCA_DEV_KEYCHAIN_PATH"
}
