#!/bin/bash
#
# Negative-path / argument-parsing test for osdtrace's --id option.
# Validates the error branches that don't require a running ceph cluster:
#
#   - --id with a non-existent OSD ID fails with "no running ceph-osd
#     process found"
#   - --id combined with -p fails with "mutually exclusive"
#   - --id with a non-numeric value fails with "Invalid --id value"
#   - --id with a negative value fails with "must be non-negative"
#   - the removed -o option is rejected by getopt
#
# Exit codes from `parse_args() < 0` get converted to `return 0` inside
# osdtrace's `main()`, so we anchor on stderr substrings rather than the
# numeric exit code for parse-time errors.  For main()-time errors (--id
# resolution, --id/-p conflict) the binary exits 1 — those we check both.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OSDTRACE="$PROJECT_ROOT/osdtrace"

# shellcheck source=lib/log.sh
source "$SCRIPT_DIR/lib/log.sh"

if [ ! -x "$OSDTRACE" ]; then
    err "osdtrace binary not found at $OSDTRACE (build with 'make osdtrace')"
    exit 1
fi

pass_count=0
fail_count=0

# expect_stderr <name> <expected_substring> <expected_exit_or_-1> -- <argv...>
expect_stderr() {
    local name=$1 needle=$2 want_exit=$3
    shift 3
    [ "$1" = "--" ] && shift

    local out
    local rc=0
    out=$("$OSDTRACE" "$@" 2>&1) || rc=$?

    local ok=1
    if [ "$want_exit" != "-1" ] && [ "$rc" -ne "$want_exit" ]; then
        err "[$name] expected exit $want_exit, got $rc"
        ok=0
    fi
    if ! grep -qF -- "$needle" <<< "$out"; then
        err "[$name] expected stderr/stdout substring not found: $needle"
        err "----- actual output -----"
        echo "$out" >&2
        err "-------------------------"
        ok=0
    fi

    if (( ok )); then
        info "[$name] PASS"
        pass_count=$((pass_count + 1))
    else
        fail_count=$((fail_count + 1))
    fi
}

# Picking an OSD ID that is essentially never going to exist on a CI host,
# so the "not found" branch fires deterministically regardless of whether
# the test host happens to have a Ceph OSD running.
NONEXISTENT_OSD_ID=2147483600

info "=== osdtrace --id option negative-path tests ==="

expect_stderr "not_found" \
    "no running ceph-osd process found with OSD ID $NONEXISTENT_OSD_ID" \
    1 -- --id "$NONEXISTENT_OSD_ID"

expect_stderr "conflict_with_-p" \
    "--id and -p are mutually exclusive" \
    1 -- --id "$NONEXISTENT_OSD_ID" -p 1

expect_stderr "non_numeric" \
    "Invalid --id value: abc" \
    -1 -- --id abc

expect_stderr "negative" \
    "Invalid --id value (must be non-negative): -1" \
    -1 -- --id -1

# -o was removed when --id replaced it; getopt should print the standard
# `invalid option` diagnostic.  Anchor on `?` being treated as the help
# fall-through (which prints the usage banner that starts with "Usage:").
expect_stderr "o_option_removed" \
    "Usage:" \
    -1 -- -o 0

info "=== Summary: $pass_count passed, $fail_count failed ==="
if (( fail_count > 0 )); then
    exit 1
fi
exit 0
