# Aspect 1: `model-store-keying`

**Merge order: 1st.** No dependencies. Pure store/data work, no UI.

## Problem slice

`ModelStore` keys every model directory as `<root>/<engineID>/<version>/`
(`Sources/VoccaASR/Models/ModelStore.swift:89-92`), and both `isPresent` (`:103`) and
`downloadIfMissing` (`:158`) are keyed on that pair. Both Whisper manifests declare the **same**
pair — `engineID: "whisper-large-v3-turbo"`, `version: "1"`:

| Manifest | File | Bytes |
|---|---|---|
| `whisper-large-v3-turbo.json` | `ggml-large-v3-turbo.bin` | 1 624 555 275 |
| `whisper-large-v3-turbo-q5_0.json` | `ggml-large-v3-turbo-q5_0.bin` | 574 041 195 |

So the two tiers share one directory and one verified marker. Download q5_0, select turbo, and
`downloadIfMissing` short-circuits at `:158` while the engine is handed a directory whose `.bin`
is the wrong one. `ShippedModelManifest.load(for:)` maps the tiers to the right *manifest files*
(`ShippedModelManifest.swift:60-69`) — the collision is in the store key alone.

**User outcome:** selecting a tier gets that tier's model, and the Speech tab's
`[installed]`/`[download]` badge tells the truth per row.

## In scope

- **R1** The q5_0 manifest declares a tier-specific `engineID` (`whisper-large-v3-turbo-q5_0`), so
  each tier resolves to its own `<engineID>/<version>/` directory.
- **R2** A per-tier presence query the UI can ask: given an `EngineTier`, is that tier's model
  present and verified?
- **R3** A per-tier disk-usage query (bytes on disk for a tier's directory), for
  `PRODUCT_SPEC.md:260`'s "disk used".
- **R4** A per-tier removal that deletes the tier's directory **and** its verified marker, so a
  removed model cannot read back as present.
- **R5** A guard making this class of defect unrepeatable: no two shipped manifests may declare the
  same `(engineID, version)` pair.

## Out of scope

- Any UI (aspect 4). Any change to selection or resolution (aspects 2, 3).
- Verifying digests against the served bytes (aspect 6).
- Changing the Parakeet manifest's key, or `ModelStore`'s directory *shape*.

## Acceptance criteria (tests first)

1. **The collision test, written red first:** `whisperTurbo` and `whisperTurboQ5` resolve to
   **different** `baseURL`s. Fails before R1, passes after.
2. Downloading one Whisper tier over a stub transport leaves `isPresent` **false** for the other.
3. `downloadIfMissing` for tier B does **not** short-circuit when tier A is present and verified.
4. **R5's guard:** a test enumerating every shipped manifest asserts the `(engineID, version)`
   pairs are pairwise distinct — and a planted duplicate makes it fail (a gate that cannot fail
   proves nothing).
5. Removal (R4) makes `isPresent` answer `false`, including when a verified marker existed.
6. Disk usage (R3) answers 0 for an absent tier and the summed file size for a present one.
7. The Parakeet path is untouched: its `baseURL`, presence and download behaviour are unchanged,
   pinned by a test that would fail if the key shape moved.

## Risks

- **On-disk path change.** Verify before implementing that no user has either Whisper tier on disk:
  the published release was deleted, and `SMOKE_CHECKLIST.md` step 19 (whisper's first real run) is
  unexecuted. If that holds there is nothing to migrate; if it does not, R1 needs a migration and
  this spec must be revised rather than worked around.
