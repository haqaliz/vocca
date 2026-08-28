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
# Provisions a Vocca-shaped model install from an existing model directory, and generates the
# SHA-256 manifest the fixture suite's env-gated tests consume. Run once per machine (or CI
# cache); the output is verified by SMOKE_CHECKLIST.md steps 17-18 and by the env-gated engine
# WER tests with VOCCA_MODEL_DIR set.
#
# Usage:
#   Scripts/provision-asr-fixtures.sh --source <model-dir> [--root <store-root>]
#       [--engine parakeet-tdt-0.6b-v3 | whisper-large-v3-turbo] [--tier turbo | q5_0]
#
# --source: a directory holding the model artifact's files.
#           For parakeet-tdt-0.6b-v3: the TDT v3 int8 files — the Preprocessor, Encoder,
#           Decoder and JointDecisionv3 .mlmodelc bundles, config.json and parakeet_vocab.json
#           (e.g. FluidAudio's cache: ~/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3).
#           For whisper-large-v3-turbo: the single GGUF file for the tier
#           (ggml-large-v3-turbo.bin or ggml-large-v3-turbo-q5_0.bin, e.g. Hugging Face
#           ggerganov/whisper.cpp).
# --engine: the engine whose artifact is being provisioned. Defaults to parakeet-tdt-0.6b-v3,
#           keeping today's invocation (--source + --root only) working unchanged. The whisper
#           engine installs its single file flat — no sdkDirectory.
# --tier:   for whisper-large-v3-turbo only: turbo (default) or q5_0, naming the GGUF file.
# --root:   the model store root; defaults to a scratch dir under /tmp. The install lands at
#           <root>/<engineID>/<version>/<sdkDirectory>/ for parakeet (flat at
#           <root>/<engineID>/<version>/ for whisper), and prints the VOCCA_MODEL_DIR value
#           (<root>/<engineID>/<version>). The SHA-256 manifest is written beside the install at
#           <root>/<engineID>/<version>/manifest.json — commit its content as
#           Sources/VoccaASR/Models/Manifests/<engineID>.json.

set -euo pipefail

ENGINE="parakeet-tdt-0.6b-v3"
VERSION="1"

source_dir=""
root_dir=""
tier="turbo"
tier_set=0

while [ $# -gt 0 ]; do
    case "$1" in
        --source) source_dir="$2"; shift 2 ;;
        --root) root_dir="$2"; shift 2 ;;
        --engine) ENGINE="$2"; shift 2 ;;
        --tier) tier="$2"; tier_set=1; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

# The per-engine shape: which files are required, and whether the artifact lives in an
# sdkDirectory subdirectory (parakeet) or flat in the version directory (whisper).
case "$ENGINE" in
    parakeet-tdt-0.6b-v3)
        [ "$tier_set" -eq 0 ] || { echo "--tier is only valid for the whisper engine" >&2; exit 2; }
        STORAGE_ID="$ENGINE"   # one tier, so the tier's storage key is the engine's name
        SDK_DIR="$ENGINE"   # the SDK's repo folder name — the layout rule `load(from: D)` resolves to
        REQUIRED=(
            "Preprocessor.mlmodelc" "Encoder.mlmodelc" "Decoder.mlmodelc"
            "JointDecisionv3.mlmodelc" "config.json" "parakeet_vocab.json"
        )
        ;;
    whisper-large-v3-turbo)
        # Storage is keyed by **tier**, not by engine (`EngineTier.storageID`): the two whisper
        # tiers are different artifacts, so installing both under the engine's name would give
        # them one directory and one verified marker — the app would load whichever arrived
        # first under the name of whichever was selected. The keys here are the shipped
        # manifests' `engineID`s, and `ModelStoreTierKeyingTests` pins those to the enum.
        case "$tier" in
            turbo)
                MODEL_FILE="ggml-large-v3-turbo.bin"
                STORAGE_ID="whisper-large-v3-turbo"
                ;;
            q5_0)
                MODEL_FILE="ggml-large-v3-turbo-q5_0.bin"
                STORAGE_ID="whisper-large-v3-turbo-q5_0"
                ;;
            *) echo "unknown tier: $tier" >&2; exit 2 ;;
        esac
        SDK_DIR=""
        REQUIRED=("$MODEL_FILE")
        ;;
    *)
        echo "unknown engine: $ENGINE" >&2
        echo "expected one of: parakeet-tdt-0.6b-v3, whisper-large-v3-turbo" >&2
        exit 2
        ;;
esac

[ -n "$source_dir" ] || { echo "missing --source <model-dir>" >&2; exit 2; }
[ -d "$source_dir" ] || { echo "--source is not a directory: $source_dir" >&2; exit 2; }

for name in "${REQUIRED[@]}"; do
    [ -e "$source_dir/$name" ] || { echo "missing required model file: $source_dir/$name" >&2; exit 1; }
done

if [ -z "$root_dir" ]; then
    root_dir="$(mktemp -d /tmp/vocca-models.XXXXXX)"
    echo "no --root given; using scratch store root $root_dir"
fi

version_dir="$root_dir/$STORAGE_ID/$VERSION"
if [ -n "$SDK_DIR" ]; then
    install_dir="$version_dir/$SDK_DIR"
else
    install_dir="$version_dir"
fi
mkdir -p "$install_dir"

echo "installing to $install_dir ..."
for name in "${REQUIRED[@]}"; do
    if [ -d "$source_dir/$name" ]; then
        cp -R "$source_dir/$name" "$install_dir/"
    else
        cp "$source_dir/$name" "$install_dir/"
    fi
done

# The verified marker: the store's presence truth. Written last, after every file is on disk.
touch "$version_dir/verified"

# The SHA-256 manifest, generated from the bytes actually installed. The parakeet shape walks
# the install recursively (nested .mlmodelc files); the whisper shape is exactly the one
# required file, passed by name so the walk can never absorb the marker or a stale manifest.
python3 - "$install_dir" "$version_dir/manifest.json" "$STORAGE_ID" "$VERSION" "$SDK_DIR" ${MODEL_FILE:+"$MODEL_FILE"} <<'PY'
import hashlib, json, os, sys

install_dir, out_path, storage_id, version, sdk_dir = sys.argv[1:6]
explicit = sys.argv[6:]
files = []
if explicit:
    for name in sorted(explicit):
        path = os.path.join(install_dir, name)
        digest = hashlib.sha256(open(path, "rb").read()).hexdigest()
        files.append({"name": name, "sha256": digest, "byteCount": os.path.getsize(path)})
else:
    for root, dirs, names in os.walk(install_dir):
        dirs.sort()
        for name in sorted(names):
            path = os.path.join(root, name)
            rel = os.path.relpath(path, install_dir)
            digest = hashlib.sha256(open(path, "rb").read()).hexdigest()
            files.append({"name": rel, "sha256": digest, "byteCount": os.path.getsize(path)})
if sdk_dir:
    manifest = {"engineID": storage_id, "version": version, "sdkDirectory": sdk_dir, "files": files}
else:
    manifest = {"engineID": storage_id, "version": version, "files": files}
os.makedirs(os.path.dirname(out_path), exist_ok=True)
with open(out_path, "w") as f:
    json.dump(manifest, f, indent=2)
    f.write("\n")
print(f"manifest: {out_path} ({len(files)} files)")
PY

echo "install complete. Set VOCCA_MODEL_DIR=$version_dir to run the env-gated engine tests."
