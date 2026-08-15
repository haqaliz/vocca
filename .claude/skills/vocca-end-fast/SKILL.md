---
name: vocca-end-fast
description: Use when finishing local work on a Vocca unit of work after the PR is merged and you want to clean up without generating a completion report. Triggers on "vocca-end-fast", "vef", "vef bug 12", "vef feat dictation-core", "end fast".
arguments: "type id"
---

# Vocca End (Fast Track)

## Overview

Closes out a unit of work's local state after the PR has merged: **master → pull → remove worktree → delete branch**. No report (use `vocca-end` / `ve` for that).

**Invocation:** `vef <type> <id>` — e.g. `vef bug 12`, `vef feat dictation-core`.

- `type` ∈ `bug | feat | feature | task | chore` (normalize `feature` → `feat`)
- `id` = the GitHub issue number, or the slug used at begin time
- Owner is `aliz`
- Branch: `<type>/<id>/aliz`; worktree dir: `.claude/worktrees/<type>-<id>`

Vocca is a single repo, so this runs once. The base branch is **`master`**, never `main`.

## Pipeline

### Phase 0 — Safety check

Before removing anything:

- **Worktree clean?** `git -C <worktree> status --porcelain` must be empty. If not, stop — commit or stash first.
- **Branch merged?** Confirm the PR is merged (`gh pr view <PR> --json state,mergedAt` if reachable). `git branch -d` will refuse an unmerged branch on purpose; do not bypass with `-D` without explicit user OK.
- **You may be inside the worktree being removed.** Resolve the primary checkout first (Phase 1) and run all commands from there.

### Phase 1 — Master, pulled

Resolve the **primary** checkout (not the worktree). The first line of `git worktree list` is the primary:

```bash
PRIMARY=$(git worktree list | head -1 | awk '{print $1}')
```

Switch and pull, fast-forward only:

```bash
git -C "$PRIMARY" checkout master
git -C "$PRIMARY" pull --ff-only origin master
```

### Phase 2 — Remove worktree, delete branch

```bash
WORKTREE_NAME="<type>-<id>"   # e.g. bug-12, feat-dictation-core
BRANCH="<type>/<id>/aliz"     # e.g. bug/12/aliz, feat/dictation-core/aliz

git -C "$PRIMARY" worktree remove ".claude/worktrees/$WORKTREE_NAME"
git -C "$PRIMARY" branch -d "$BRANCH"
```

If `worktree remove` refuses due to uncommitted/untracked files, go back to Phase 0 — don't pass `--force` silently.

If `branch -d` refuses because the branch isn't merged into master, surface the message — the PR may not be merged, or there are unpushed commits. Don't use `-D` silently.

After both succeed, verify:

```bash
git -C "$PRIMARY" worktree list           # the worktree should be gone
git -C "$PRIMARY" branch --list "$BRANCH" # should print nothing
```

### Phase 3 — Release (only when the user asks)

Finishing a unit of work does **not** automatically release. The release phase runs only when the
user explicitly asks, and only with a user-confirmed version number. The machine is now real:
`.github/workflows/release.yml` runs the whole suite, builds Release, signs it with the workflow's
imported identity, re-runs the suite against the *signed* bundle, verifies the tag version matches
`CFBundleShortVersionString`, and uploads `Vocca-macos.zip` (+ SHA256) to a GitHub Release — all
triggered by pushing a `v*` tag.

1. **Decide the version**: patch bump from the latest tag for small fixes, minor for new features —
   `git tag --sort=-v:refname | head -1`. The first release is `v0.1.0` (the current
   `CFBundleShortVersionString`); confirm the number with the user before proceeding.
2. **Bump the bundle version in `App/Info.plist`** — it is the source of truth the workflow checks:
   `CFBundleShortVersionString` = tag without the `v` (v0.1.0 → `0.1.0`), `CFBundleVersion` = the
   same integer. Keep `Vocca.xcodeproj`'s `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in sync
   (they are inert — `GENERATE_INFOPLIST_FILE = NO`, the plist's literals ship — but they must not
   drift).
3. Commit + push:
   ```bash
   git add App/Info.plist Vocca.xcodeproj/project.pbxproj
   git commit -m "release: bump to v0.1.0"
   git push
   ```
4. **Tag + ship** (v* tags trigger the signed Release build):
   ```bash
   git tag v0.1.0 && git push origin v0.1.0
   ```
5. **Verify the release landed**:
   ```bash
   gh run list --workflow release.yml --limit 1    # wait for green
   gh release view v0.1.0                          # Vocca-macos.zip + .sha256 present
   ```
   A green run must have produced a release: without the signing secrets the workflow fails loudly
   at the signing step, and if the tag doesn't match the bundle version it fails at the version
   step — there is no silent skip.

