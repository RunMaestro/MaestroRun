# Threat model

MaestroRun holds a powerful grant and hands it to scripts. This page says
plainly what stands between that grant and code you did not approve.

## What you get

1. **A registry.** Only scripts on the allowlist run with the grant.
2. **A tamper check.** A script is hashed on every run. If it changed since you
   approved it, it does not run. An agent or an update that rewrites an
   approved script loses the grant until you look at it again.
3. **A record.** Allowed and denied runs are logged. The log is best effort and
   it is yours to edit, see below.
4. **A launcher that cannot be injected into.** Every build is signed with the
   hardened runtime and carries no entitlements, so `DYLD_INSERT_LIBRARIES`
   cannot load code into the process that holds the grant. `DYLD_*` is also
   removed before the script starts.

## What you do not get

MaestroRun is not a sandbox, and the default setup is not a security boundary
against other code running as you.

| Gap | Detail |
| --- | --- |
| The per-user allowlist is writable by you | So it is writable by any process running as you. Such a process can approve its own script and run it. |
| The interpreter is pinned by path, not by content | Pinning its hash would bring the upgrade problem straight back. A process that can replace the interpreter binary gets the grant. Homebrew's tree is writable by its admin user. |
| Imports are not pinned | The script's hash covers one file. The modules it imports can change freely. |
| Check and use are separate steps | The script is hashed, then executed by path. A process that swaps the file in between wins the race. It needs write access to the script or to a directory on its path. |
| The caller controls how the script starts | Only `DYLD_*` is removed. Every other variable, the working directory, the arguments and the open files come from whoever starts the launcher. That is enough to run other code inside an approved, unchanged script. `BASH_ENV` is read by every `bash` script. `PATH` picks the interpreter for a `#!/usr/bin/env` line and every command the script names. `PYTHONPATH` loads a `sitecustomize.py` into every Python script. All three were reproduced against 0.1.0. The run is logged as `ALLOW` and `list` reports `ok`. |
| The record can be edited | The log is a file you own. A process running as you can change it, delete it or make it unwritable, and a run goes ahead when the log cannot be written. `MAESTRO_RUN_CONFIG_DIR` moves the per-user list and the log to a directory the caller picks. |
| `run` reports on any path | Before the allowlist is read, the launcher resolves the path it was given and prints the resolved path or the error. A caller learns whether the path exists and where its symlinks point, as seen with the grant. |
| Every signed build keeps the grant | macOS stores the grant under the identifier and the team, not the version. A copy of an old release holds it as well as the installed one. A defect in a signed release cannot be withdrawn by shipping a fix. |
| The grant is inherited | Once the script starts, everything it launches has the grant, at any depth. A process that keeps running after the script has exited keeps it too. There is no way to narrow it afterwards. |
| Every grant is handed on, not only Full Disk Access | Whatever you switch on for MaestroRun under Privacy & Security reaches every approved script: Accessibility, Screen Recording, Input Monitoring, Automation, Contacts and the rest. Measured, see `docs/TCC-FINDINGS.md` section 10. With the per-user allowlist that means every process running as you can use each of those grants without a prompt. Accessibility, Input Monitoring and Screen Recording together let a process read your keystrokes and your screen and drive other apps. Grant MaestroRun only what your scripts need. |

Compare this with the alternative it replaces. A grant given directly to an
interpreter is a grant to every script that interpreter is ever asked to run,
with no registry, no tamper check and no record.

## The system allowlist

Create `/Library/Application Support/MaestroRun/allowlist` with
`sudo maestro-run approve --system <script>`. From then on it is the only list
read, and changing it takes an administrator password. That closes the first
gap and nothing else. The system list is not a boundary today:

- The caller still controls the environment, the working directory and the
  arguments. The examples in the table above work against a script on the
  system list, even when root owns the script and its interpreter.
- The interpreter gap and the race remain unless the script and its
  interpreter live where only root can write. The launcher does not check
  that.
- `MAESTRO_RUN_CONFIG_DIR` is ignored, but the log stays in your home.

## Rules that keep this page true

- The launcher never accepts an interpreter or a command on the `run` command
  line. Both come from the allowlist.
- A list that cannot be trusted approves nothing.
- A system allowlist that exists but cannot be examined stops every command.
  The launcher falls back to the per-user list only when the system list is
  absent. A caller can hide a file from the launcher with a `sandbox-exec`
  deny rule, so any other fallback would let the caller pick its own list.
- Releases are never signed without the hardened runtime and never carry
  entitlements.
