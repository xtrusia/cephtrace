#!/bin/bash
#
# Helpers for bootstrapping a single-host cephadm cluster with:
#   1 MON + 1 MGR (from --single-host-defaults)
#   3 OSDs       (loopback-backed devices, --all-available-devices)
#   1 radosgw    (cephadm orch service)
#
# Used by tests/functional-test-cephadm-rgw.sh as a matrix across the
# Quincy → Tentacle line.  All cephadm operations target the cephadm
# binary downloaded from the matching release branch; the cluster runs
# against the matching quay.io/ceph/ceph:vX.Y.Z image.

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=log.sh
source "$_LIB_DIR/log.sh"


# cephadm_image_for_release <release>
#
# Echo the latest tracked stable point-release image tag for a major Ceph
# release.  Bump these as upstream cuts new tags — the goal is "latest
# point release of the named major series" per the test matrix.
cephadm_image_for_release() {
    case "$1" in
        quincy)   echo "quay.io/ceph/ceph:v17.2.8"  ;;
        reef)     echo "quay.io/ceph/ceph:v18.2.7"  ;;
        squid)    echo "quay.io/ceph/ceph:v19.2.3"  ;;
        tentacle) echo "quay.io/ceph/ceph:v20.2.1"  ;;
        *) err "unknown release: $1"; return 1 ;;
    esac
}


# install_cephadm <release> <dest_path>
#
# Make a working `cephadm` available at $dest.  Strategy:
#   1. Try the distro-packaged cephadm (apt install on Ubuntu).  Ubuntu 24.04
#      ships squid-era cephadm, which can bootstrap any v17–v20 image via
#      `--image`.  This is the simplest and most reliable path.
#   2. Fall back to extracting cephadm from the matching quay.io image.
#      That guarantees the cephadm version matches the cluster image, which
#      matters for older releases (quincy, reef) where flag names differ.
#
# Why not "curl the script from github.com/ceph/ceph/<branch>"?
#   - Squid (and later) repackaged cephadm as a multi-file Python package
#     that imports `cephadmlib.*`; pulling just `src/cephadm/cephadm` from
#     GitHub fails at first import with ModuleNotFoundError.
#   - Quincy/Reef shipped a self-contained single-file script, so the
#     github-URL path worked, but the asymmetry is a footgun — drop it.
install_cephadm() {
    local release="$1"; local dest="${2:-/tmp/cephadm}"; local image="$3"

    # Path 1: distro package.
    if command -v cephadm >/dev/null; then
        cp "$(command -v cephadm)" "$dest"
        chmod +x "$dest"
        info "using distro cephadm: $(cephadm --version 2>&1 | head -1 | tr -d '\n')"
        return 0
    fi
    if apt-get install -y -q cephadm >/dev/null 2>&1; then
        cp "$(command -v cephadm)" "$dest"
        chmod +x "$dest"
        info "installed cephadm via apt: $(cephadm --version 2>&1 | head -1 | tr -d '\n')"
        return 0
    fi

    # Path 2: extract from the matching container image.  Every quay.io/ceph
    # image bundles /usr/sbin/cephadm; pulling that out yields a cephadm
    # whose bootstrap flag-set matches the image version exactly.
    [ -n "$image" ] || { err "no fallback image supplied to install_cephadm"; return 1; }
    info "extracting cephadm from $image (cold start ~1 min for image pull)"
    podman pull "$image" >/dev/null
    local cid; cid=$(podman create --rm "$image" /bin/true)
    podman cp "${cid}:/usr/sbin/cephadm" "$dest"
    podman rm -f "$cid" >/dev/null 2>&1 || true
    chmod +x "$dest"
    info "extracted cephadm from $image"
    return 0
}

# Backwards-compatible alias for tests still calling the old name.
download_cephadm() { install_cephadm "$@"; }


