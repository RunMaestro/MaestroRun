# TCC findings

Measured on macOS 26.6 (Apple silicon) between 2026-08-18 and 2026-10-10. The
probe in every test is the same: open `~/Library/Messages/chat.db`, a file that
needs Full Disk Access. A test passes when the open succeeds.

Every result on this page is a measurement unless it says otherwise. Claims
that nobody has tested are listed under "Not tested" near the end. Do not move
one from that list into a document as a fact.

"Granted" below means an identity that already holds Full Disk Access.
"Ad hoc" means a binary signed without an identity, which is how Homebrew
ships Python.

## 1. Why an interpreter's grant dies

The stored requirement for each client in the system TCC database:

| Client | Stored requirement |
| --- | --- |
| Homebrew Python (ad hoc) | `cdhash H"..."` |
| `/usr/sbin/cron` (Apple) | `identifier "com.apple.cron" and anchor apple` |
| A Developer ID app | `identifier "..." and anchor apple generic and ... certificate leaf[subject.OU] = "<team>"` |

An ad-hoc binary has nothing stable to match, so macOS pins its code hash. One
machine held three separate Full Disk Access rows for three builds of the same
Python minor version. Re-granting cannot fix this. A stable identity can.

## 2. A bundle, not a bare binary

| Test | Result |
| --- | --- |
| Developer ID `.app`, rebuilt from changed source (new code hash) | pass |
| The same `.app` copied to a new path | pass |
| The same `.app` invoked through a symlink outside the bundle | pass |
| Bare Mach-O, same certificate, same identifier, requirement verified identical | **fail** |

macOS keys a bundle by its identifier and a bare executable by its path. Only
the bundle survives being rebuilt, moved and updated.

## 3. The outermost bundle wins

| Outer bundle | Nested bundle | Result |
| --- | --- | --- |
| not granted | granted identity | fail |
| granted | its own, not granted identity | pass |

A helper nested inside another `.app` is judged as the outer app. Its own
identifier does nothing. MaestroRun therefore ships as a standalone bundle and
must never be installed inside another app.

## 4. Responsibility is inherited until it is disclaimed

macOS judges the responsible process, not the process that opens the file.

| Chain | Result |
| --- | --- |
| launchd -> ad-hoc Python, not granted | fail |
| launchd -> granted binary -> `execve` -> ad-hoc Python | pass |
| launchd -> granted binary -> `posix_spawn` -> ad-hoc Python | pass |
| launchd -> granted binary -> shell -> any child, any depth | pass |
| GUI app with a grant -> shell -> ad-hoc binary | pass |
| GUI app with a grant -> Developer ID wrapper, not granted -> ad-hoc binary | pass |
| GUI app with a grant -> the same wrapper, self-disclaimed -> ad-hoc binary | **fail** |
| GUI app with a grant -> wrapper with a granted identity, self-disclaimed -> ad-hoc binary | pass |

Three consequences:

- `execve` and `posix_spawn` both inherit. The launcher can replace itself with
  the script and needs no supervising parent.
- Inside an app's process tree the app is responsible and a plain wrapper is
  ignored. A launcher that wants its own grant to apply there must disclaim:
  re-execute itself with `POSIX_SPAWN_SETEXEC` and
  `responsibility_spawnattrs_setdisclaim`.
- Once the script starts there is no boundary left. Any check has to happen in
  the launcher before it executes the script.

## 5. The shipped launcher, end to end

`maestro-run` 0.1.0 running an approved script on an ad-hoc Python that holds
no grant of its own.

How the build under test was signed matters. It was a copy of the bundle with
its identifier changed to that of a GUI app from the same team that already
held Full Disk Access on the test machine (the Maestro desktop app). It was
signed with the team's Developer ID and the hardened runtime, without a secure
timestamp, and it was not notarized. That copy satisfied a grant that already
existed, so no new grant was made. Three things follow:

- The launcher code is proven. The identifier `com.maestro.run` is not: it has
  never held a grant on any machine.
- Adding `MaestroRun.app` to Full Disk Access in System Settings is untested.
- A bundle signed under another app's identifier satisfies that app's grants.
  It must never leave a test directory. The one used here was deleted.

| Started from | Control: the same Python run directly | Through `maestro-run run` | `doctor` |
| --- | --- | --- | --- |
| launchd | fail | pass | `responsible-process: self`, `granted` |
| cron | fail | pass | `responsible-process: self`, `granted` |
| inside a GUI app's process tree | pass (inherits the app) | pass | `responsible-process: self`, `granted` |

