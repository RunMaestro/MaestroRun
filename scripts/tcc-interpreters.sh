#!/bin/bash
# Local check of the one claim MaestroRun exists for: the interpreter can
# change and the grant stays. It approves one Python script once, with a
# symlink as its interpreter. Then, for each interpreter given, it points the
# symlink at that interpreter and runs the script under launchd through
# `maestro-run run`. The allowlist is not touched between the runs.
#
# The script reads the Full Disk Access decision and opens a protected file
# only when the decision is "granted", so a run that holds nothing leaves no
# denied row. See docs/TCC-FINDINGS.md section 11.
#
# Give it interpreters that hold no Full Disk Access row of their own.
# Otherwise a pass does not show that the launcher's grant was the one used.
#
# usage: scripts/tcc-interpreters.sh /path/to/MaestroRun.app /path/to/python3.x [/path/to/python3.y ...]
set -eu

USAGE="usage: scripts/tcc-interpreters.sh /path/to/MaestroRun.app /path/to/python3.x [...]"
# launchd needs an absolute path to the program.
APP="$(cd "${1:?$USAGE}" && pwd)"
shift
[ "$#" -ge 1 ] || { echo "$USAGE" >&2; exit 1; }
BIN="$APP/Contents/MacOS/maestro-run"
LABEL="com.maestro.run.interpreters"
DOMAIN="gui/$(id -u)"
WORK="$(mktemp -d)"
trap 'launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true; rm -rf "$WORK"' EXIT

[ -x "$BIN" ] || { echo "no maestro-run binary in $APP" >&2; exit 1; }

cat > "$WORK/job.py" <<'PY'
import ctypes, os, pwd, sys

cf = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
tcc = ctypes.CDLL("/System/Library/PrivateFrameworks/TCC.framework/TCC")
cf.CFStringCreateWithCString.restype = ctypes.c_void_p
cf.CFStringCreateWithCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint32]
tcc.TCCAccessPreflight.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
service = cf.CFStringCreateWithCString(None, b"kTCCServiceSystemPolicyAllFiles", 0x08000100)
decision = {0: "granted", 1: "denied", 2: "unknown"}.get(tcc.TCCAccessPreflight(service, None), "other")

access = "not-attempted"
if decision == "granted":
    path = pwd.getpwuid(os.getuid()).pw_dir + "/Library/Application Support/com.apple.TCC/TCC.db"
    try:
        os.close(os.open(path, os.O_RDONLY))
        access = "open-ok"
    except OSError as error:
        access = "open-failed-" + error.strerror

print("version\t%d.%d.%d" % sys.version_info[:3])
print("interpreter\t" + os.path.realpath(sys.executable))
print("full-disk-access\tpreflight=%s\taccess=%s" % (decision, access))
print("done")
PY

cat > "$WORK/job.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>$LABEL</string>
	<key>ProgramArguments</key>
	<array><string>$BIN</string><string>run</string><string>$WORK/job.py</string></array>
	<key>EnvironmentVariables</key>
	<dict><key>MAESTRO_RUN_CONFIG_DIR</key><string>$WORK/config</string></dict>
	<key>StandardOutPath</key><string>$WORK/out.txt</string>
	<key>StandardErrorPath</key><string>$WORK/out.txt</string>
	<key>RunAtLoad</key><true/>
</dict>
</plist>
PLIST

export MAESTRO_RUN_CONFIG_DIR="$WORK/config"
mkdir "$WORK/config"
ln -s "$1" "$WORK/python"
"$BIN" approve --interpreter "$WORK/python" "$WORK/job.py" > /dev/null
approved="$(shasum -a 256 < "$WORK/config/allowlist")"

failed=0
for python in "$@"; do
	ln -sfn "$python" "$WORK/python"
	rm -f "$WORK/out.txt"
	launchctl bootstrap "$DOMAIN" "$WORK/job.plist"
	tries=0
	until grep -q '^done$' "$WORK/out.txt" 2>/dev/null; do
		tries=$((tries + 1))
		[ "$tries" -lt 30 ] || break
		sleep 1
	done
	launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
	echo "== $python"
	cat "$WORK/out.txt" 2>/dev/null || echo "no output"
	grep -q 'access=open-ok$' "$WORK/out.txt" 2>/dev/null || failed=1
	echo
done

[ "$(shasum -a 256 < "$WORK/config/allowlist")" = "$approved" ] && echo "allowlist: unchanged, one approval" ||
	{ echo "allowlist: changed"; failed=1; }
"$BIN" list
exit "$failed"
