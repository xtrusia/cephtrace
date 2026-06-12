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
