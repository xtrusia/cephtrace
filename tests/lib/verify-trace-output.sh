#!/bin/bash
#
# Generic verifiers for the textual output produced by osdtrace and radostrace.
# Sourced by:
#   - tests/functional-test-microceph.sh
#   - tests/functional-test-embedded-dwarf.sh
#
# Design
# ------
# Each verifier reads its log once and parses every data row into a bash
# associative array (the per-row "dict") whose keys are named field names
# (pid, client, tid, pool, pg, acting, wr, size, latency, object, …).  All
# field-level checks then read named keys from that dict — `${row[size]}`,
# `${row[wr]}` — instead of positional awk fields.  Aggregate checks
# (row count, W/R diversity, size anchor) run after the row loop.
#
# Each verifier returns non-zero on the first failure; the caller's `set -e`
# stops the test.  Both rely on info()/err() from tests/lib/log.sh, which
# the caller is expected to have sourced already.

# Upper bound on per-op latency (µs).  Anything bigger than 100 s almost
# certainly means a timestamp went backwards or the units field is broken.
TRACE_MAX_LATENCY_US=100000000

# rbd bench --io-size used by the functional tests' workload (4 MiB).  At
# least one radostrace row must report this exact length — anchors the size
# field to a known constant from the workload, which catches
# endianness/unit/cast regressions in the BPF length extraction.
TRACE_RBD_BENCH_IO_SIZE=4194304


# _osdtrace_rows <log>
#
# Stream pipe-separated osdtrace data rows to stdout, one per line:
#   osd_id|pool|pg_hex|op|latency
# Filters out the header/status/truncated lines and the `[delayed…]`
# continuation lines.  Latency is forced numeric via `$NF + 0` so a
# truncated mid-print row (whose last field becomes a non-numeric fragment
# like "s" from a half-emitted "seq_wait") doesn't poison the downstream
# bash arithmetic comparison.
_osdtrace_rows() {
    awk '
        $1 == "osd" && $3 == "pg" && \
        $2 ~ /^-?[0-9]+$/ && \
        $4 ~ /^[0-9]+\.[0-9a-fA-F]+$/ {
            split($4, pg, ".")
            # $5 is the op type: op_r / op_w / subop_w.  Useful context for
            # error messages even though no check currently keys off it.
            print $2 "|" pg[1] "|" pg[2] "|" $5 "|" ($NF + 0)
        }
    ' "$1"
}


# _radostrace_rows <log>
#
# Stream pipe-separated radostrace data rows to stdout, one per line:
#   pid|client|tid|pool|pg|acting|wr|size|latency|object
# Data rows start with a numeric PID (the traced process's PID).  Filter
# `$1 ~ /^[0-9]+$/ && NF >= 9` rejects the header line ("pid client … "),
# status messages, and tool-emitted log noise.  $10 may be missing on a
# malformed row — emitted as the empty string so the downstream regex
# check fails loudly rather than silently skipping.
_radostrace_rows() {
    awk '
        $1 ~ /^[0-9]+$/ && NF >= 9 {
            obj = (NF >= 10) ? $10 : ""
            print $1 "|" $2 "|" $3 "|" $4 "|" $5 "|" $6 "|" $7 "|" \
                  ($8 + 0) "|" ($9 + 0) "|" obj
        }
    ' "$1"
}


