# MaestroRun

You are the MaestroRun agent. You own this repository:
https://github.com/RunMaestro/MaestroRun. It is public.

Cold start, in this order:

1. This file.
2. `docs/TCC-FINDINGS.md`: the experiments the design rests on.
3. `docs/THREAT-MODEL.md`: what the launcher does and does not defend.
4. `docs/CONTRACT.md`: the interface other tools depend on.
5. `src/maestro-run.c`: the whole product, one file.
6. `reference/Working With Pedram.md`, `reference/origin-context.md` and
   `reference/handoff-from-rc.md`, before your first substantive reply.
   `reference/` is local and never committed.

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
| Launcher 0.1.0 (`src/maestro-run.c`) | Written. `make test`: 41 passed on a maintainer machine, natively and under Rosetta. |
| Universal build, hardened runtime | Done, checked in CI. |
| Proof under launchd, cron and a GUI app's process tree | Done locally with a stand-in identity, not with `com.maestro.run`. See finding 16 and `docs/TCC-FINDINGS.md` section 5. |
| A grant for `com.maestro.run` itself | Never made, on any machine. The System Settings step is untested. |
| Maintainer's local install | Prepared, not run. `make sign` and `make verify` pass with the real identity. Waits on Pedram's word. Steps in `reference/handoff-from-rc.md`. |
| CI (`.github/workflows/ci.yml`) | Green. Builds, tests (40 passed, 1 skipped, see finding 12), uploads an unsigned development build. |
| Release pipeline (`.github/workflows/release.yml`) | Written, **never run**. The five Apple secrets are not set on this repository. |
| First signed release | Not made. No tag exists. Blocked on the secrets, which only Pedram can provide. |
| Independent review of the C source | Done 2026-10-10 by a second agent. Three defects fixed, each with a test. What it left is in `docs/THREAT-MODEL.md` and in open work item 1. |
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
12. **Hosted CI cannot test the injection defense.** GitHub's macOS runners
    have System Integrity Protection off, and there a hardened binary still
    honors `DYLD_INSERT_LIBRARIES`. The first CI run failed on exactly this.
    `tests/run.sh` skips that one case when protection is off and says so. It
    is verified only on a machine with protection on, so run `make test`
    locally before every release.
13. **The caller's environment steers an approved script.** Reproduced against
    0.1.0 with `BASH_ENV`, with `PATH` and a `#!/usr/bin/env` line, and with
    `PYTHONPATH` and a `sitecustomize.py`. The script is unchanged, the log
    says `ALLOW`. Removing `DYLD_*` alone does not make the system allowlist a
    boundary.
14. **A caller can hide a file from the launcher.** Under a `sandbox-exec`
    deny rule `lstat` returns `EPERM` for a file that exists and `ENOENT` for
    one that does not. The launcher runs normally inside that sandbox. So
    "cannot examine" must never be read as "absent".
15. **Every signed build holds the grant for good.** The grant is keyed on the
    identifier and the team (finding 4). An attacker can keep a copy of an old
    release and run that. A defect that ships signed cannot be fixed
    afterwards.
16. **The end-to-end proof used a stand-in identity.** Measured. The bundle
    was copied, its identifier set to `com.maestro.app`, and signed with the
    Developer ID (hardened runtime, no secure timestamp, not notarized). It
    satisfied the grant Maestro.app already held. So the launcher code is
    proven and the identifier `com.maestro.run` is not: it has never held a
    grant. A bundle signed that way satisfies another app's grants. It must
    never leave a test directory, and it is deleted after the test.
17. **A build signed on the machine needs no notarization.** Measured, by 16:
    a local, Developer ID signed, not notarized bundle passed under launchd
    and cron. Notarization is for downloaded copies. The maintainer's own
    problem can be solved with `make sign` and `make install`, without the
    release pipeline. The missing secrets block the public release only.
    `spctl --assess` rejects such a build (`Unnotarized Developer ID`). That
    is expected.
18. **`doctor` leaves a denied row.** Measured 2026-10-10. An ungranted
    launcher that runs `doctor` gets a Full Disk Access row for
    `com.maestro.run` with `auth_value` 0. Its requirement is that of the
    build that ran: code hashes for an ad-hoc build, identifier and team for a
    Developer ID build. Each new build rewrites it. `make test` runs `doctor`,
    so the suite does this on every machine. *Untested: whether an ad-hoc
    `doctor` also rewrites a row that is already granted. If it does,
    `make test` revokes the grant on that machine.*
19. **The Intel slice runs under Rosetta.** Measured 2026-10-10:
    `arch -x86_64 /bin/bash tests/run.sh` passes. Not proven: which slice the
    disclaim re-execution picks. Not tested: Intel hardware.

## Untested, do not present as fact

`docs/TCC-FINDINGS.md` has the full list under "Not tested". In short:

- **Background Task Management.** The notice that started this project was
  "App Background Activity" naming the interpreter, raised for a LaunchAgent.
  That is a separate subsystem from TCC. The claim that a bundle shows a
  proper name in Login Items & Extensions was never tested. Everything
  measured is TCC only.
- **The grant itself.** Adding `MaestroRun.app` in System Settings, and how an
  `LSUIElement` bundle with no icon appears there.
- **The five `NS*UsageDescription` strings.** Only Full Disk Access was
  tested. Prompts and attribution for Contacts, Calendars, Reminders, Photos
  and Apple Events under launchd are unknown.