**Signing secrets** (set once, repo Settings → Secrets and variables → Actions): `APPLE_CERT_P12_BASE64`
+ `APPLE_CERT_PASSWORD` — an exported Apple Development .p12. Without them a tag push still runs
the suite gate, then ends red on purpose.

**Notarization is gated: do not claim it works.** The workflow signs (hardened runtime, secure
timestamp) but does **not** notarize — `Scripts/notarize.sh` has never run end to end, and
notarization needs a paid **Developer ID Application** certificate plus a `notarytool` credential,
neither of which exists. **A free Apple Development certificate cannot notarize.** Until a Developer
ID exists, state clearly in any release announcement: build signed, **not** notarized, **not**
distributable outside the signing machine — and the workflow's own release notes say exactly that.

**Local validation still precedes tagging** for releases that matter: `Scripts/dev-identity.sh` →
build Release → `Scripts/sign.sh .build/xcode-release/Build/Products/Release/Vocca.app` →
`docs/SMOKE_CHECKLIST.md` → "Manual steps before a release" in order; an unrun step is a failed
step. The workflow is the *publish* path; the checklist is the *proof* path, and CI structurally
cannot run its real-machine steps.

**Default rule: no release, no tag, no artifact upload at end of a unit of work** — the release
phase runs only when the user explicitly asks for one. There is no Homebrew cask; the eventual shape
is a signed/notarized app via GitHub Releases.

### Phase 4 — Comment on the issue (optional)

Optional, and only if there's a reachable GitHub issue. Ask first: *"Want me to post a short comment on the issue explaining what we did?"* If the user declines, there's nothing meaningful to say, or there's no issue (the work came from an inline brief), skip.

Otherwise:

1. **Draft a short note** (2–4 sentences). Sources, in order of preference:
   - What the user tells you to say.
   - The merged PR's title + description (`gh pr view <PR>`), if accessible.
   - A best-effort summary from the issue title and the change verb.

   Keep it friendly, light on jargon, no em dashes, no commit hashes, no file paths. The change verb matches the type: `bug → fixed`, `task → done`, `feat`/`feature → shipped`, `chore → done`. Example: *"Shipped hold-to-talk dictation. Press the hotkey, talk, and your words type straight into whatever app you're in, cleaned up as you go. Let me know if anything looks off."*

2. **Confirm the draft** with the user before posting.

3. **Post it** via `gh`:

   ```bash
   gh issue comment "$ID" --body "<confirmed comment text>"
   ```

   On success `gh` prints the comment URL. Tell the user it landed. If `gh` errors (not authenticated, Issues disabled), surface it and stop — don't retry blindly.

## Common mistakes

| Mistake | Fix |
|---|---|
| Running from inside the worktree being removed | Resolve `PRIMARY` first, run commands from there |
| Checking out / pulling `main` | Vocca's base branch is `master`; `main` doesn't exist |
| Using `git pull` (allowing merge) | Use `--ff-only` |
| Forcing branch delete with `-D` | Only after explicit user OK — `-d` refuses unmerged for a reason |
| Forcing worktree remove with `--force` | Same — never silently discard uncommitted work |
| Worktree dir vs branch confusion | Worktree dir is `<type>-<id>` (e.g. `bug-12`); branch is `<type>/<id>/aliz` |
| Posting the issue comment without confirmation | Draft first, show the user, only post after explicit OK |
| Trying to comment when the work has no issue | Skip Phase 4 — it came from an inline brief |
| Releasing at the end of every unit of work | Release only when the user asks — default is no tag, no `gh release create`, no upload |
| Tagging without bumping `App/Info.plist` first | The workflow fails the tag-vs-`CFBundleShortVersionString` match, and the installed app would report the old version — bump first, then tag |
| Tagging with no signing secrets | The workflow runs the suite gate, then ends red at the signing step — configure `APPLE_CERT_P12_BASE64` + `APPLE_CERT_PASSWORD` once in repo Settings before the first tag |
| Running a bare `Scripts/sign.sh` for local validation | Signs the Debug bundle; always pass `.build/xcode-release/Build/Products/Release/Vocca.app` |
| Claiming a workflow release is notarized | It is not — the workflow signs with the imported Apple Development identity and says "not notarized" in the release notes; notarization needs a Developer ID that does not exist |
| Claiming notarization works | It does not — `notarize.sh` has never run end to end; needs a paid Developer ID Application cert + `notarytool` credential; a free Apple Development cert signs but cannot notarize |
| Checking the `runtime` flag loosely | The `flags=` line must read `flags=0x10000(runtime)`; "the word `runtime` appears" is not the same claim |
| Tagging without a user-confirmed version | Ask for the version number and explicit OK before `git tag` / `gh release create` |
