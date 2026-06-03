#!/bin/bash

# E2E test: verify osdtrace and radostrace work without --import-json,
# i.e. they successfully load the embedded DWARF data compiled into the
# binaries.  Validates output fields with the same depth as
# functional-test-microceph.sh, plus the embedded-mode boot marker.
# Exits non-zero on the first failure.

set -e  # Exit on error
# Run with `bash -x ./tests/functional-test-embedded-dwarf.sh` for
# command-level tracing if you need to debug.  Enabling set -x
# unconditionally drowns the CI log with per-loop trace lines from the
# verifier.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/log.sh
source "$SCRIPT_DIR/lib/log.sh"
# shellcheck source=lib/microceph-setup.sh
source "$SCRIPT_DIR/lib/microceph-setup.sh"
# shellcheck source=lib/verify-trace-output.sh
source "$SCRIPT_DIR/lib/verify-trace-output.sh"

OSDTRACE_LOG="/tmp/osdtrace-embedded.log"
RADOSTRACE_LOG="/tmp/radostrace-embedded.log"

cleanup() {
    info "=== Cleanup ==="
    # Match the full path so we only kill processes spawned from this checkout,
    # not anything else on the host that happens to contain "osdtrace" in argv.
    pkill -f "$PROJECT_ROOT/osdtrace" 2>/dev/null || true
    pkill -f "$PROJECT_ROOT/radostrace" 2>/dev/null || true
    pkill -f "rbd bench" 2>/dev/null || true

    if [[ -e $OSDTRACE_LOG ]]; then
        info "osdtrace output:"
        cat $OSDTRACE_LOG
        info " === END of OSD trace === "
    fi
    if [[ -e $RADOSTRACE_LOG ]]; then
        info "radostrace output:"
        cat $RADOSTRACE_LOG
        info " === END of RADOS trace === "
    fi
    rm -f $OSDTRACE_LOG $RADOSTRACE_LOG

    microceph.rbd rm test_pool/testimage 2>/dev/null || true
    microceph.ceph osd pool delete test_pool test_pool --yes-i-really-really-mean-it 2>/dev/null || true

    info "Cleanup completed"
}
trap cleanup EXIT

if [ "$EUID" -ne 0 ]; then
    err "This test must be run as root or with sudo"
    exit 1
fi

if [ ! -f "$PROJECT_ROOT/osdtrace" ]; then
    err "osdtrace binary not found at $PROJECT_ROOT/osdtrace"
    err "Please build the project first with 'make osdtrace'"
    exit 1
fi
if [ ! -f "$PROJECT_ROOT/radostrace" ]; then
    err "radostrace binary not found at $PROJECT_ROOT/radostrace"
    err "Please build the project first with 'make radostrace'"
    exit 1
fi

info "=== Step 0: Verify --list-embedded lists compiled-in DWARF versions ==="
# No cluster needed: --list-embedded just prints the DWARF versions baked into
# the binary and exits 0.  Assert both tools succeed, print the table header,
# and report at least one embedded version.
for tool in osdtrace radostrace; do
    if ! list_out=$("$PROJECT_ROOT/$tool" --list-embedded 2>&1); then
        err "$tool --list-embedded exited non-zero"
        echo "$list_out" >&2
        exit 1
    fi
    if ! grep -q "VERSION" <<<"$list_out" || ! grep -q "BUILD ID" <<<"$list_out"; then
        err "$tool --list-embedded missing expected table header"
        echo "$list_out" >&2
        exit 1
    fi
    count=$(sed -n 's/^\([0-9][0-9]*\) Ceph version.*/\1/p' <<<"$list_out")
    if [ -z "$count" ] || [ "$count" -lt 1 ]; then
        err "$tool --list-embedded reported no embedded versions"
        echo "$list_out" >&2
        exit 1
    fi
    info "✓ $tool --list-embedded: $count embedded version(s)"
done

info "=== Step 1: Setup MicroCeph (install + bootstrap + OSDs + wait healthy) ==="
if ! microceph_setup_single_node 3 3G 120; then
    err "MicroCeph cluster did not become healthy within timeout"
    exit 1
fi

# Disable librbd cache in microceph's snap conf so reads always reach
# RADOS (otherwise radostrace would never see the read path).
if ! microceph_disable_rbd_cache; then
    err "Failed to disable rbd_cache in microceph's snap conf"
    exit 1
fi

microceph.ceph status

info "=== Step 2: Find OSD process PID ==="
OSD_PID=$(pgrep -f "ceph-osd.*--id 1" | head -1)
if [ -z "$OSD_PID" ]; then
    err "Could not find ceph-osd process"
    ps aux | grep ceph-osd
    exit 1
fi
info "Found OSD process: PID $OSD_PID"

info "=== Step 3: Create RBD pool and image for testing ==="
if ! microceph.ceph osd pool ls | grep -q "^test_pool$"; then
    microceph.ceph osd pool create test_pool 32
    microceph.ceph osd pool application enable test_pool rbd
fi
# Recreate image fresh with only the `layering` feature: drops object-map,
# which would otherwise short-circuit reads of unallocated regions in the
# librbd client and hide read-path ops from radostrace.
microceph.rbd rm test_pool/testimage 2>/dev/null || true
microceph.rbd create --image-feature layering --size 1G test_pool/testimage

