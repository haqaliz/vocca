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
# Provisions the Silero VAD CoreML bundle into a Vocca-shaped model store, and generates the
# SHA-256 manifest the shipped `Sources/VoccaASR/Models/Manifests/silero-vad.json` is committed
# from. Run once per machine; the output is verified by the env-gated VAD suite in `sdk-adapters`
# with VOCCA_MODEL_DIR set to the store root.
#
# Usage:
#   Scripts/provision-vad-fixtures.sh [--root <store-root>]
#
# --root: the model store root; defaults to `~/Library/Application Support/Vocca/models` (the C2
#         store's default root). The install lands at the store shape
#         <root>/silero-vad/1/vad/silero-vad-unified-256ms-v6.2.1.mlmodelc/ — the five files of
#         the .mlmodelc DIRECTORY (the artifact ships as a bare directory, not a tarball — the
#         SDK-shaped per-file manifest pattern), the verified marker at the version root — and
#         prints the digest of every file. The SHA-256 manifest is written at
#         <root>/silero-vad/1/manifest.json — commit its content as
#         Sources/VoccaASR/Models/Manifests/silero-vad.json.
#
# The artifact is the SDK's named model (ModelNames.VAD.sileroVadFile at the resolved 0.15.7):
#   https://huggingface.co/FluidInference/silero-vad-coreml/resolve/main/silero-vad-unified-256ms-v6.2.1.mlmodelc/<file>
# The digests and byte counts are generated from the ACTUAL downloaded bytes — never from a
# README or a web page — and cross-checked against the Hugging Face tree's declared content
# hashes for the v6.2.1 directory (recorded in the vetting gate, 2026-09-15).

set -euo pipefail

REPO_BASE="https://huggingface.co/FluidInference/silero-vad-coreml/resolve/main"
MODEL_DIR="silero-vad-unified-256ms-v6.2.1.mlmodelc"
STORAGE_ID="silero-vad"
VERSION="1"
SDK_DIR="vad"

# The five files of the v6.2.1 .mlmodelc directory, as listed by the HF tree API on 2026-09-15.
# Each entry is `<path>:<kind>:<oid>:<size>` where kind `lfs` means the oid is the content
# SHA-256 (the LFS object hash) and kind `git` means the oid is the git blob hash (SHA-1 of the
# object header + content — what `git hash-object` prints); the blob hash is the repo's declared
# content identity for non-LFS files. The downloaded bytes must match both the declared identity
# AND the declared size — a mismatch means the repo changed shape and the vetting record's pins
# are stale. The manifest's sha256 is always computed from the ACTUAL bytes by the script; the
# repo's declared identities only cross-check them.
FILES=(
    "analytics/coremldata.bin:lfs:8067594eb3126ab8318af507f0c00cabfed40d5fedb8a0ee5075dd02e903d909:243"
    "coremldata.bin:lfs:7db35a4fd995222a7fb0129713473b15d1462572ab4a2e5e4d56bcaad9e40f41:625"
    "metadata.json:git:8ecdc26edff98896279d325d0dfffc46a65f5f53:3335"
    "model.mil:git:adf9d2a7d9a4c02164644ff7c5d864d08eb409a9:176918"
    "weights/weight.bin:lfs:53ecc8b5081146140ab654c89109cf001f2183abddd7a2411c5081feeffff063:882304"
)

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
model_dir="$install_dir/$MODEL_DIR"

if [ -f "$version_dir/verified" ]; then
    echo "verified marker present at $version_dir/verified — nothing to do"
    echo "the staged bundle is at $model_dir"
    exit 0
fi

mkdir -p "$model_dir"

for entry in "${FILES[@]}"; do
    rel_path="${entry%%:*}"
    rest="${entry#*:}"
    kind="${rest%%:*}"
    rest="${rest#*:}"
    declared_oid="${rest%%:*}"
    declared_size="${rest#*:}"
    target="$model_dir/$rel_path"

    if [ -f "$target" ]; then
        echo "using existing $target"
    else
        mkdir -p "$(dirname "$target")"
        echo "downloading $REPO_BASE/$MODEL_DIR/$rel_path ..."
        # Range-resumable like the store's own transport; HF resolve URLs redirect to the CDN.
        curl -fL --retry 3 -C - -o "$target.part" "$REPO_BASE/$MODEL_DIR/$rel_path"
        mv "$target.part" "$target"
    fi
done

echo "verifying the downloaded bytes ..."
for entry in "${FILES[@]}"; do
    rel_path="${entry%%:*}"
    rest="${entry#*:}"
    kind="${rest%%:*}"
    rest="${rest#*:}"
    declared_oid="${rest%%:*}"
    declared_size="${rest#*:}"
    target="$model_dir/$rel_path"

    if [ "$kind" = "lfs" ]; then
        # LFS object hash: the SHA-256 of the content itself.
        actual_oid="$(shasum -a 256 "$target" | awk '{print $1}')"
    else
        # Git blob hash: SHA-1 over "blob <size>\0<content>" — what `git hash-object` prints.
        actual_oid="$(git hash-object "$target")"
    fi
    actual_size="$(stat -f%z "$target")"

    if [ "$actual_oid" != "$declared_oid" ]; then
        echo "ERROR: $rel_path identity mismatch — downloaded $actual_oid, repo declares $declared_oid" >&2
        exit 1
    fi
    if [ "$actual_size" != "$declared_size" ]; then
        echo "ERROR: $rel_path size mismatch — downloaded $actual_size, repo declares $declared_size" >&2
        exit 1
    fi
    echo "$rel_path: identity=$actual_oid byteCount=$actual_size"
done
echo "all five files verified against the repo's declared content identities"

touch "$version_dir/verified"

# The SHA-256 manifest, generated from the bytes actually installed — one entry per file, the
# SDK-shaped per-file pattern (the parakeet-tdt-0.6b-v3.json shape) with the digests and byte
# counts printed above.
python3 - "$version_dir/manifest.json" "$STORAGE_ID" "$VERSION" "$SDK_DIR" "$MODEL_DIR" "$model_dir" "${FILES[@]}" <<'PY'
import hashlib, json, os, sys

out_path, storage_id, version, sdk_dir, model_dir, install_model_dir = sys.argv[1:7]
entries = sys.argv[7:]

files = []
for entry in entries:
    rel_path, _, _ = entry.split(":", 2)
    full = os.path.join(install_model_dir, rel_path)
    digest = hashlib.sha256(open(full, "rb").read()).hexdigest()
    files.append(
        {
            "name": os.path.join(model_dir, rel_path),
            "sha256": digest,
            "byteCount": os.path.getsize(full),
        }
    )

manifest = {
    "engineID": storage_id,
    "version": version,
    "sdkDirectory": sdk_dir,
    "files": files,
}
os.makedirs(os.path.dirname(out_path), exist_ok=True)
with open(out_path, "w") as f:
    json.dump(manifest, f, indent=2)
    f.write("\n")
print(f"manifest: {out_path} ({len(files)} files)")
PY

echo "--- manifest to commit as Sources/VoccaASR/Models/Manifests/silero-vad.json ---"
cat "$version_dir/manifest.json"
echo "--- install complete. The staged bundle is at $model_dir (set VOCCA_MODEL_DIR=$root_dir to run the env-gated VAD suite)."