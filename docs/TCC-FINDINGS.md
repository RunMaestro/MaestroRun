# TCC findings

Measured on macOS 26.6 (Apple silicon) between 2026-08-18 and 2026-10-10. The
probe in every test is the same: open `~/Library/Messages/chat.db`, a file that
needs Full Disk Access. A test passes when the open succeeds.

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

`maestro-run` 0.1.0, Developer ID signed with a granted identity, running an
approved script on an ad-hoc Python that holds no grant of its own:

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

## Open question

Under cron, a child signed by Apple (`/usr/bin/python3`, `/bin/dd`) could open
the probe file, and an ad-hoc child could not, even when an Apple-signed
process sat between cron and the ad-hoc child. Inside a GUI app's tree an
ad-hoc child passed. The difference is not explained. It does not affect the
launcher, which disclaims and is then judged on its own identity in all three
places.
