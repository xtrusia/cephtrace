#!/bin/bash
#
# Verifiers for `radostrace --list` and `osdtrace --list` output.
# Sourced by functional tests; follows the conventions of
# verify-trace-output.sh (xtrace silencing around per-row loops, row
# extraction helpers prefixed with _).

# Emit radostrace --list data rows, one per line:
#   pid|container|traceable|version|path
# Data rows start with a numeric PID and have exactly the 5 columns
# (PID, Container, Traceable, Ceph Version, Executable Path); the
# header, separator, and preamble lines all fail the predicate.
_radostrace_list_rows() {
    "$1" --list 2>/dev/null | awk '
        $1 ~ /^[0-9]+$/ && NF >= 5 {
            print $1 "|" $2 "|" $3 "|" $4 "|" $5
        }'
}

# Emit osdtrace --list data rows, one per line:
#   pid|osd_id|container|traceable|version
_osdtrace_list_rows() {
    "$1" --list 2>/dev/null | awk '
        $1 ~ /^[0-9]+$/ && NF >= 5 {
            print $1 "|" $2 "|" $3 "|" $4 "|" $5
        }'
}

# Strip an optional epoch ("2:19.2.4-0.el9" -> "19.2.4-0.el9") and return
# the major version number ("19").
_version_major() {
    echo "$1" | sed 's/^[0-9]*://' | cut -d. -f1
}

# verify_radostrace_list_multiclient <binary> <expected_major> \
#     <native_pid> <native_version>
#
# Asserts the --list output over a mixed-client host:
#   - containerized daemons (radosgw, ceph-mon, ceph-mgr) all report
#     Container=yes, Traceable=yes, and one uniform version whose major
#     matches expected_major
#   - the native client <native_pid> reports Container=no, Traceable=yes,
#     and exactly <native_version> (the host package version)
#   - no PID appears twice
#
# ceph-osd processes are deliberately NOT expected here: ceph-osd links
# the common code statically and maps no libceph-common.so.2, so it is
# not a librados client and never appears in radostrace --list (it is
# osdtrace --list's job, keyed on the ceph-osd binary's build-id).
verify_radostrace_list_multiclient() {
    local _xtrace=0
    case $- in *x*) _xtrace=1; set +x;; esac

    _verify_radostrace_list_multiclient_impl "$@"
    local rc=$?

    (( _xtrace == 1 )) && set -x
    return $rc
}

_verify_radostrace_list_multiclient_impl() {
    local binary=$1
    local expected_major=$2
    local native_pid=$3
    local native_version=$4

    local total=0 osd_rows=0 dup=0
    local saw_rgw=0 saw_mon=0 saw_mgr=0 saw_native=0
    local container_version=""
    local fail=0
    local pid container traceable version path base
    local -A seen_pid

    while IFS='|' read -r pid container traceable version path; do
        [ -z "$pid" ] && continue
        total=$((total + 1))

        if [ -n "${seen_pid[$pid]:-}" ]; then
            err "radostrace --list: PID $pid listed more than once"
            dup=$((dup + 1))
        fi
        seen_pid[$pid]=1

        base=${path##*/}

        if [ "$pid" = "$native_pid" ]; then
            saw_native=1
            if [ "$container" != "no" ]; then
                err "native client $pid ($base): Container=$container, expected no"
                fail=1
            fi
            if [ "$traceable" != "yes" ]; then
                err "native client $pid ($base): Traceable=$traceable, expected yes"
                fail=1
            fi
            if [ "$version" != "$native_version" ]; then
                err "native client $pid ($base): version '$version' != host package '$native_version'"
                fail=1
            fi
            continue
        fi

        # Containerized daemons we explicitly expect on a cephadm host.
        case "$base" in
            radosgw)  saw_rgw=1 ;;
            ceph-mon) saw_mon=1 ;;
            ceph-mgr) saw_mgr=1 ;;
            ceph-osd) osd_rows=$((osd_rows + 1)) ;;
            *) continue ;;  # crash agents etc. — presence not asserted
        esac

        if [ "$container" != "yes" ]; then
            err "containerized $base (pid $pid): Container=$container, expected yes"
            fail=1
        fi
        if [ "$traceable" != "yes" ]; then
            err "containerized $base (pid $pid): Traceable=$traceable, expected yes"
            fail=1
        fi
        if [ -z "$container_version" ]; then
            container_version=$version
        elif [ "$version" != "$container_version" ]; then
            err "containerized $base (pid $pid): version '$version' differs from '$container_version'"
            fail=1
        fi
    done < <(_radostrace_list_rows "$binary")

    info "radostrace --list: total=$total rgw=$saw_rgw mon=$saw_mon mgr=$saw_mgr" \
         "osd_rows=$osd_rows native=$saw_native container_version=${container_version:-none}"

    [ "$saw_rgw" -eq 1 ]  || { err "radostrace --list: no radosgw row";  fail=1; }
    [ "$saw_mon" -eq 1 ]  || { err "radostrace --list: no ceph-mon row"; fail=1; }
    [ "$saw_mgr" -eq 1 ]  || { err "radostrace --list: no ceph-mgr row"; fail=1; }
    [ "$saw_native" -eq 1 ] || { err "radostrace --list: native client pid $native_pid missing"; fail=1; }
    [ "$dup" -eq 0 ] || fail=1
    # ceph-osd statically links the common code (no libceph-common.so.2 in
    # its maps), so it must NOT be listed as a librados client.
    if [ "$osd_rows" -ne 0 ]; then
        err "radostrace --list: $osd_rows ceph-osd rows; OSDs are not librados clients"
        fail=1
    fi
    if [ -n "$container_version" ] && \
       [ "$(_version_major "$container_version")" != "$expected_major" ]; then
        err "radostrace --list: container version '$container_version' major != $expected_major"
        fail=1
    fi

    if [ "$fail" -ne 0 ]; then
        "$binary" --list 2>&1 || true
        return 1
    fi
    info "✓ radostrace --list multi-client output verified"
    return 0
}