The same build signed ad hoc, started inside the GUI app's tree, reports
`responsible-process: self` and `not-granted`, and the script fails. That is
the proof that the disclaim works: without it the script would have inherited
the app's grant.

## 6. The hardened runtime is a security requirement

An ad-hoc build without the hardened runtime honored `DYLD_INSERT_LIBRARIES`:
dyld tried to load the named library into the launcher before `main` ran. With
`--options runtime` dyld ignores it. Every build, development builds included,
is signed with the hardened runtime.

No entitlement is needed. A hardened launcher with no entitlements starts an
ad-hoc Python without `disable-library-validation`, because the interpreter is
a separate process with its own signature.

## 7. A build signed on the machine needs no notarization

The bundle in section 5 was built and signed locally and never notarized. It
passed under launchd and under cron. Notarization matters for a copy that was
downloaded, not for a bundle built on the machine that runs it.

Measured on 2026-10-10 with the real identifier, `make sign` and the team's
Developer ID:

| Check | Result |
| --- | --- |
| `make verify` | pass. Designated requirement: `identifier "com.maestro.run" and anchor apple generic and ... certificate leaf[subject.OU] = "4N4DQ24LED"` |
| The `codesign -R` check from `docs/CONTRACT.md` | pass |
| Hardened runtime flag, zero entitlements | both as required |
| `spctl --assess --type execute` | **rejected**, `source=Unnotarized Developer ID` |

So a maintainer can sign a local build and grant it without the release
pipeline. `spctl` is a check for releases, not for this path. A later notarized
release carries the same identifier and team. Section 2 says a rebuild keeps
its grant, so the grant is expected to carry over. That step from a local
build to a notarized release has not been measured.

## 8. `doctor` leaves a denied row

Measured on 2026-10-10 on macOS 26.6.1. When a launcher that holds no grant
runs `doctor`, macOS records a Full Disk Access row for client
`com.maestro.run` in the system TCC database with `auth_value` 0 (denied).
The stored requirement is the designated requirement of the build that ran:

| Build that ran `doctor` | Stored requirement afterwards |
| --- | --- |
| Ad hoc, universal | `cdhash H"..." or cdhash H"..."`, one hash per slice |
| The same source rebuilt ad hoc with a different code hash | The two new hashes. The row was rewritten. |
| Developer ID signed, not granted | `identifier "com.maestro.run" and anchor apple generic and ... certificate leaf[subject.OU] = "4N4DQ24LED"` |
| Any build, `--version` only | No change |

Consequences:

- `make test` runs `doctor`, so the test suite writes this row on every
  machine it runs on. A machine that has built and tested the launcher already
  has a `com.maestro.run` row before anyone grants anything.
- Run the Developer ID build's `doctor` once before the grant. The row then
  holds the stable requirement instead of a code hash.
- Not tested: what an ad-hoc build's `doctor` does to a row that is already
  **granted**. If macOS rewrites that row the same way, running `make test`
  would revoke the grant on that machine. Measure this once, on purpose,
  before relying on a granted machine for development.

## 9. One architecture per build

Measured on 2026-10-10 on Apple silicon, macOS 26.6.1. Until that day the
launcher was one universal binary, `arm64` and `x86_64`. It is now built once
per architecture, and this section is why.

First, a probe that prints its own slice and `sysctl.proc_translated`, then
replaces itself with the next program in the chain. "Translated shell" is
`arch -x86_64 /bin/bash`.

| Chain | Slice each program ran |
| --- | --- |
| native shell -> `arm64` only -> universal | `arm64`, `arm64` |
| translated shell -> universal -> universal | `x86_64`, `x86_64` |
| translated shell -> `arm64` only -> `arm64` only -> universal | `arm64`, `arm64`, **`x86_64`** |
| `arch -x86_64` universal -> `arm64` only -> universal | `x86_64`, `arm64`, **`x86_64`** |

Then the launcher, running an approved `#!/bin/sh` script that prints
`sysctl.proc_translated`. `/bin/sh` is universal.

| Started from | Launcher build | The script ran |
| --- | --- | --- |
| native shell | universal | native |
| `arch -x86_64`, directly | universal | translated |
| translated shell | universal | translated |
| translated shell | `arm64` only | translated |
| `arch -x86_64`, directly | `arm64` only | Did not start: `Bad CPU type in executable` |

Consequences:

- A process with a translated ancestor selects the Intel slice of every
  universal binary it starts. The preference survives `fork` and `execve`,
  and it survives passing through a binary that has no Intel slice.