# provision_loopback_osds <count> <size_gib>
#
# Create N sparse files of size $size_gib GB under /var/lib/ceph-test-osds,
# attach each as /dev/loopXX, wrap each in its own LVM volume group, and
# emit one LV path per line.
#
# Why LVM wrap?  cephadm's `ceph orch device ls` filters out raw /dev/loopX
# from its inventory — `--all-available-devices` then sees nothing and no
# OSDs get created.  Wrapping in LVM presents each loop as a real block
# device path that cephadm's ceph-volume accepts.  One VG per loop keeps
# the layout symmetric (one OSD per VG) and lets us add `lvm zap` cleanup
# later if needed.
provision_loopback_osds() {
    local count="$1"; local size_gib="$2"
    mkdir -p /var/lib/ceph-test-osds
    local i lvs=()
    for ((i=0; i<count; i++)); do
        local img="/var/lib/ceph-test-osds/osd${i}.img"
        truncate -s "${size_gib}G" "$img"
        local dev
        dev=$(losetup --find --show --partscan "$img")
        wipefs -a "$dev" >/dev/null 2>&1 || true
        sgdisk --zap-all "$dev" >/dev/null 2>&1 || true
        local vg="ceph-test-vg${i}"
        pvcreate -ff -y "$dev" >&2
        vgcreate "$vg" "$dev" >&2
        lvcreate -y -l 100%FREE -n "osd-data" "$vg" >&2
        lvs+=("/dev/${vg}/osd-data")
    done
    printf '%s\n' "${lvs[@]}"
}


# cephadm_bootstrap_single_host <image> <mon_ip> [cephadm_bin]
#
# Bootstrap the cluster and echo the new FSID.  --single-host-defaults
# relaxes the no-single-host warnings; --skip-mon-network avoids requiring
# a real network range; --allow-overwrite lets the test be idempotent
# across retries on the same runner.
cephadm_bootstrap_single_host() {
    local image="$1"; local mon_ip="$2"; local cephadm_bin="${3:-/tmp/cephadm}"
    # --cluster-network is intentionally omitted: it requires a *network*
    # address (e.g. 10.0.0.0/24), not a host address, and the rejection
    # message is unhelpful ("has host bits set").  For a single-host cluster
    # the cluster network defaults to the mon network anyway, which is what
    # we want.
    # --allow-mismatched-release is required when the host's cephadm is
    # from a different Ceph release than the target image (e.g. Ubuntu
    # 24.04 ships squid-era cephadm, but we may want to bootstrap a reef
    # or quincy cluster).  cephadm refuses to proceed otherwise.
    # --no-cleanup-on-failure would let us inspect a partial bootstrap, but
    # it was added later in the quincy line and the apt-installed cephadm
    # on Ubuntu 22.04 rejects it.  CI doesn't need the inspection anyway —
    # the default (auto-cleanup on failed bootstrap) is what we want there.
    "$cephadm_bin" --image "$image" bootstrap \
        --mon-ip "$mon_ip" \
        --skip-mon-network \
        --skip-firewalld \
        --skip-dashboard \
        --single-host-defaults \
        --allow-overwrite \
        --allow-mismatched-release \
        >&2
    ls /var/lib/ceph/ 2>/dev/null | grep -E '^[0-9a-f]{8}-[0-9a-f-]+$' | head -1
}


# _ceph <fsid> <args...>
#
# Convenience wrapper to run a ceph CLI command inside the bootstrap
# container.  Each invocation spawns a fresh podman container, so use it
# for short queries — for long-running shells, use `cephadm shell --fsid X`
# directly.
_ceph() {
    local fsid="$1"; shift
    cephadm shell --fsid "$fsid" -- "$@"
}


