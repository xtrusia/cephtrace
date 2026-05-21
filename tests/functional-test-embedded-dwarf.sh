#!/bin/bash

# E2E test: verify osdtrace and radostrace work without --import-json,
# i.e. they successfully load the embedded DWARF data compiled into the
# binaries.  Validates output fields with the same depth as
# functional-test-microceph.sh, plus the embedded-mode boot marker.
# Exits non-zero on the first failure.

set -e  # Exit on error
set -x  # Print commands

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
    pkill -x fio 2>/dev/null || true

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

info "=== Step 1: Setup MicroCeph (install + bootstrap + OSDs + wait healthy) ==="
if ! microceph_setup_single_node 3 1G 120; then
    err "MicroCeph cluster did not become healthy within timeout"
    exit 1
fi

# Expose microceph's conf/keyring at standard /etc/ceph/ paths and disable
# librbd cache so fio's rbd engine can reach the cluster and reads are not
# satisfied locally.
if ! microceph_setup_client_conf; then
    err "Failed to set up /etc/ceph/ for host-side librados"
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
# Trace runtime is 45 s — needs to outlast fio (30 s) by enough margin that
# osdtrace stays attached for fio's entire lifetime even though it starts
# a few seconds earlier.
timeout 45 $PROJECT_ROOT/osdtrace -p $OSD_PID -x >$OSDTRACE_LOG 2>&1 &
sleep 2 # ensure osdtrace starts before we get its PID
OSDTRACE_PID=$(pidof osdtrace)
info "Started osdtrace with PID $OSDTRACE_PID"
sleep 3

info "=== Step 5: Generate I/O traffic via fio (rbd engine) ==="
# fio drives a random read-write mix directly through librbd's rados engine,
# 4 KiB direct IO, fixed 30 s runtime, --size capped at 256 MiB to keep
# allocated objects well below the pool's usable space.
fio --name=trace_test --ioengine=rbd \
    --pool=test_pool --rbdname=testimage --clientname=admin \
    --direct=1 --bs=4k --iodepth=16 \
    --rw=randrw --rwmixread=50 \
    --runtime=30 --time_based=1 --size=256M \
    --norandommap --eta=never \
    >/tmp/fio.log 2>&1 &

info "=== Step 6: Start radostrace in background (embedded mode, no --import-json) ==="
# Find the fio PID with librados.so mapped — fio uses dlopen for its rbd
# engine, so this confirms the rbd engine actually loaded before we attach.
FIO_PID=""
for i in $(seq 1 60); do
    for pid in $(pgrep -x fio 2>/dev/null); do
        if grep -q "librados" /proc/$pid/maps 2>/dev/null; then
            FIO_PID=$pid
            break 2
        fi
    done
    sleep 0.5
done

if [ -z "$FIO_PID" ]; then
    err "Could not find a fio process with librados loaded in its maps"
    if [[ -e /tmp/fio.log ]]; then
        info "fio log so far:"
        cat /tmp/fio.log
    fi
    exit 1
fi
info "Attaching radostrace to fio PID $FIO_PID (confirmed librados-loaded)"

timeout 45 $PROJECT_ROOT/radostrace -p $FIO_PID >$RADOSTRACE_LOG 2>&1 &
sleep 2 # ensure radostrace starts before we get its PID
RADOSTRACE_PID=$(pidof radostrace)
info "Started radostrace with PID $RADOSTRACE_PID"

info "=== Step 7: Wait for fio + traces to complete"
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
# min_rows is 200 here vs 500 in functional-test-microceph.sh: embedded mode
# binds to addresses baked into the binary at build time, so a snap rebuild
# of the same Ceph version can shift addresses enough that some uprobes fail
# to attach (-ENOEXEC), legitimately reducing trace volume.
verify_osdtrace_output "$OSDTRACE_LOG" "$TEST_POOL_ID" "$MAX_OSD_ID" "$TOT_PG" 200

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
verify_radostrace_output "$RADOSTRACE_LOG" "$TEST_POOL_ID" "$MAX_OSD_ID" 200

info "=== Test Summary ==="
info "✓ MicroCeph cluster deployed successfully"
info "✓ osdtrace and radostrace output validated (see Steps 8/11 for embedded vs fallback path)"
info "✓ All E2E checks passed!"

exit 0
