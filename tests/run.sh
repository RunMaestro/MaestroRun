#!/bin/bash
# Behavior tests for maestro-run. They need no privacy grant, so they run in CI.
# Every case uses a private config directory and never touches the real allowlist.
set -u

BIN="${MAESTRO_RUN:?set MAESTRO_RUN to the maestro-run binary}"
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(mktemp -d)"
WORK="$(cd "$WORK" && pwd -P)"
export MAESTRO_RUN_CONFIG_DIR="$WORK/config"
mkdir -p "$MAESTRO_RUN_CONFIG_DIR"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0

check() {
	local name="$1" want="$2" got="$3"
	if [ "$want" = "$got" ]; then
		pass=$((pass + 1))
	else
		fail=$((fail + 1))
		printf 'FAIL %s\n  want: %s\n  got:  %s\n' "$name" "$want" "$got"
	fi
}

contains() {
	local name="$1" needle="$2" haystack="$3"
	case "$haystack" in
	*"$needle"*) pass=$((pass + 1)) ;;
	*)
		fail=$((fail + 1))
		printf 'FAIL %s\n  want substring: %s\n  got: %s\n' "$name" "$needle" "$haystack"
		;;
	esac
}

SCRIPT="$WORK/job.sh"
printf '#!/bin/sh\necho "ran:$1:$2"\nexit 7\n' > "$SCRIPT"
chmod +x "$SCRIPT"

out="$("$BIN" run "$SCRIPT" 2>&1)"; code=$?
check "unapproved script is denied" 126 "$code"
contains "unapproved message names the fix" "maestro-run approve" "$out"

out="$("$BIN" approve "$SCRIPT")"; code=$?
check "approve succeeds" 0 "$code"
contains "approve reports direct execution" "$(printf '\t-\t')" "$out"

out="$("$BIN" run "$SCRIPT" "a b" c 2>&1)"; code=$?
check "exit code passes through" 7 "$code"
check "arguments pass through unsplit" "ran:a b:c" "$out"

ln -s "$SCRIPT" "$WORK/link.sh"
out="$("$BIN" run "$WORK/link.sh" x y 2>&1)"; code=$?
check "a symlink resolves to the approved script" "ran:x:y" "$out"

mode="$(stat -f '%Lp' "$MAESTRO_RUN_CONFIG_DIR/allowlist")"
check "allowlist is private to the user" 600 "$mode"

printf '#!/bin/sh\necho tampered\n' > "$SCRIPT"
out="$("$BIN" run "$SCRIPT" 2>&1)"; code=$?
check "changed script is denied" 126 "$code"
contains "changed message says so" "changed after it was approved" "$out"
contains "list reports the change" "changed" "$("$BIN" list)"

"$BIN" approve "$SCRIPT" > /dev/null
out="$("$BIN" run "$SCRIPT" 2>&1)"; code=$?
check "re-approved script runs" "tampered" "$out"
contains "list reports ok" "ok" "$("$BIN" list)"

PLAIN="$WORK/plain.txt"
printf 'echo "interp:$1"\n' > "$PLAIN"
"$BIN" approve --interpreter /bin/sh "$PLAIN" > /dev/null
out="$("$BIN" run "$PLAIN" arg 2>&1)"; code=$?
check "interpreter mode runs a non-executable script" "interp:arg" "$out"

printf 'echo "edited:$1"\n' > "$PLAIN"
"$BIN" approve "$PLAIN" > /dev/null
out="$("$BIN" run "$PLAIN" arg 2>&1)"
check "re-approval keeps the interpreter" "edited:arg" "$out"

out="$("$BIN" approve --interpreter relative/sh "$PLAIN" 2>&1)"; code=$?
check "relative interpreter is rejected" 64 "$code"

PROBE="$WORK/envprobe"
clang -o "$PROBE" "$HERE/envprobe.c"
"$BIN" approve "$PROBE" > /dev/null
# A DYLD variable that is harmless to the launcher itself, so this case tests
# the scrub alone on any machine.
out="$(DYLD_FRAMEWORK_PATH=/nonexistent MAESTRO_RUN_TEST_KEPT=yes "$BIN" run "$PROBE" one two 2>&1)"
check "DYLD variables are removed, others kept" "dyld=unset kept=yes args=2" "$out"

# The hardened runtime is what keeps a library out of the launcher, and macOS
# enforces it only with System Integrity Protection on. Hosted CI runners have
# it off, so there this case cannot pass and is skipped out loud.
if csrutil status 2>/dev/null | grep -q 'enabled'; then
	DYLD_INSERT_LIBRARIES=/nonexistent/evil.dylib "$BIN" --version > /dev/null 2>&1; code=$?
	check "the launcher ignores DYLD_INSERT_LIBRARIES" 0 "$code"
else
	echo "SKIP the launcher ignores DYLD_INSERT_LIBRARIES: System Integrity Protection is off here"
fi

contains "allowed runs are logged" "ALLOW" "$(cat "$MAESTRO_RUN_CONFIG_DIR/log/maestro-run.log")"
contains "denied runs are logged" "DENY-changed" "$(cat "$MAESTRO_RUN_CONFIG_DIR/log/maestro-run.log")"

