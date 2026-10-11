#!/bin/bash
# Local check of which privacy grants reach a script that MaestroRun starts,
# service by service. It builds scripts/tcc-probe.m, signs it ad hoc so that it
# has no grant of its own, and runs it six ways:
#
#   shell-direct       this shell -> probe
#   shell-launcher     this shell -> maestro-run run -> script, which becomes the probe
#   launchd-direct     launchd -> probe
#   launchd-exec       launchd -> maestro-run run -> script, which becomes the probe
#   launchd-child      launchd -> maestro-run run -> script -> probe as a child
#   launchd-detached   as launchd-child, but the probe starts after the script exited
#
# The two "direct" runs are the controls. The probe reads decisions and only
# touches a service that is already allowed, so no run raises a prompt. The
# controls leave out Full Disk Access and Accessibility: asking about either
# one without a grant makes macOS record a denied row for the caller.
#
# It needs the Xcode command line tools, and no system allowlist: it approves
# its own three scripts in a throwaway per-user list.
#
# usage: scripts/tcc-matrix.sh /path/to/MaestroRun.app [apple-event-target-bundle-id ...]
set -eu

# launchd needs an absolute path to the program.
APP="$(cd "${1:?usage: scripts/tcc-matrix.sh /path/to/MaestroRun.app [apple-event-target-bundle-id ...]}" && pwd)"
shift
BIN="$APP/Contents/MacOS/maestro-run"
HERE="$(cd "$(dirname "$0")" && pwd)"
LABEL="com.maestro.run.matrix"
DOMAIN="gui/$(id -u)"
JOBS="direct exec child detached"
WORK="$(mktemp -d)"
PROBE="$WORK/tcc-probe"

cleanup() {
	for name in $JOBS; do
		launchctl bootout "$DOMAIN/$LABEL.$name" 2>/dev/null || true
	done
	rm -rf "$WORK"
}
trap cleanup EXIT

[ -x "$BIN" ] || { echo "no maestro-run binary in $APP" >&2; exit 1; }

clang -O2 -fobjc-arc -o "$PROBE" "$HERE/tcc-probe.m" \
	-framework AppKit -framework ApplicationServices -framework AVFoundation -framework Contacts \
	-framework CoreServices -framework EventKit -framework Foundation -framework Photos
codesign --force --sign - "$PROBE" 2>/dev/null

# MaestroRun replaces itself with the script. In exec.sh the script replaces
# itself with the probe, so one process is the launcher, the shell and the
# probe in turn. That is what a Python script is: the interpreter keeps the pid.
cat > "$WORK/exec.sh" <<SH
#!/bin/sh
exec "$PROBE" "\$@"
SH
cat > "$WORK/child.sh" <<SH
#!/bin/sh
"$PROBE" "\$@"
SH
# The probe starts after this script has exited. MaestroRun replaced itself
# with this script, so the process that held the identity is gone by then.
cat > "$WORK/detached.sh" <<SH
#!/bin/sh
( sleep 3; exec "$PROBE" "\$@" > "$WORK/launchd-detached.txt" 2>&1 ) &
SH
chmod +x "$WORK/exec.sh" "$WORK/child.sh" "$WORK/detached.sh"

export MAESTRO_RUN_CONFIG_DIR="$WORK/config"
mkdir "$WORK/config"
for script in exec child detached; do
	"$BIN" approve "$WORK/$script.sh" > /dev/null
done

# job <name> <output file> <program> [args...]: run once under launchd and
# wait for the probe to finish.
job() {
	local name="$1" out="$2" plist="$WORK/$1.plist" arg tries=0
	shift 2
	{
		cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>$LABEL.$name</string>
	<key>ProgramArguments</key>
	<array>
PLIST
		for arg in "$@"; do
			printf '\t\t<string>%s</string>\n' "$arg"
		done
		cat <<PLIST
	</array>
	<key>EnvironmentVariables</key>
	<dict><key>MAESTRO_RUN_CONFIG_DIR</key><string>$WORK/config</string></dict>
	<key>StandardOutPath</key><string>$WORK/$name.job.txt</string>
	<key>StandardErrorPath</key><string>$WORK/$name.job.txt</string>
	<key>AbandonProcessGroup</key><true/>
	<key>RunAtLoad</key><true/>
</dict>
</plist>
PLIST
	} > "$plist"
	launchctl bootstrap "$DOMAIN" "$plist"
	until grep -qE '^(done|timeout)' "$out" 2>/dev/null; do
		tries=$((tries + 1))
		[ "$tries" -lt 70 ] || break
		sleep 1
	done
	launchctl bootout "$DOMAIN/$LABEL.$name" 2>/dev/null || true
}

show() {
	echo "== $1"
	cat "$2" 2>/dev/null || echo "no output"
	echo
}

"$PROBE" --control "$@" > "$WORK/shell-direct.txt" 2>&1 || true
"$BIN" run "$WORK/exec.sh" "$@" > "$WORK/shell-launcher.txt" 2>&1 || true
job direct "$WORK/direct.job.txt" "$PROBE" --control "$@"
job exec "$WORK/exec.job.txt" "$BIN" run "$WORK/exec.sh" "$@"
job child "$WORK/child.job.txt" "$BIN" run "$WORK/child.sh" "$@"
job detached "$WORK/launchd-detached.txt" "$BIN" run "$WORK/detached.sh" "$@"

show shell-direct "$WORK/shell-direct.txt"
show shell-launcher "$WORK/shell-launcher.txt"
show launchd-direct "$WORK/direct.job.txt"
show launchd-exec "$WORK/exec.job.txt"
show launchd-child "$WORK/child.job.txt"
show launchd-detached "$WORK/launchd-detached.txt"
