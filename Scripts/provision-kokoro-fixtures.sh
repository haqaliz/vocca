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
# Provisions the Kokoro TTS model tarball into a Vocca-shaped model store, and generates the
# SHA-256 manifest the shipped `Sources/VoccaASR/Models/Manifests/kokoro-82m.json` is committed
# from. Run once per machine (or CI cache); the output is verified by the env-gated Kokoro suite
# with VOCCA_KOKORO_MODEL_DIR set to the printed extraction directory.
#
# Usage:
#   Scripts/provision-kokoro-fixtures.sh [--root <store-root>]
#
# --root: the model store root; defaults to `~/Library/Application Support/Vocca/models` (the C2
#         store's default root). The install lands at the store shape
#         <root>/kokoro-82m/1/kokoro/ — the tarball where `ModelStore` commits it (inside the
#         sdkDirectory, `ModelStore.swift:280-284`), the extracted models beside it, the verified
#         marker at the version root — and prints the VOCCA_KOKORO_MODEL_DIR value
#         (<root>/kokoro-82m/1/kokoro). The SHA-256 manifest is written at
#         <root>/kokoro-82m/1/manifest.json — commit its content as
#         Sources/VoccaASR/Models/Manifests/kokoro-82m.json.
#
# The artifact is the port's own release asset (Jud/kokoro-coreml, Apache-2.0):
#   https://github.com/Jud/kokoro-coreml/releases/download/models-2026-03-23/kokoro-models.tar.gz
# The digest and byte count below are generated from the ACTUAL downloaded bytes — never from the
# port's README numbers.

set -euo pipefail

RELEASE_BASE="https://github.com/Jud/kokoro-coreml/releases/download/models-2026-03-23"
TARBALL="kokoro-models.tar.gz"
STORAGE_ID="kokoro-82m"
VERSION="1"
SDK_DIR="kokoro"

root_dir=""
while [ $# -gt 0 ]; do
    case "$1" in
        --root) root_dir="$2"; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

if [ -z "$root_dir" ]; then
    root_dir="$HOME/Library/Application Support/Vocca/models"
    echo "no --root given; using the default store root $root_dir"
fi

version_dir="$root_dir/$STORAGE_ID/$VERSION"
install_dir="$version_dir/$SDK_DIR"
mkdir -p "$install_dir"

tarball_path="$install_dir/$TARBALL"
if [ -f "$tarball_path" ]; then
    echo "using existing tarball $tarball_path"
else
    echo "downloading $RELEASE_BASE/$TARBALL ..."
    # Range-resumable like the store's own transport; GitHub release assets support ranges.
    curl -fL --retry 3 -C - -o "$tarball_path.part" "$RELEASE_BASE/$TARBALL"
    mv "$tarball_path.part" "$tarball_path"
fi

echo "verifying $tarball_path ..."
sha256=$(python3 - "$tarball_path" <<'PY'
import hashlib, sys
print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())
PY
)
byte_count=$(python3 - "$tarball_path" <<'PY'
import os, sys
print(os.path.getsize(sys.argv[1]))
PY
)
echo "sha256: $sha256"
echo "byteCount: $byte_count"

# The artifact's real layout, verified from a temp extraction before anything is installed: the
# listing decides the manifest, not the plan's assumption.
listing_dir="$(mktemp -d /tmp/vocca-kokoro-listing.XXXXXX)"
trap 'rm -rf "$listing_dir"' EXIT
tar -xzf "$tarball_path" -C "$listing_dir"
echo "tarball listing:"
find "$listing_dir" -maxdepth 2 | sort | sed "s|$listing_dir|.|"

trio_ok=1
for name in kokoro_frontend.mlmodelc kokoro_backend.mlmodelc voices; do
    if [ ! -e "$listing_dir/$name" ]; then
        echo "ERROR: tarball is missing $name — the extraction marker trio cannot be honoured" >&2
        trio_ok=0
    fi
done
if [ "$trio_ok" -ne 1 ]; then
    exit 1
fi

if [ -e "$listing_dir/voices/af_heart.bin" ] || [ -e "$listing_dir/voices/af_heart.json" ]; then
    echo "voices/af_heart: present"
else
    echo "WARNING: voices/af_heart not found — the voice naming differs from the plan; the engine's voice argument is 'af_heart'" >&2
fi
if [ -e "$listing_dir/vocab_index.json" ]; then
    echo "vocab_index.json: present"
else
    echo "WARNING: vocab_index.json absent from the artifact — the port falls back to its bundled tokenizer (KokoroEngine.swift:180-185); recorded, not assumed" >&2
fi

echo "installing to $install_dir ..."
cp -R "$listing_dir"/. "$install_dir/"
touch "$version_dir/verified"

# The SHA-256 manifest, generated from the bytes actually installed — the one tarball entry, with
# the digest and byte count printed above.
python3 - "$tarball_path" "$version_dir/manifest.json" "$STORAGE_ID" "$VERSION" "$SDK_DIR" "$TARBALL" <<'PY'
import hashlib, json, os, sys

tarball_path, out_path, storage_id, version, sdk_dir, tarball_name = sys.argv[1:7]
digest = hashlib.sha256(open(tarball_path, "rb").read()).hexdigest()
manifest = {
    "engineID": storage_id,
    "version": version,
    "sdkDirectory": sdk_dir,
    "files": [
        {
            "name": tarball_name,
            "sha256": digest,
            "byteCount": os.path.getsize(tarball_path),
        }
    ],
}
os.makedirs(os.path.dirname(out_path), exist_ok=True)
with open(out_path, "w") as f:
    json.dump(manifest, f, indent=2)
    f.write("\n")
print(f"manifest: {out_path} ({len(manifest['files'])} file)")
PY

echo "--- manifest to commit as Sources/VoccaASR/Models/Manifests/kokoro-82m.json ---"
cat "$version_dir/manifest.json"
echo "--- install complete. Set VOCCA_KOKORO_MODEL_DIR=$install_dir to run the env-gated Kokoro suite."