"$BIN" revoke "$SCRIPT" > /dev/null
out="$("$BIN" run "$SCRIPT" 2>&1)"; code=$?
check "revoked script is denied" 126 "$code"
"$BIN" revoke "$SCRIPT" > /dev/null 2>&1; code=$?
check "revoking an unknown script reports it" 1 "$code"

chmod 666 "$MAESTRO_RUN_CONFIG_DIR/allowlist"
out="$("$BIN" run "$PLAIN" 2>&1)"; code=$?
check "allowlist writable by others is refused" 126 "$code"
chmod 600 "$MAESTRO_RUN_CONFIG_DIR/allowlist"

printf 'not a valid line\n' >> "$MAESTRO_RUN_CONFIG_DIR/allowlist"
out="$("$BIN" run "$PLAIN" 2>&1)"; code=$?
check "malformed allowlist approves nothing" 126 "$code"

out="$("$BIN" run "$WORK/missing.sh" 2>&1)"; code=$?
check "missing script is denied" 126 "$code"
"$BIN" bogus > /dev/null 2>&1; code=$?
check "unknown command is a usage error" 64 "$code"
contains "version prints" "maestro-run " "$("$BIN" --version)"

# One architecture per build. A universal launcher runs its Intel slice under
# Rosetta whenever an ancestor process is translated.
check "the binary holds one architecture" 1 "$(lipo -archs "$BIN" | wc -w | tr -d ' ')"

# An installer reads the installed version to refuse a downgrade. The contract
# gives it two places to read, and they have to agree.
version="$(cat "$HERE/../VERSION")"
check "VERSION is three numbers" "" "$(printf '%s' "$version" | sed -E 's/^[0-9]+\.[0-9]+\.[0-9]+$//')"
check "version output matches VERSION" "maestro-run $version" "$("$BIN" --version)"
check "the bundle version matches VERSION" "$version" \
	"$(plutil -extract CFBundleShortVersionString raw -o - "$(dirname "$BIN")/../Info.plist")"

rm -f "$MAESTRO_RUN_CONFIG_DIR/allowlist"
out="$("$BIN" doctor 2>/dev/null)"; code=$?
contains "doctor reports the executable" "executable: " "$out"
contains "doctor reports the responsible process" "responsible-process: " "$out"
contains "doctor reports Full Disk Access" "full-disk-access: " "$out"
case "$code" in 0 | 3) pass=$((pass + 1)) ;; *) fail=$((fail + 1)); echo "FAIL doctor exit code: $code" ;; esac

# A list edited by hand can name a script twice. revoke has to remove both
# entries, or it reports success while the script stays approved.
export MAESTRO_RUN_CONFIG_DIR="$WORK/config-dup"
mkdir -p "$MAESTRO_RUN_CONFIG_DIR"
"$BIN" approve --interpreter /bin/sh "$PLAIN" > /dev/null
entry="$(grep -v '^#' "$MAESTRO_RUN_CONFIG_DIR/allowlist")"
printf '%s\n' "$entry" >> "$MAESTRO_RUN_CONFIG_DIR/allowlist"
"$BIN" revoke "$PLAIN" > /dev/null
out="$("$BIN" run "$PLAIN" arg 2>&1)"; code=$?
check "revoke removes every entry for the script" 126 "$code"

# The directory is created with a fixed mode, whatever the umask. This matters
# for the system directory: under umask 077 it would hide the list from every
# user. Only root can create that one, so the same code is tested here.
export MAESTRO_RUN_CONFIG_DIR="$WORK/config-umask"
(umask 777; "$BIN" approve "$PROBE" > /dev/null 2>&1); code=$?
check "approve works under a restrictive umask" 0 "$code"
check "the allowlist directory mode ignores the umask" 700 "$(stat -f '%Lp' "$MAESTRO_RUN_CONFIG_DIR" 2>/dev/null)"

# The system allowlist path is a compile-time constant, so these cases build
# the same source with it pointed at a private directory.
export MAESTRO_RUN_CONFIG_DIR="$WORK/config-system"
mkdir -p "$MAESTRO_RUN_CONFIG_DIR"
SYSDIR="$WORK/system"
SYSBIN="$WORK/maestro-run-system-test"
clang -DSYSTEM_DIR="\"$SYSDIR\"" -o "$SYSBIN" "$HERE/../src/maestro-run.c"
"$SYSBIN" approve "$PROBE" > /dev/null
out="$("$SYSBIN" run "$PROBE" 2>&1)"; code=$?
check "without a system allowlist the user list decides" 0 "$code"

mkdir "$SYSDIR"
touch "$SYSDIR/allowlist"
out="$("$SYSBIN" run "$PROBE" 2>&1)"; code=$?
check "a system allowlist replaces the user list" 126 "$code"
contains "a system allowlist must be owned by root" "wrong owner" "$out"

# A system list that cannot be examined is not an absent one. Falling back to
# the user list here would let a caller hide the system list from the launcher.
chmod 000 "$SYSDIR"
out="$("$SYSBIN" run "$PROBE" 2>&1)"; code=$?
chmod 700 "$SYSDIR"
check "an unreadable system allowlist approves nothing" 126 "$code"

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
