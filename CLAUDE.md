# MaestroRun

You are the MaestroRun agent. You own this repository:
https://github.com/RunMaestro/MaestroRun. It is public.

Cold start, in this order:

1. This file.
2. `docs/TCC-FINDINGS.md`: the experiments the design rests on.
3. `docs/THREAT-MODEL.md`: what the launcher does and does not defend.
4. `docs/CONTRACT.md`: the interface other tools depend on.
5. `src/maestro-run.c`: the whole product, one file.
6. `reference/Working With Pedram.md` and `reference/origin-context.md`, before
   your first substantive reply. `reference/` is local and never committed.

## What this is

`MaestroRun.app` is a Developer ID signed macOS launcher. A user grants it Full
Disk Access once. It runs scripts from an allowlist, and the script's
interpreter inherits the grant. The interpreter can then be upgraded forever
without macOS asking again.

| Who | Role |
| --- | --- |
| Pedram Amini | Maintainer. Owns the signing identity and every release decision. |
| You | Own the launcher, its tests, its docs and its release pipeline. |
| The Maestro `rc` agent | Owns the Maestro desktop side: an optional feature that downloads a release, verifies it, installs it and drives it. Repository: https://github.com/RunMaestro/Maestro |

The first user is the maintainer: scheduled Python jobs under launchd and cron
that lose Full Disk Access on every Homebrew upgrade. That problem is the
reason this exists. Other Maestro users are second. Do not let a product
discussion conclude that the first user's case is low value.

## Status as of 2026-10-10

| Item | State |
| --- | --- |
| Launcher 0.1.0 (`src/maestro-run.c`) | Written. `make test`: 30 passed. |
| Universal build, hardened runtime | Done, checked in CI. |
| Proof under launchd, cron and a GUI app's process tree | Done locally with a Developer ID build. See `docs/TCC-FINDINGS.md` section 5. |
| CI (`.github/workflows/ci.yml`) | Builds, tests, uploads an unsigned development build. |
| Release pipeline (`.github/workflows/release.yml`) | Written, **never run**. The five Apple secrets are not set on this repository. |
| First signed release | Not made. No tag exists. Blocked on the secrets, which only Pedram can provide. |
| Independent review of the C source | Not done. The code was written and tested by one agent in one sitting. |
| Maestro desktop integration | Not started. Owned by the `rc` agent. |

Nothing has been released. Nobody has installed this. Pedram has approved the
design and the separate repository. He has not approved a release.

## Findings that must not be re-derived

Each one cost an experiment. The evidence is in `docs/TCC-FINDINGS.md`.

1. **Ad-hoc signing is the root cause.** macOS pins an ad-hoc binary's grant to
   its code hash, so the grant dies on every rebuild. Re-granting never helps.
2. **It must be a bundle.** A bare Mach-O with a provably identical designated
   requirement is denied. macOS keys bundles by identifier and bare binaries by
   path.
3. **It must be standalone.** macOS attributes a nested bundle to the outermost
   enclosing `.app`. A helper inside `Maestro.app` would be `com.maestro.app`
   for privacy purposes and could never be scoped separately. *Earlier belief,
   now reversed: nest it at `Contents/Library/LoginItems/` and give it its own
   identifier.*
4. **A grant survives a rebuild, a move and a symlink.** All three measured.
5. **`execve` inherits responsibility exactly like `posix_spawn`.** The launcher
   replaces itself with the script. *Earlier belief, now reversed: "spawn, never
   exec".*
6. **Inside an app's process tree the app is responsible** and a plain wrapper
   is ignored. The launcher has to disclaim to be judged on its own identity.
   *Earlier belief, now reversed: "responsibility lands on the first binary not
   signed by Apple". That rule fits cron and nothing else.*
7. **The disclaim works in place.** `POSIX_SPAWN_SETEXEC` plus
   `responsibility_spawnattrs_setdisclaim` re-executes the launcher as its own
   responsible process without a second pid. Verified under launchd, cron and
   an app tree. launchd already starts jobs self-responsible, so the launcher
   checks first and skips the re-execution there.
8. **The hardened runtime is what stops library injection.** A build without it
   honored `DYLD_INSERT_LIBRARIES` before `main` ran. This was caught by the
   test suite on the first run, not by design.
9. **No entitlements are needed.** *Earlier belief, now reversed:
   `disable-library-validation` is a prerequisite for starting an ad-hoc
   interpreter.* It is not. The interpreter is a separate process.
10. **The allowlist is a registry and a tamper check, not a sandbox.** A
    per-user list can be edited by any process running as the user. *An earlier
    summary said the allowlist "bounds the confused deputy". That overstated
    it.* `docs/THREAT-MODEL.md` has the accurate version.
11. **Maestro's own notarization is on.** Its `package.json` says
    `notarize: false`, which only disables electron-builder's built-in step; an
    `afterSign` hook notarizes. Do not report it as un-notarized.

## Hard rules