# verify_osdtrace_list_multiosd <binary> <expected_major> <expected_osd_count>
#
# Asserts the --list output on a host whose OSDs are all containerized:
#   - the listed PID set equals the live ceph-osd PID set (pgrep -x)
#   - exactly <expected_osd_count> rows with distinct OSD IDs
#   - every row: Container=yes, Traceable=yes, one uniform version whose
#     major matches expected_major
verify_osdtrace_list_multiosd() {
    local _xtrace=0
    case $- in *x*) _xtrace=1; set +x;; esac

    _verify_osdtrace_list_multiosd_impl "$@"
    local rc=$?

    (( _xtrace == 1 )) && set -x
    return $rc
}

_verify_osdtrace_list_multiosd_impl() {
    local binary=$1
    local expected_major=$2
    local expected_count=$3

    local total=0 fail=0
    local pid osd_id container traceable version
    local container_version=""
    local -A seen_pid seen_id

    while IFS='|' read -r pid osd_id container traceable version; do
        [ -z "$pid" ] && continue
        total=$((total + 1))

        if [ -n "${seen_pid[$pid]:-}" ]; then
            err "osdtrace --list: PID $pid listed more than once"
            fail=1
        fi
        seen_pid[$pid]=1
        if [ -n "${seen_id[$osd_id]:-}" ]; then
            err "osdtrace --list: OSD ID $osd_id listed more than once"
            fail=1
        fi
        seen_id[$osd_id]=1

        if ! kill -0 "$pid" 2>/dev/null; then
            err "osdtrace --list: PID $pid (osd.$osd_id) is not a live process"
            fail=1
        fi
        if [ "$container" != "yes" ]; then
            err "osdtrace --list: osd.$osd_id (pid $pid): Container=$container, expected yes"
            fail=1
        fi
        if [ "$traceable" != "yes" ]; then
            err "osdtrace --list: osd.$osd_id (pid $pid): Traceable=$traceable, expected yes"
            fail=1
        fi
        if [ -z "$container_version" ]; then
            container_version=$version
        elif [ "$version" != "$container_version" ]; then
            err "osdtrace --list: osd.$osd_id (pid $pid): version '$version' differs from '$container_version'"
            fail=1
        fi
    done < <(_osdtrace_list_rows "$binary")

    info "osdtrace --list: total=$total expected=$expected_count" \
         "container_version=${container_version:-none}"

    if [ "$total" -ne "$expected_count" ]; then
        err "osdtrace --list: $total rows, expected exactly $expected_count"
        fail=1
    fi

    # Every live ceph-osd process must be listed (comm is exactly
    # "ceph-osd", 8 chars, so -x is safe here).
    local live
    for live in $(pgrep -x ceph-osd 2>/dev/null); do
        if [ -z "${seen_pid[$live]:-}" ]; then
            err "osdtrace --list: live ceph-osd PID $live not listed"
            fail=1
        fi
    done

    if [ -n "$container_version" ] && \
       [ "$(_version_major "$container_version")" != "$expected_major" ]; then
        err "osdtrace --list: container version '$container_version' major != $expected_major"
        fail=1
    fi

    if [ "$fail" -ne 0 ]; then
        "$binary" --list 2>&1 || true
        return 1
    fi
    info "✓ osdtrace --list multi-OSD output verified"
    return 0
}

# ---------------------------------------------------------------------------
# MicroCeph (snap) variants.
#
# MicroCeph runs every daemon snap-confined: each process lives in the snap's
# own mount namespace with its libraries under /snap/microceph/<rev>/...,
# which is a different resolution path than podman/docker containers.  These
# verifiers assert what --list must get right for that snap path:
#   - Container = yes               (the snap mount ns differs from the host's)
#   - Traceable != "unknown"        ("unknown" means the ELF build-id could not
#                                     be read through /proc/<pid>/root, i.e. the
#                                     snap-namespace resolution failed - the bug
#                                     these guard)
#   - version exact-match only when Traceable=yes, so a MicroCeph release that
#     has moved ahead of the embedded DWARF set (Traceable=no) does not make
#     the test flaky.
# ---------------------------------------------------------------------------

