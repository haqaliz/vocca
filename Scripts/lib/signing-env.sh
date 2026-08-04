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
