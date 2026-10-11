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
out="$(DYLD_INSERT_LIBRARIES=/tmp/evil.dylib MAESTRO_RUN_TEST_KEPT=yes "$BIN" run "$PROBE" one two 2>&1)"
check "DYLD variables are removed, others kept" "dyld=unset kept=yes args=2" "$out"

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

rm -f "$MAESTRO_RUN_CONFIG_DIR/allowlist"
out="$("$BIN" doctor 2>/dev/null)"; code=$?
contains "doctor reports the executable" "executable: " "$out"
contains "doctor reports the responsible process" "responsible-process: " "$out"
contains "doctor reports Full Disk Access" "full-disk-access: " "$out"
case "$code" in 0 | 3) pass=$((pass + 1)) ;; *) fail=$((fail + 1)); echo "FAIL doctor exit code: $code" ;; esac

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