# verify_osdtrace_output <log> <test_pool_id> <max_osd_id> <pg_num> <min_rows>
verify_osdtrace_output() {
    local log=$1
    local test_pool_id=$2
    local max_osd_id=$3
    local pg_num=$4
    local min_rows=$5

    local pool_rows=0
    local -A row
    local osd_id pool pg_hex op latency
    local pg_dec

    while IFS='|' read -r osd_id pool pg_hex op latency; do
        [ -z "$osd_id" ] && continue

        # Per-row dict.  All subsequent checks read fields by name.
        row=(
            [osd_id]="$osd_id"
            [pool]="$pool"
            [pg]="$pg_hex"
            [op]="$op"
            [latency]="$latency"
        )

        # 1. OSD id within cluster range (global invariant — any pool).
        if (( row[osd_id] < 0 || row[osd_id] > max_osd_id )); then
            err "Found OSD id ${row[osd_id]} outside expected range [0, $max_osd_id] (op=${row[op]} pool=${row[pool]})"
            return 1
        fi

        # 2. Latency upper bound (global invariant — any pool).
        if (( row[latency] > TRACE_MAX_LATENCY_US )); then
            err "Found latency ${row[latency]} µs > $TRACE_MAX_LATENCY_US µs in osdtrace output (osd=${row[osd_id]} op=${row[op]} pool=${row[pool]})"
            return 1
        fi

        # Per-pool checks: only test_pool rows.  osdtrace also captures
        # internal MicroCeph traffic (.mgr/.osd metadata pools); we don't
        # want to validate PG ranges against those pools' pg_num.
        if [ "${row[pool]}" = "$test_pool_id" ]; then
            pool_rows=$((pool_rows + 1))

            # 3. PG index within pg_num.  osdtrace prints PG in hex
            #    (std::hex on op.pg.m_seed) without an `0x` prefix, so plain
            #    decimal parsing would silently accept any hex letters as 0.
            #    Convert with bash's `$((16#…))`.
            pg_dec=$((16#${row[pg]}))
            if (( pg_dec < 0 || pg_dec >= pg_num )); then
                err "Found PG ${row[pg]} (decimal $pg_dec) outside expected range [0, $pg_num) in osdtrace output"
                return 1
            fi
        fi
    done < <(_osdtrace_rows "$log")

    # 4. Aggregate: enough rows for test_pool specifically.  Counting only
    #    test_pool rows is what proves the rbd-bench traffic reached the BPF
    #    program — not just internal-pool noise.
    info "osdtrace captured $pool_rows trace rows for test_pool (pool id $test_pool_id)"
    if (( pool_rows < min_rows )); then
        err "osdtrace did not capture enough trace data for test_pool (expected >= $min_rows rows, got $pool_rows)"
        return 1
    fi

    info "✓ All osdtrace output fields validated successfully"
}


# verify_radostrace_output <log> <test_pool_id> <max_osd_id> <min_rows>
#
# All invariants below are anchored to the rbd-bench PID radostrace is
# attached to.  The rados put/get/rm calls in the workload are *separate*
# processes and never appear in radostrace output — so the W+R diversity
# check requires the bench workload to be `--io-type readwrite`.
verify_radostrace_output() {
    local log=$1
    local test_pool_id=$2
    local max_osd_id=$3
    local min_rows=$4

    local total=0
    local saw_w=0 saw_r=0 saw_bench_size=0
    local -A row
    local pid client tid pool pg acting wr size latency object
    local acting_inner osd_id_str osd_id

    while IFS='|' read -r pid client tid pool pg acting wr size latency object; do
        [ -z "$pid" ] && continue

        # Per-row dict.  All subsequent checks read fields by name.
        row=(
            [pid]="$pid"
            [client]="$client"
            [tid]="$tid"
            [pool]="$pool"
            [pg]="$pg"
            [acting]="$acting"
            [wr]="$wr"
            [size]="$size"
            [latency]="$latency"
            [object]="$object"
        )
        total=$((total + 1))

        # 1. Pool id matches test_pool.
        if [ "${row[pool]}" != "$test_pool_id" ]; then
            err "Unexpected pool id ${row[pool]} in radostrace output (expected $test_pool_id, tid=${row[tid]})"
            return 1
        fi

        # 2. WR flag is W or R.  Tracking diversity in the same step so we
        #    don't re-traverse the rows after the loop.
        case "${row[wr]}" in
            W) saw_w=1 ;;
            R) saw_r=1 ;;
            *) err "Invalid WR flag '${row[wr]}' in radostrace output (expected W or R, tid=${row[tid]})"
               return 1 ;;
        esac

        # 3. Acting-set OSD ids within 0..max_osd_id.  Acting is a
        #    comma-separated list inside square brackets, e.g. "[1,0,2]".
        acting_inner=${row[acting]#\[}
        acting_inner=${acting_inner%\]}
        local IFS_save=$IFS
        IFS=','
        # shellcheck disable=SC2086  # intentional word-split on commas
        for osd_id_str in $acting_inner; do
            osd_id=$((osd_id_str))
            if (( osd_id < 0 || osd_id > max_osd_id )); then
                IFS=$IFS_save
                err "OSD id $osd_id in acting set ${row[acting]} outside valid range [0, $max_osd_id] (tid=${row[tid]})"
                return 1
            fi
        done
        IFS=$IFS_save

        # 4. Latency in bounds: > 0 µs (catches a missing finish_stamp in
        #    the BPF program) and <= upper bound (catches runaway
        #    timestamps).  Latency was numeric-coerced in _radostrace_rows.
        if (( row[latency] == 0 )); then
            err "radostrace row has zero latency (suspect measurement bug): pid=${row[pid]} tid=${row[tid]} object=${row[object]} wr=${row[wr]}"
            return 1
        fi
        if (( row[latency] > TRACE_MAX_LATENCY_US )); then
            err "Found latency ${row[latency]} µs > $TRACE_MAX_LATENCY_US µs in radostrace output (tid=${row[tid]})"
            return 1
        fi

        # 5. Object name matches the workload's expected prefixes.  Catches
        #    garbled object-name extraction in the BPF helper.  Empty
        #    object (NF < 10 in the raw log) is rejected by the same regex
        #    since it matches neither branch.
        if [[ ! "${row[object]}" =~ ^(rbd_|testobj$) ]]; then
            err "Unexpected object name '${row[object]}' in radostrace output (expected rbd_* or testobj, tid=${row[tid]} wr=${row[wr]})"
            return 1
        fi

        # 6. Track whether any row hit the rbd-bench --io-size (4 MiB).
        #    Confirms the size field carries the workload's known constant.
        if (( row[size] == TRACE_RBD_BENCH_IO_SIZE )); then
            saw_bench_size=1
        fi
    done < <(_radostrace_rows "$log")

    # 7. Aggregate: row count.
    info "radostrace captured $total trace rows"
    if (( total < min_rows )); then
        err "radostrace did not capture enough data (expected >= $min_rows rows, got $total)"
        return 1
    fi

    # 8. Both W and R must appear — workload (rbd bench --io-type readwrite)
    #    issues both directions.  Catches regressions where one direction is
    #    silently dropped (e.g. a uretprobe missing on the read path).
    if (( saw_w == 0 )); then
        err "radostrace output has no 'W' rows but workload issued writes"
        return 1
    fi
    if (( saw_r == 0 )); then
        err "radostrace output has no 'R' rows but workload issued reads"
        return 1
    fi

    # 9. At least one row reported the rbd-bench --io-size (4 MiB).  Anchors
    #    the size field to a known workload constant.
    if (( saw_bench_size == 0 )); then
        err "radostrace output has no row with size=$TRACE_RBD_BENCH_IO_SIZE (rbd bench --io-size)"
        return 1
    fi

    info "✓ All radostrace output fields validated successfully"
}
