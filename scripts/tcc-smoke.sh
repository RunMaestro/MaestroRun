#!/bin/bash
# Local check that an installed MaestroRun holds Full Disk Access when launchd
# starts it. It runs `maestro-run doctor` from a throwaway LaunchAgent and
# prints what doctor reported. It needs a Developer ID signed build that you
# have already granted Full Disk Access; an ad-hoc build always reports
# not-granted.
#
# usage: scripts/tcc-smoke.sh /path/to/MaestroRun.app
set -eu

APP="${1:?usage: scripts/tcc-smoke.sh /path/to/MaestroRun.app}"
BIN="$APP/Contents/MacOS/maestro-run"
LABEL="com.maestro.run.smoke"
WORK="$(mktemp -d)"
trap 'launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true; rm -rf "$WORK"' EXIT

[ -x "$BIN" ] || { echo "no maestro-run binary in $APP" >&2; exit 1; }

cat > "$WORK/job.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>$LABEL</string>
	<key>ProgramArguments</key>
	<array><string>$BIN</string><string>doctor</string></array>
	<key>StandardOutPath</key><string>$WORK/out.txt</string>
	<key>StandardErrorPath</key><string>$WORK/out.txt</string>
	<key>RunAtLoad</key><true/>
</dict>
</plist>
PLIST

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$WORK/job.plist"
sleep 3
cat "$WORK/out.txt"
grep -q '^full-disk-access: granted$' "$WORK/out.txt"