- A universal launcher started that way runs under Rosetta. Nothing in the
  launcher can prevent it: the slice is chosen before `main` runs.
- A launcher with one slice is never translated on Apple silicon. The script
  still is when its interpreter is universal, because the launcher does not
  reset the preference.
- Which slice the disclaim re-execution selects is no longer a question.
  There is one.

The suite passes for the `x86_64` build under Rosetta: `make test ARCH=x86_64`
on Apple silicon. Before the split, `arch -x86_64 /bin/bash tests/run.sh`
passed against the universal build.

Observed, cause not isolated: a machine that had run the universal build
translated showed the macOS notice "Support Ending for Intel-based Apps",
which named MaestroRun and said that this version will not open in a future
release of macOS. Not tested: whether the notice appears when an `arm64` only
launcher has a translated ancestor. The launcher itself is native then.

The machine's architecture, as an installer or a build has to read it:

| Read from | Native | Under Rosetta |
| --- | --- | --- |
| `uname -m` | `arm64` | `x86_64` |
| `sysctl -n hw.optional.arm64` | `1` | `1` |

On an Intel machine `uname -m` prints `x86_64` and the `sysctl` key does not
exist (`unknown oid`). Measured on GitHub's `macos-26-intel` runner, where the
`x86_64` build also passes the behavior suite. That suite needs no privacy
grant, so it says nothing about TCC on Intel.

## Not tested

Nobody has measured any of these. Each has been stated as a fact at some point
and should not be again until it has a row in a table above.

| Claim | State |
| --- | --- |
| `com.maestro.run` can be granted Full Disk Access and keep it | Untested. Section 5 used a stand-in identifier. |
| How `MaestroRun.app` appears in System Settings | Untested. It is an `LSUIElement` bundle with no icon. |
| The bundle shows a proper name in Login Items & Extensions | Untested. The "App Background Activity" notice that names an interpreter comes from Background Task Management, a separate subsystem from TCC. Everything on this page is TCC only. |
| The five `NS*UsageDescription` strings in `Info.plist` do anything | Untested. Only Full Disk Access was measured. Whether a Contacts, Calendars, Reminders, Photos or Apple Events prompt appears for a job started by launchd, and whether it names this launcher, is unknown. |
| It works on macOS 11 through 25 | Untested. Everything ran on macOS 26.6. The 11.0 minimum in the `Makefile` and the plist is unverified, and so is the presence of the `responsibility_*` symbols on older systems. |
| A grant works on Intel hardware | Untested. Every TCC result on this page is from Apple silicon. Section 9 has what the behavior suite showed on Intel. |
| Notarization will accept this binary | Unknown until the first submission. A past remark that the allowlist would help notarization review was speculation. |
| A grant made for a local build carries over to a notarized release | Expected from section 2, not measured. |
| An ad-hoc `doctor` leaves a granted row alone | Untested. See section 8. |

## Diagnostics

These need a shell that can read the system TCC database, for example one
inside an app that holds Full Disk Access. Open the database read-only and
never write to it.

The stored requirement for a client. For a bundle the client is its
identifier, for a bare binary it is its path:

```bash
sqlite3 "file:/Library/Application Support/com.apple.TCC/TCC.db?immutable=1" \
  "select hex(csreq) from access where service='kTCCServiceSystemPolicyAllFiles' and client='com.maestro.run'" \
  | xxd -r -p > blob.bin
csreq -r blob.bin -t
```

After a grant the output must name the identifier and the team and must not
contain `cdhash`. The same table has `auth_value`: 0 is denied, 2 is allowed.

A test under cron that leaves the crontab as it was:

```bash
crontab -l > crontab.backup
# append one line per test at the minute given by: date -v+2M '+%M %H'
# wait for it to fire, then:
crontab crontab.backup
crontab -l | diff - crontab.backup   # no output: the crontab is identical
```

A test under launchd: `scripts/tcc-smoke.sh`.

## Open question

Under cron, a child signed by Apple (`/usr/bin/python3`, `/bin/dd`) could open
the probe file, and an ad-hoc child could not, even when an Apple-signed
process sat between cron and the ad-hoc child. Inside a GUI app's tree an
ad-hoc child passed. The difference is not explained. It does not affect the
launcher, which disclaims and is then judged on its own identity in all three
places.

A lead, measured: on the test machine `/usr/sbin/cron` holds its own Full Disk
Access row (the requirement in section 1). That accounts for the Apple-signed
children passing under cron. It does not account for an ad-hoc child failing
there while it passes inside a GUI app's tree.
