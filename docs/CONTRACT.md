# Contract

Other tools drive `maestro-run`: launchd jobs, crontabs, and the Maestro
desktop app. Everything on this page is a promise to them. Change it only with
a major version and a migration note.

## Identity

| Property | Value |
| --- | --- |
| Bundle identifier | `com.maestro.run` |
| Signing team | `4N4DQ24LED` |
| Signature | Developer ID Application, hardened runtime, no entitlements, notarized, stapled |

macOS stores every user's grant under the identifier and the team. A release
that changes either one silently revokes Full Disk Access for every user.

An installer must verify both before it puts a copy in place:

```bash
codesign --verify --strict -R='identifier "com.maestro.run" and anchor apple generic and certificate leaf[subject.OU] = "4N4DQ24LED"' MaestroRun.app
spctl --assess --type execute --verbose=2 MaestroRun.app
```

## Commands

| Command | Purpose |
| --- | --- |
| `maestro-run run <script> [args...]` | Run an approved script. Replaces itself with the script. |
| `maestro-run approve [--interpreter <path>] [--system] <script>` | Approve the script at its current contents. |
| `maestro-run revoke [--system] <script>` | Remove the script from the allowlist. |
| `maestro-run list` | One line per approved script. |
| `maestro-run doctor` | Report identity and Full Disk Access. |
| `maestro-run --version` | Print `maestro-run <version>`. |

`approve` on a script that is already approved updates its hash and keeps its
interpreter unless `--interpreter` is given. `--interpreter -` selects direct
execution.

## Output

Fields are separated by a tab.

| Command | Line |
| --- | --- |
| `approve` | `approved`, sha256, interpreter, script |
| `revoke` | `revoked`, script |
| `list` | status, sha256, interpreter, script. Status is `ok`, `changed` or `missing`. |
| `doctor` | `key: value` lines: `version`, `executable`, `responsible-process`, `allowlist`, `full-disk-access` |

`full-disk-access` is `granted`, `not-granted` or `unknown`.
`responsible-process` is `self`, a process name with a pid, or `unknown`.

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Success. For `run`, the script's own exit code is returned instead. |
| 1 | `revoke`: the script is not on the allowlist. |
| 3 | `doctor`: Full Disk Access is not in effect. |
| 64 | Usage error. |
| 126 | Denied: not approved, changed, unreadable, or the allowlist cannot be trusted. |
| 127 | The approved script or its interpreter could not be executed. |

A script that itself exits 1, 3, 64, 126 or 127 is indistinguishable from the
launcher by exit code alone. The log tells them apart.

## Allowlist

| Location | When it is used |
| --- | --- |
| `/Library/Application Support/MaestroRun/allowlist` | Whenever it exists. It is then the only list read. Owned by root. |
| `~/Library/Application Support/MaestroRun/allowlist` | Otherwise. Owned by the user, mode 600. |

Format, version 1: a header comment, then one entry per line.

```
# maestro-run allowlist v1: sha256<TAB>interpreter<TAB>script
<64 lowercase hex chars><TAB><absolute interpreter path or -><TAB><absolute script path>
```

The script path is the resolved real path. The interpreter path is stored as
given, so a symlink such as `/opt/homebrew/bin/python3` keeps following
upgrades. Paths that contain a tab or a newline are rejected. A list with the
wrong owner, write access for group or other, or a line that does not parse
approves nothing.

## Log

`~/Library/Logs/MaestroRun/maestro-run.log`, one line per `run`, tab separated:
UTC timestamp, `pid=`, `ppid=`, `uid=`, verdict, sha256, interpreter, script.
Verdicts: `ALLOW`, `DENY-not-approved`, `DENY-changed`, `DENY-unreadable`.

## Environment

| Variable | Effect |
| --- | --- |
| `MAESTRO_RUN_CONFIG_DIR` | Absolute directory that replaces the per-user allowlist directory. Logs go to its `log` subdirectory. Ignored when a system allowlist exists. Used by the tests. |
| `DYLD_*` | Removed before the script starts. |

Every other variable passes through to the script unchanged.
