# Aspect spec: probe

> Source: `docs/planning/shell-provider/prd.md` R7 · Date 2026-09-22.

## Problem slice and user outcome

The evidence that the composed default still spawns nothing and that shell commands are not
voice-reachable — driven inside the zero-network interposer, the only place the promise is
observed. The user outcome is a CI-asserted fact, not a claim.

## In-scope requirements

- **`PROBE-SHELL`**: a probe drive in `VoccaNetworkProbe/` exercising the composed shell
  configuration. The composed default reads `commands=0`, `spawnsSubprocess=false` off the
  wiring's fact carrier (the `ActionAuditDrive.swift:300-301` shape). With a seeded temp-dir
  registry + enablement, the drive runs one arm → confirm → execute → audit-reconstruct round
  trip over a benign real command (`/bin/echo`), plus a dry-run row.
- **Guard-the-guard**: the `ZeroNetworkTests.swift` readers assert the post-condition lines
  verbatim and refuse a version that no longer describes the composed round trip or the
  composed default (the `:1937-2006` precedent).
- **The intent seam untouched**: a probe/lint fact that the resolver catalog never names
  `dev.vocca.shell` — shell commands are arm-surface-only (founder decision), asserted.
- **Interposer coverage**: the probe runs inside the zero-network interposer
  (`Tests/HarnessTests/ZeroNetworkTests.swift`, `DYLD_INSERT_LIBRARIES` shim over the eight
  libSystem entry points); loopback counts as NETWORK on purpose. The D2 limit is recorded:
  a shell child spawned by an *enabled* configuration is not observable by the interposer —
  the probe proves the *default* cannot spawn, never that an enabled command cannot egress.

## Out-of-scope boundaries

- No real shell execution beyond the benign `/bin/echo` round trip in the drive (the real
  engine's hostile battery lives in the `execution` aspect's suite).
- No SMOKE execution (recorded, never gated).

## Acceptance criteria

1. `PROBE-SHELL` over the composed default prints `commands=0`, `spawnsSubprocess=false`;
   the suite asserts the lines verbatim and exits non-zero if the probe fails.
2. The seeded round trip reconstructs from the audit store (ordinals, decisions,
   binding=match).
3. The guard-the-guard readers refuse a weakened constant (planted-line control).
4. A resolver-catalog fact asserts no `dev.vocca.shell` row is ever composed into the
   intent wiring.
5. The dictation digests are unchanged; the G5 pin (re-anchored only if `AppBootstrap` grew,
   computed never edited-to-match).

## Dependencies and sequencing

Fifth aspect — depends on `wiring` (the composition the probe observes). The G5 re-anchor
(if any) lands in this aspect's REFACTOR commit, exactly as the intent-layer precedent
scheduled it.

## Open questions / risks

- Whether `AppBootstrap` grows (forcing a G5 re-anchor) depends on whether the wiring adds
  a shell leg to the arm surface. If the generic rows suffice, no re-anchor is needed.