# verify_osdtrace_list_microceph <binary> <expected_count> <expected_version>
verify_osdtrace_list_microceph() {
    local _xtrace=0
    case $- in *x*) _xtrace=1; set +x;; esac
    _verify_osdtrace_list_microceph_impl "$@"
    local rc=$?
    (( _xtrace == 1 )) && set -x
    return $rc
}

_verify_osdtrace_list_microceph_impl() {
    local binary=$1 expected_count=$2 expected_version=$3
    local total=0 fail=0
    local pid osd_id container traceable version
    local -A seen_pid seen_id

    while IFS='|' read -r pid osd_id container traceable version; do
        [ -z "$pid" ] && continue
        total=$((total + 1))

        [ -z "${seen_pid[$pid]:-}" ] || {
            err "osdtrace --list: PID $pid listed more than once"; fail=1; }
        seen_pid[$pid]=1
        [ -z "${seen_id[$osd_id]:-}" ] || {
            err "osdtrace --list: OSD ID $osd_id listed more than once"; fail=1; }
        seen_id[$osd_id]=1

        kill -0 "$pid" 2>/dev/null || {
            err "osdtrace --list: PID $pid (osd.$osd_id) not a live process"
            fail=1; }
        [ "$container" = "yes" ] || {
            err "osdtrace --list: osd.$osd_id (pid $pid) Container=$container, expected yes (snap)"
            fail=1; }
        [ "$traceable" != "unknown" ] || {
            err "osdtrace --list: osd.$osd_id (pid $pid) Traceable=unknown - build-id read through the snap namespace failed"
            fail=1; }
        if [ "$traceable" = "yes" ] && [ "$version" != "$expected_version" ]; then
            err "osdtrace --list: osd.$osd_id traceable but version '$version' != '$expected_version'"
            fail=1
        fi
    done < <(_osdtrace_list_rows "$binary")

    info "osdtrace --list (microceph): total=$total expected=$expected_count"

    [ "$total" -eq "$expected_count" ] || {
        err "osdtrace --list: $total rows, expected $expected_count"; fail=1; }

    local live
    for live in $(pgrep -x ceph-osd 2>/dev/null); do
        [ -n "${seen_pid[$live]:-}" ] || {
            err "osdtrace --list: live ceph-osd PID $live not listed"; fail=1; }
    done

    if [ "$fail" -ne 0 ]; then
        "$binary" --list 2>&1 || true
        return 1
    fi
    info "✓ osdtrace --list (microceph) verified"
    return 0
}

# verify_radostrace_list_microceph <binary> <client_pid> <expected_version>
#
# Asserts the snap-confined librados client <client_pid> (an rbd process) is
# discovered, and that --list also surfaces the snap ceph daemons (mon/mgr/
# mds), proving daemon discovery - not just the bench client.
verify_radostrace_list_microceph() {
    local _xtrace=0
    case $- in *x*) _xtrace=1; set +x;; esac
    _verify_radostrace_list_microceph_impl "$@"
    local rc=$?
    (( _xtrace == 1 )) && set -x
    return $rc
}

_verify_radostrace_list_microceph_impl() {
    local binary=$1 client_pid=$2 expected_version=$3
    local total=0 fail=0 saw_client=0 saw_daemon=0
    local pid container traceable version path base
    local -A seen_pid

    while IFS='|' read -r pid container traceable version path; do
        [ -z "$pid" ] && continue
        total=$((total + 1))
        [ -z "${seen_pid[$pid]:-}" ] || {
            err "radostrace --list: PID $pid listed more than once"; fail=1; }
        seen_pid[$pid]=1
        base=${path##*/}

        if [ "$pid" = "$client_pid" ]; then
            saw_client=1
            [ "$container" = "yes" ] || {
                err "rbd client $pid: Container=$container, expected yes (snap)"
                fail=1; }
            case "$path" in
                /snap/*) ;;
                *) err "rbd client $pid: path '$path' not under /snap (snap lib resolution?)"
                   fail=1;;
            esac
            [ "$traceable" != "unknown" ] || {
                err "rbd client $pid: Traceable=unknown - snap-namespace build-id read failed"
                fail=1; }
            if [ "$traceable" = "yes" ] && [ "$version" != "$expected_version" ]; then
                err "rbd client $pid: traceable but version '$version' != '$expected_version'"
                fail=1
            fi
        fi
        case "$base" in
            ceph-mon|ceph-mgr|ceph-mds) saw_daemon=1 ;;
        esac
    done < <(_radostrace_list_rows "$binary")

    info "radostrace --list (microceph): total=$total client=$saw_client daemons=$saw_daemon"

    [ "$saw_client" -eq 1 ] || {
        err "radostrace --list: snap rbd client pid $client_pid not listed"; fail=1; }
    [ "$saw_daemon" -eq 1 ] || {
        err "radostrace --list: no snap ceph-mon/mgr/mds daemon listed"; fail=1; }

    if [ "$fail" -ne 0 ]; then
        "$binary" --list 2>&1 || true
        return 1
    fi
    info "✓ radostrace --list (microceph) verified"
    return 0
}
