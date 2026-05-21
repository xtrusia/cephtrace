#!/bin/bash

# Shared helpers for tests that need a single-node MicroCeph cluster.
# Source from a test script: source "$SCRIPT_DIR/lib/microceph-setup.sh"

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=log.sh
source "$_LIB_DIR/log.sh"

# Install MicroCeph snap (if missing), bootstrap a single-node cluster,
# add loop-backed OSDs (if fewer than requested), and wait until the
# cluster reports HEALTH_OK or HEALTH_WARN.
#
# Args:
#   $1  osd_count           number of OSDs to ensure (default 3)
#   $2  osd_size            per-OSD size as accepted by `microceph disk add` (default 1G)
#   $3  health_timeout_sec  max seconds to wait for healthy state (default 120)
#
# Returns 0 on healthy cluster, 1 on health-wait timeout.
microceph_setup_single_node() {
    local osd_count="${1:-3}"
    local osd_size="${2:-1G}"
    local health_timeout="${3:-120}"

    if ! snap list 2>/dev/null | grep -q microceph; then
        info "Installing MicroCeph snap..."
        snap install microceph
        snap refresh --hold microceph
    else
        info "MicroCeph snap already installed"
    fi

    if ! microceph cluster list 2>/dev/null | grep -q "$(hostname)"; then
        info "Bootstrapping MicroCeph cluster..."
        microceph cluster bootstrap
    else
        info "MicroCeph cluster already bootstrapped"
    fi

    local current_osds
    current_osds=$(microceph.ceph osd stat | grep -oP '\d+(?= osds:)' || echo "0")
    if [ "$current_osds" -lt "$osd_count" ]; then
        info "Adding $osd_count loop-backed OSDs (${osd_size} each)..."
        microceph disk add "loop,${osd_size},${osd_count}"
    else
        info "Already have $current_osds OSDs (target $osd_count)"
    fi

    info "Waiting for cluster to be healthy (timeout ${health_timeout}s)..."
    local elapsed=0
    while [ "$elapsed" -lt "$health_timeout" ]; do
        if microceph.ceph status 2>/dev/null | grep -q "HEALTH_OK\|HEALTH_WARN"; then
            info "Cluster is ready (${elapsed}s)"
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done
    err "Cluster did not become healthy within ${health_timeout}s"
    return 1
}

# Expose microceph's cluster to host-side librados clients (fio's rbd engine,
# any other ceph-aware tool running outside snap confinement) by writing
# /etc/ceph/{ceph.conf,ceph.client.admin.keyring} derived from the snap's
# internal conf.  Also disables librbd client-side cache so reads always
# reach RADOS — needed for radostrace to see read-path ops through Objecter.
microceph_setup_client_conf() {
    local snap_conf=/var/snap/microceph/current/conf/ceph.conf
    local snap_keyring=/var/snap/microceph/current/conf/ceph.keyring
    local etc_conf=/etc/ceph/ceph.conf
    local etc_keyring=/etc/ceph/ceph.client.admin.keyring

    if [ ! -r "$snap_conf" ] || [ ! -r "$snap_keyring" ]; then
        err "microceph conf/keyring not readable: $snap_conf / $snap_keyring"
        return 1
    fi

    info "Setting up $etc_conf and $etc_keyring for host-side librados..."
    mkdir -p /etc/ceph
    cp "$snap_conf" "$etc_conf"
    cp "$snap_keyring" "$etc_keyring"
    chmod 0644 "$etc_keyring"

    # The snap's conf points its `keyring =` line at the snap-internal path;
    # rewrite to the standard /etc/ceph/ path so the conf is self-contained
    # (and works even if the snap directory layout changes).
    sed -i "s|$snap_keyring|$etc_keyring|g" "$etc_conf"

    # Disable librbd client-side cache.  Without this, recently-written data
    # is satisfied from the local cache, so radostrace sees only the write
    # path and zero reads (Objecter is bypassed).
    if ! grep -q "^[[:space:]]*\[client\]" "$etc_conf"; then
        printf '\n[client]\n' >> "$etc_conf"
    fi
    if ! grep -q "^[[:space:]]*rbd_cache" "$etc_conf"; then
        sed -i '/^\[client\]/a rbd_cache = false' "$etc_conf"
    fi
}
