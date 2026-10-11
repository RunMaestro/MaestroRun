# Threat model

MaestroRun holds a powerful grant and hands it to scripts. This page says
plainly what stands between that grant and code you did not approve.

## What you get

1. **A registry.** Only scripts on the allowlist run with the grant.
2. **A tamper check.** A script is hashed on every run. If it changed since you
   approved it, it does not run. An agent or an update that rewrites an
   approved script loses the grant until you look at it again.
3. **A record.** Every allowed and denied run is logged.
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
| Check and use are separate steps | The script is hashed, then executed by path. A process that swaps the file in between wins the race. |
| The grant is inherited | Once the script starts, everything it launches has the grant, at any depth. There is no way to narrow it afterwards. |

Compare this with the alternative it replaces. A grant given directly to an
interpreter is a grant to every script that interpreter is ever asked to run,
with no registry, no tamper check and no record.

## The system allowlist

Create `/Library/Application Support/MaestroRun/allowlist` with
`sudo maestro-run approve --system <script>`. From then on it is the only list
read, and changing it takes an administrator password. That closes the first
gap. The others remain unless the script and its interpreter also live where
only root can write.

## Rules that keep this page true

- The launcher never accepts an interpreter or a command on the `run` command
  line. Both come from the allowlist.
- A list that cannot be trusted approves nothing.
- Releases are never signed without the hardened runtime and never carry
  entitlements.