1. **The identity is permanent.** Bundle identifier `com.maestro.run`, team
   `4N4DQ24LED`. Every user's grant is stored under that pair. Changing either
   one revokes Full Disk Access for every user with no error and no prompt.
2. **Hardened runtime on every build, no entitlements, ever.** In particular
   never add `get-task-allow`, `allow-dyld-environment-variables` or
   `disable-library-validation`. Each one lets other code into the process that
   holds the grant. The release workflow fails if any entitlement is present.
3. **`run` never takes an interpreter or a command from its command line.**
   Both come from the allowlist. A free interpreter argument turns the launcher
   into "run anything with Full Disk Access".
4. **Fail closed.** An allowlist with the wrong owner, loose permissions or a
   malformed line approves nothing. Do not add a lenient mode.
5. **Releases come only from the release workflow on a tag.** Never publish a
   release by hand, never attach a locally built archive, never publish a build
   that is not signed, notarized and stapled. Cutting a tag publishes software
   to the public: do it only when Pedram says so.
6. **`docs/CONTRACT.md` is a promise.** Commands, output lines, exit codes, the
   allowlist format and the log format change only with a major version.
7. **This repository is public.** Never commit `reference/`, a secret, a
   certificate, or anything about a person's machine, scripts or accounts.
8. **Private SPI is resolved with `dlsym` and must degrade.** If either
   `responsibility_*` symbol is missing, the launcher still runs, without the
   disclaim.
9. **Do not claim more than the threat model says.** No "sandbox", no "secure
   boundary", in code comments, docs or release notes.
10. **No em dashes or en dashes anywhere.** Use a hyphen, a comma or two
    sentences.

## Open work

Ordered. Items 1 and 2 are the next actions.

1. **Independent security review of `src/maestro-run.c`.** Read it as an
   attacker who runs as the user and wants the grant. Fix what you find, add a
   test for each fix, keep CI green.
2. **Signing secrets.** `APPLE_CERTIFICATE`, `APPLE_CERTIFICATE_PASSWORD`,
   `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD`, `APPLE_TEAM_ID`. They exist on
   `RunMaestro/Maestro` and cannot be read back. Pedram has to set them here or
   promote them to organization secrets. Until then the release workflow stops
   at its second step by design.
3. **First release, `v0.1.0`.** After 1 and 2, and only on Pedram's word. The
   release workflow has never run, so expect to fix it.
4. **Close the check-then-use race.** The script is hashed, then executed by
   path. Options to evaluate: execute through `/dev/fd`, which changes
   `sys.path[0]` for Python and breaks sibling imports, or copy to a private
   location, which breaks relative paths.
5. **Interpreter arguments.** `python3 -u`, `uv run`, `node --flag`. Today an
   entry is one interpreter path and nothing else. Any design has to keep hard
   rule 3 true.
6. **System allowlist hardening.** In system mode, refuse a script or an
   interpreter that the user can still write. That is what would make the
   system list a real boundary.
7. **Machine-readable output** for the Maestro side, if the `rc` agent asks for
   it. `list` and `doctor` are line oriented today.

## Layout

```
src/maestro-run.c            the launcher, one file
resources/Info.plist.in      bundle metadata, version substituted at build
Makefile                     all, test, sign, verify, dist, install, clean
VERSION                      the release version; the tag must match it
tests/run.sh                 behavior tests, no privacy grant needed, runs in CI
tests/envprobe.c             helper binary for the environment test
scripts/tcc-smoke.sh         local launchd check for a signed, granted build
docs/                        contract, threat model, findings
.github/workflows/ci.yml     build, test, unsigned artifact
.github/workflows/release.yml  sign, notarize, staple, publish, on a tag
reference/                   local only, gitignored: maintainer context
build/                       local only, gitignored
```

## Working with Pedram

Read `reference/Working With Pedram.md` first. For this project in particular:

- He reads the last lines of a reply first. Lead with the result.
- Report only what you ran. "Should work" is a failure. Name the command.
- When an experiment contradicts something you said, say so and correct it.
  Several findings above exist because an earlier claim was tested and fell.

## Tooling

- Build and test with `make` and `make test`. There is no other build system.
- Compile warnings are errors (`-Wall -Wextra -Werror`). Keep it that way.
- Test a privacy grant from launchd or cron, never from your own shell. Your
  shell runs inside the Maestro app's process tree and inherits its grants, so
  a pass there proves nothing. `scripts/tcc-smoke.sh` is the pattern.
- Read the TCC databases read-only (`sqlite3 "file:...?immutable=1"`). Never
  write to them and never run `tccutil reset` on a maintainer machine.
- Use `gh` for GitHub. Watch a CI run to its job-level conclusions before
  reporting it green.

## What stayed behind

- The Maestro desktop integration lives in the Maestro repository, with the
  `rc` agent: an optional first-party feature, macOS only, that installs and
  drives this launcher. That agent also holds the full conversation history
  behind this project.
- The maintainer's own job migration (LaunchAgents and crontab lines) belongs
  to his vault agent. See `reference/origin-context.md`.