# wait_cephadm_healthy <fsid> <timeout_seconds>
#
# Poll `ceph -s` until at least 1 MON in quorum, an active MGR, and
# `num_up_osds >= want_osds`.  We don't require HEALTH_OK because a fresh
# single-host cluster legitimately reports HEALTH_WARN about pool size
# defaults, mon insecure_global_id_reclaim, etc.
wait_cephadm_healthy() {
    local fsid="$1"; local want_osds="${2:-1}"; local timeout="${3:-600}"
    local deadline=$(( $(date +%s) + timeout ))
    while [[ $(date +%s) -lt $deadline ]]; do
        local s
        s=$(_ceph "$fsid" ceph -s --format=json 2>/dev/null) || true
        if [[ -n "$s" ]] && python3 -c "
import json, sys
try:
    d = json.loads('''$s''')
except Exception:
    sys.exit(2)
mon  = len(d.get('quorum_names', []))
# active_name is set only when the mgr CLI exposes per-name fields (older
# releases); squid+ just exposes available in the top-level mgrmap.
# Accept either signal as mgr-ready.  NOTE: this whole python block is
# embedded inside a bash double-quoted string, so do not use double
# quotes anywhere here -- they terminate the outer string and split the
# script into separate args, silently truncating the check.
mgrmap = d.get('mgrmap', {})
mgr  = mgrmap.get('active_name') or mgrmap.get('available')
ups  = d.get('osdmap', {}).get('num_up_osds', 0)
sys.exit(0 if mon >= 1 and mgr and ups >= int('$want_osds') else 1)
"; then
            info "cluster ready: ${want_osds}+ OSDs up"
            return 0
        fi
        sleep 5
    done
    err "cluster did not become ready within ${timeout}s"
    _ceph "$fsid" ceph -s 2>&1 | tail -20 || true
    return 1
}


# apply_rgw_service <fsid> <service_id> <port>
#
# Schedule a single radosgw daemon via cephadm orch.  Wait for the
# `radosgw --id rgw.<service_id>...` process to start on this host AND
# for the listening port to accept TCP, since orch reports "running" as
# soon as the container starts — before the radosgw socket is ready.
apply_rgw_service() {
    local fsid="$1"; local svc_id="${2:-test}"; local port="${3:-8080}"
    _ceph "$fsid" ceph orch apply rgw "$svc_id" \
        --placement="count:1" --port="$port" >&2
    local i
    # cephadm names the daemon 'rgw.<svc_id>.<host>.<random>' and runs it
    # via `-n client.rgw.<svc_id>.<host>.<random>` (NOT --id).  Match the
    # 'client.rgw.<svc_id>.' prefix so we catch the per-host suffix that
    # cephadm appends.
    for i in $(seq 1 90); do
        if pgrep -f "radosgw.*-n[[:space:]]+client\.rgw\.${svc_id}\." >/dev/null \
           && curl -fs --max-time 3 "http://localhost:${port}/" >/dev/null 2>&1; then
            info "radosgw ready on port $port"
            return 0
        fi
        sleep 5
    done
    err "radosgw did not come up within 450s"
    _ceph "$fsid" ceph orch ps 2>&1 | tail -10 || true
    return 1
}


# create_rgw_user <fsid> <uid> <access_key> <secret_key>
#
# Create an RGW user with deterministic keys (so the test doesn't need to
# parse the JSON response). Returns 0 on success.
create_rgw_user() {
    local fsid="$1"; local uid="$2"; local access="$3"; local secret="$4"
    _ceph "$fsid" radosgw-admin user create \
        --uid="$uid" --display-name="$uid" \
        --access-key="$access" --secret-key="$secret" \
        --format=json >/dev/null
}


# cleanup_cephadm_cluster <fsid>
#
# Tear down the cluster, detach loop devices, and remove backing files.
# Used by tests' EXIT trap.  Tolerant of partial-init state.
cleanup_cephadm_cluster() {
    local fsid="$1"
    [[ -n "$fsid" ]] && cephadm rm-cluster --fsid "$fsid" --force --zap-osds 2>/dev/null || true
    # Tear down the LVM stack we built in provision_loopback_osds before
    # detaching the loops — otherwise vgremove later complains about missing
    # PVs, and stale /dev/ceph-test-vgN entries clutter subsequent runs.
    local vg
    for vg in $(vgs --noheadings -o vg_name 2>/dev/null | awk '/^ *ceph-test-vg/{print $1}'); do
        vgremove -ff -y "$vg" >/dev/null 2>&1 || true
    done
    losetup -D 2>/dev/null || true
    rm -rf /var/lib/ceph-test-osds 2>/dev/null || true
}