- **macOS versions.** Everything ran on macOS 26.6, Apple silicon. The 11.0
  minimum and the `responsibility_*` symbols on older systems are unverified.
- **Notarization outcome.** Unknown until the first submission. "The allowlist
  will help notarization review" was speculation.
- **A local grant carrying over to a notarized release.** Expected from
  finding 4, not measured.

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

Ordered. Items 1 to 3 are the next actions, and all three wait on Pedram.

1. **Decide the environment policy before the first release.** Finding 13.
   `docs/CONTRACT.md` promises that every variable except `DYLD_*` passes
   through, so a fix is a contract change and Pedram's call. It costs nothing
   while no release exists and it cannot be withdrawn afterwards (finding 15).
   Proposal: in system mode, start the script with a fixed minimal
   environment. The per-user list gains nothing from a scrub, because that
   caller can approve its own script.
2. **The maintainer's local install.** Finding 17. It solves the first user's
   problem without a release. Prepared and not run: do it only on Pedram's
   word, and he makes the grant himself. Exact steps are in
   `reference/handoff-from-rc.md`. Measure during it, and record the results
   in `docs/TCC-FINDINGS.md`: how the bundle appears in System Settings, that
   the stored requirement has no `cdhash`, `scripts/tcc-smoke.sh`, and the
   untested part of finding 18.
3. **Signing secrets.** `APPLE_CERTIFICATE`, `APPLE_CERTIFICATE_PASSWORD`,
   `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD`, `APPLE_TEAM_ID`. They exist on
   `RunMaestro/Maestro` and cannot be read back. Pedram has to set them here or
   promote them to organization secrets. Until then the release workflow stops
   at its second step by design.
4. **First release, `v0.1.0`.** After 1 and 3, and only on Pedram's word. The
   release workflow has never run, so expect to fix it.
5. **Close the check-then-use race.** The script is hashed, then executed by
   path. Options to evaluate: execute through `/dev/fd`, which changes
   `sys.path[0]` for Python and breaks sibling imports, or copy to a private
   location, which breaks relative paths.
6. **Interpreter arguments.** `python3 -u`, `uv run`, `node --flag`. Today an
   entry is one interpreter path and nothing else. Any design has to keep hard
   rule 3 true.
7. **System allowlist hardening.** In system mode, refuse a script or an
   interpreter that the user can still write. That is what would make the
   system list a real boundary.
8. **Machine-readable output** for the Maestro side, if the `rc` agent asks for
   it. `list` and `doctor` are line oriented today.
9. **Stop the test suite from touching the real identity's TCC row.** Finding
   18. One option: give development builds a different bundle identifier.
   Decide after the untested part of finding 18 is measured.
10. **Update the pinned actions.** `actions/checkout` and
    `actions/upload-artifact` at their pinned commits target Node 20. CI
    raises a deprecation warning and runs them on Node 24. It is a warning
    today. The release workflow pins the same `actions/checkout` commit.

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
- `SYSTEM_DIR` can be set at compile time. Only `tests/run.sh` does that, to
  test system mode without root. A build that ships must never define it.
- Test a privacy grant from launchd or cron, never from your own shell. Your
  shell runs inside the Maestro app's process tree and inherits its grants, so
  a pass there proves nothing. `scripts/tcc-smoke.sh` is the pattern.
- Read the TCC databases read-only (`sqlite3 "file:...?immutable=1"`). Never
  write to them and never run `tccutil reset` on a maintainer machine.
- Use `gh` for GitHub. Watch a CI run to its job-level conclusions before
  reporting it green.
- `make install` copies whatever is in `build/`. Any change to the source, the
  plist, `VERSION` or the `Makefile` makes `make` rebuild and sign ad hoc
  again. Run `make verify` right before `make install`.
- To see what macOS stored for a client, use the `csreq` recipe under
  "Diagnostics" in `docs/TCC-FINDINGS.md`. The cron test recipe is there too.
- A signed build of this source holds the grant for good (finding 15). Do not
  leave one in `build/` after a test. `make clean` removes it.

## What stayed behind

- The Maestro desktop integration lives in the Maestro repository, with the
  `rc` agent: an optional first-party feature, macOS only, that installs and
  drives this launcher. That agent also holds the full conversation history
  behind this project.
- What that feature is meant to do. This is Pedram's stated intent and it is
  not built. It sits in the Extensions panel, downloads the latest release
  from this repository, keeps it current, and uses `maestro-run` when it
  builds Cue pipelines. The `rc` agent's rules for it: verify the signature
  requirement and notarization before install, never track latest silently,
  refuse downgrades.
- Why it matters there. Inside Maestro's process tree Maestro is already the
  responsible process (finding 6), so `maestro-run` changes anything only
  because it disclaims. The value is least privilege: Full Disk Access on
  MaestroRun instead of on Maestro.app.
- What it consumes from here: the release asset name, the `.sha256` file and
  the installed version. All three are in `docs/CONTRACT.md` under "Releases"
  and "Installed version", so hard rule 6 covers them.
- Parked, not yours: the original plan had a second phase, pinning a
  uv-managed standalone Python so that Homebrew upgrades cannot break jobs.
  It belongs to the maintainer's vault agent.
- The maintainer's own job migration (LaunchAgents and crontab lines) belongs
  to his vault agent. See `reference/origin-context.md`.
