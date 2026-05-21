#!/bin/bash
#
# Run tests/functional-test-cephadm-rgw.sh inside a clean LXD VM, once per
# Ceph release.  Use this to validate the cephadm test + binaries on the
# developer host before pushing CI.
#
# Why a VM?  cephadm bootstrap installs systemd units, creates loopback
# devices, and binds to system addresses — none of which we want touching
# the developer's host environment.  An LXD VM (not container — cephadm
# needs full systemd + kernel namespaces) gives a disposable scratch host
# each run.
#
# Usage:
#   tests/local-cephadm-test.sh                                # all 4 releases
#   tests/local-cephadm-test.sh squid                          # one release
#   tests/local-cephadm-test.sh -k squid                       # keep VM on success
#   tests/local-cephadm-test.sh -v ubuntu:22.04 reef           # run on a 22.04 VM
#
# Flags:
#   -k           Keep the VM after a successful run (always kept on failure)
#   -v <image>   LXD image to use (default: ubuntu:24.04)
#   -c <count>   CPU count per VM (default: 4)
#   -m <ram>     RAM per VM (default: 8GiB)
#   -d <disk>    Root-disk size per VM (default: 30GiB)
#
# On failure the VM is always preserved so you can `lxc exec <vm> -- bash`
# and inspect the partial cluster state.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

KEEP_VM=0
VM_IMAGE="ubuntu:24.04"
VM_CPU=4
VM_RAM="8GiB"
VM_DISK="30GiB"

while getopts ":kv:c:m:d:h" opt; do
    case "$opt" in
        k) KEEP_VM=1 ;;
        v) VM_IMAGE="$OPTARG" ;;
        c) VM_CPU="$OPTARG" ;;
        m) VM_RAM="$OPTARG" ;;
        d) VM_DISK="$OPTARG" ;;
        h|*)
            sed -n '4,28p' "$0"; exit 0 ;;
    esac
done
shift $((OPTIND - 1))

RELEASES=("$@")
[ "${#RELEASES[@]}" -eq 0 ] && RELEASES=(quincy reef squid tentacle)

info() { printf '\033[1;34mINFO:\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; }
ok()   { printf '\033[1;32mOK:\033[0m %s\n' "$*"; }

# Pre-flight: tooling + built binaries.
command -v lxc >/dev/null || { err "lxc not in PATH (install lxd-client)"; exit 1; }
for f in "$PROJECT_ROOT/osdtrace" "$PROJECT_ROOT/radostrace"; do
    [ -x "$f" ] || { err "missing built binary $f — run 'make all' first"; exit 1; }
done


# run_one_release <release>
#
# Create a fresh ubuntu LXD VM, push the cephtrace binaries + the tests/
# directory, and invoke functional-test-cephadm-rgw.sh inside.
run_one_release() {
    local release="$1"
    local vm="cephadm-test-${release}"
    local logf="/tmp/cephadm-test-${release}.log"

    info "[${release}] step 1: provision LXD VM ${vm} (image=${VM_IMAGE} cpu=${VM_CPU} ram=${VM_RAM} disk=${VM_DISK})"

    if lxc info "$vm" >/dev/null 2>&1; then
        info "[${release}] existing VM found — deleting before fresh init"
        lxc delete --force "$vm" >/dev/null
    fi

    lxc init "$VM_IMAGE" "$vm" --vm \
        -c "limits.cpu=${VM_CPU}" \
        -c "limits.memory=${VM_RAM}" \
        -d "root,size=${VM_DISK}" >/dev/null
    lxc start "$vm"

    info "[${release}] step 2: wait for VM agent + cloud-init"
    local i ready=0
    for i in $(seq 1 60); do
        if lxc exec "$vm" -- true 2>/dev/null \
           && lxc exec "$vm" -- cloud-init status --wait >/dev/null 2>&1; then
            ready=1
            break
        fi
        sleep 5
    done
    if [ $ready -eq 0 ]; then
        err "[${release}] VM never became reachable"
        return 1
    fi

    info "[${release}] step 3: push binaries + tests/ tree"
    lxc exec "$vm" -- mkdir -p /root/cephtrace
    # `lxc file push` works for individual files; for the binary it preserves
    # mode and inode is fresh, avoiding the ETXTBSY trap if something on the
    # host happens to be holding the file open.  Use --mode=755 explicitly
    # so the test's `[ -x ]` check passes.
    lxc file push --mode=755 "$PROJECT_ROOT/osdtrace"   "$vm/root/cephtrace/osdtrace"
    lxc file push --mode=755 "$PROJECT_ROOT/radostrace" "$vm/root/cephtrace/radostrace"
    # tests/ is a small directory; tar-pipe in one shot.
    tar -C "$PROJECT_ROOT" -cf - tests \
        | lxc exec "$vm" -- tar -C /root/cephtrace -xf -

    info "[${release}] step 4: run functional-test-cephadm-rgw.sh inside VM"
    local rc=0
    # NB: ${PIPESTATUS[0]} captures lxc-exec's exit, not tee's.  Without this
    # a tee that returns 0 (always) would mask any test failure.
    set +e
    lxc exec "$vm" --env DEBIAN_FRONTEND=noninteractive \
                  --env "KEEP_CLUSTER=${KEEP_CLUSTER:-0}" -- bash -c "
        cd /root/cephtrace
        ./tests/functional-test-cephadm-rgw.sh '$release'
    " 2>&1 | tee "$logf"
    rc=${PIPESTATUS[0]}
    set -e

    if [ $rc -eq 0 ]; then
        ok "[${release}] PASSED  (log: $logf)"
        if [ $KEEP_VM -eq 0 ]; then
            info "[${release}] cleanup: delete VM ${vm}"
            lxc delete --force "$vm" >/dev/null
        else
            info "[${release}] VM ${vm} retained (-k flag): inspect with 'lxc exec ${vm} -- bash'"
        fi
        return 0
    else
        err "[${release}] FAILED (exit ${rc})"
        err "[${release}] VM ${vm} retained for inspection: 'lxc exec ${vm} -- bash'"
        err "[${release}] log: $logf"
        return $rc
    fi
}


# Run releases sequentially.  Parallel would crush a single host: each
# cluster uses 3 OSDs + MON + MGR + RGW + s3cmd, roughly 5–7 GiB RAM and
# 10 GiB disk inside its VM.
info "releases to run: ${RELEASES[*]}"
OVERALL_RC=0
FAILED=()
for r in "${RELEASES[@]}"; do
    if ! run_one_release "$r"; then
        OVERALL_RC=1
        FAILED+=("$r")
    fi
done

echo
if [ $OVERALL_RC -eq 0 ]; then
    ok "all releases passed: ${RELEASES[*]}"
else
    err "failed: ${FAILED[*]}"
    err "passed: $(comm -23 <(printf '%s\n' "${RELEASES[@]}" | sort) \
                          <(printf '%s\n' "${FAILED[@]}" | sort) | xargs)"
fi
exit $OVERALL_RC