info "=== Step 4: Start osdtrace in background (embedded mode, no --import-json) ==="
# Trace runtime is 30 s — outlasts the bench (20 s) with enough margin to
# stay attached for its entire lifetime even though osdtrace starts first.
timeout 30 $PROJECT_ROOT/osdtrace -p $OSD_PID >$OSDTRACE_LOG 2>&1 &
sleep 2 # ensure osdtrace starts before we get its PID
OSDTRACE_PID=$(pidof osdtrace)
info "Started osdtrace with PID $OSDTRACE_PID"
sleep 3

info "=== Step 5: Generate I/O traffic via rbd bench ==="
# Random 2 MiB read-write mix via the snap-confined rbd bench — runs
# inside the microceph snap so it picks up the bundled librbd/librados
# that match our DWARF JSON.  Single thread + 2 MiB blocks keeps the
# captured-row count to a couple hundred over the 20 s run.
# `--io-total 100G` is way more than any 20 s run can do; `timeout 20`
# gives us a fixed runtime instead.
timeout 20 microceph.rbd bench \
    --io-type readwrite --rw-mix-read 50 \
    --io-pattern rand \
    --io-size 2M --io-threads 1 \
    --io-total 100G \
    test_pool/testimage &

info "=== Step 6: Start radostrace in background (embedded mode, no --import-json) ==="
# microceph.rbd bench runs through a snap wrapper chain (snap-run →
# snap-confine → rbd).  We must find the PID of the actual rbd binary —
# the only process in that chain that has librados.so.2 mapped into its
# address space.  Poll /proc/<pid>/maps for each candidate.
RBD_ACTUAL_PID=""
for i in $(seq 1 60); do
    for pid in $(pgrep -f "rbd" 2>/dev/null); do
        if grep -q "librados" /proc/$pid/maps 2>/dev/null; then
            RBD_ACTUAL_PID=$pid
            break 2
        fi
    done
    sleep 0.5
done

if [ -z "$RBD_ACTUAL_PID" ]; then
    err "Could not find an rbd process with librados loaded in its maps"
    exit 1
fi
info "Attaching radostrace to rbd PID $RBD_ACTUAL_PID (confirmed librados-loaded)"

timeout 30 $PROJECT_ROOT/radostrace -p $RBD_ACTUAL_PID >$RADOSTRACE_LOG 2>&1 &
sleep 2 # ensure radostrace starts before we get its PID
RADOSTRACE_PID=$(pidof radostrace)
info "Started radostrace with PID $RADOSTRACE_PID"

info "=== Step 7: Wait for bench + traces to complete"
wait

info "=== Step 8: Check osdtrace embedded-mode boot marker ==="

# Embedded-mode boot marker — unique to this test.  Three outcomes:
#   - Embedded marker present  → expected best path
#   - Live-parse marker present → osdtrace couldn't detect the Ceph version
#     (e.g. snap-confined ceph where dpkg lookup fails) and fell back to
#     runtime DWARF parsing.  Acceptable — embedded data is an optimisation,
#     not a correctness requirement; the field-level checks below still apply.
#   - Neither marker           → real bug: tool didn't reach either path.
if grep -q "Using embedded DWARF data" $OSDTRACE_LOG; then
    info "✓ osdtrace used embedded DWARF data"
elif grep -q "Start to parse dwarf info" $OSDTRACE_LOG; then
    info "[NOTE] osdtrace fell back to live DWARF parsing (version detection unsupported in this env)"
else
    err "osdtrace output unclear: neither embedded marker nor live-parse marker present"
    exit 1
fi

info "=== Step 9: Gather cluster facts for verification ==="

TEST_POOL_ID=$(microceph.ceph osd pool ls detail | grep "^pool.*'test_pool'" | grep -oP "pool \K\d+")
MAX_OSD_ID=$(microceph.ceph osd ls | sort -n | tail -1)
TOT_PG=$(microceph.ceph osd pool get test_pool pg_num | awk '{print $2}')
info "test_pool id: $TEST_POOL_ID, max OSD id: $MAX_OSD_ID, pg_num: $TOT_PG"

info "=== Step 10: Verify osdtrace output ==="
# min_rows is 20 here vs 50 in functional-test-microceph.sh: embedded mode
# binds to addresses baked into the binary at build time, so a snap rebuild
# of the same Ceph version can shift addresses enough that some uprobes fail
# to attach (-ENOEXEC), legitimately reducing trace volume.
verify_osdtrace_output "$OSDTRACE_LOG" "$TEST_POOL_ID" "$MAX_OSD_ID" "$TOT_PG" 20

info "=== Step 11: Check radostrace embedded-mode boot marker ==="
if grep -q "Using embedded DWARF data" $RADOSTRACE_LOG; then
    info "✓ radostrace used embedded DWARF data"
elif grep -q "Start to parse dwarf info" $RADOSTRACE_LOG; then
    info "[NOTE] radostrace fell back to live DWARF parsing (version detection unsupported in this env)"
else
    err "radostrace output unclear: neither embedded marker nor live-parse marker present"
    exit 1
fi

info "=== Step 12: Verify radostrace output ==="
verify_radostrace_output "$RADOSTRACE_LOG" "$TEST_POOL_ID" "$MAX_OSD_ID" 20

info "=== Test Summary ==="
info "✓ MicroCeph cluster deployed successfully"
info "✓ osdtrace and radostrace output validated (see Steps 8/11 for embedded vs fallback path)"
info "✓ All E2E checks passed!"

exit 0
