#!/bin/bash

# Comprehensive check for why events aren't appearing
# Usage: sudo ./check_real_issue.sh <pid> <dwarf_json>

if [ "$EUID" -ne 0 ]; then
    echo "Error: Must run as root"
    exit 1
fi

PID=$1
DWARF_JSON=$2

if [ -z "$PID" ] || [ -z "$DWARF_JSON" ]; then
    echo "Usage: $0 <pid> <dwarf_json>"
    exit 1
fi

echo "=========================================="
echo "Comprehensive Event Debugging"
echo "=========================================="
echo "PID: $PID"
echo "DWARF JSON: $DWARF_JSON"
echo

# 1. Check if process exists
if [ ! -d "/proc/$PID" ]; then
    echo "❌ ERROR: Process $PID does not exist"
    exit 1
fi
echo "✓ Process exists"

# 2. Check DWARF JSON content
echo
echo "Checking DWARF JSON content..."
if [ ! -f "$DWARF_JSON" ]; then
    echo "❌ ERROR: DWARF JSON file not found"
    exit 1
fi

# Check for key functions
for func in "OSD::dequeue_op" "OSD::enqueue_op" "PrimaryLogPG::log_op_stats"; do
    if grep -q "$func" "$DWARF_JSON"; then
        OFFSET=$(grep -A 10 "$func" "$DWARF_JSON" | grep -o '"offset"[^,]*' | head -1)
        if [ ! -z "$OFFSET" ]; then
            echo "  ✓ Found $func: $OFFSET"
        else
            echo "  ⚠ Found $func but no offset"
        fi
    else
        echo "  ✗ $func not found in JSON"
    fi
done

# 3. Clear and check trace
echo
echo "Clearing trace buffer..."
echo > /sys/kernel/debug/tracing/trace 2>/dev/null
echo 1 > /sys/kernel/debug/tracing/tracing_on 2>/dev/null
echo "✓ Trace buffer cleared"

# 4. Check current uprobes
echo
echo "Current uprobe events:"
UPROBE_COUNT=$(wc -l < /sys/kernel/debug/tracing/uprobe_events 2>/dev/null)
echo "Total registered: $UPROBE_COUNT"

if [ $UPROBE_COUNT -gt 0 ]; then
    echo "Sample (last 5):"
    tail -5 /sys/kernel/debug/tracing/uprobe_events
fi

# 5. Get binary path
BINARY=$(cat /proc/$PID/maps | grep 'r-xp' | grep -E 'ceph-osd' | head -1 | awk '{print $NF}')
echo
echo "Binary: $BINARY"

# 6. Check if OSD is active
echo
echo "Checking OSD activity..."
CMDLINE=$(cat /proc/$PID/cmdline | tr '\0' ' ')
OSD_ID=$(echo "$CMDLINE" | grep -oP '(?<=--id )\d+' || echo "$CMDLINE" | grep -oP 'osd\.\K\d+')

if [ ! -z "$OSD_ID" ]; then
    echo "OSD ID: $OSD_ID"
    
    if command -v ceph &> /dev/null; then
        # Check OSD status
        OSD_STATUS=$(ceph osd tree 2>/dev/null | grep "osd.$OSD_ID" || echo "unknown")
        echo "OSD Status: $OSD_STATUS"
        
        # Check current operations
        OSD_OPS=$(ceph tell osd.$OSD_ID perf dump 2>/dev/null | grep -E '"op":|"op_w":|"op_r":' | head -3)
        if [ ! -z "$OSD_OPS" ]; then
            echo "Current ops:"
            echo "$OSD_OPS"
        fi
    fi
else
    echo "⚠ Could not determine OSD ID"
fi

# 7. Manual uprobe test
echo
echo "Testing manual uprobe..."
TEST_NAME="test_manual_$$"
echo "-:$TEST_NAME" > /sys/kernel/debug/tracing/uprobe_events 2>/dev/null

# Try offset 0x1000
if [ ! -z "$BINARY" ]; then
    echo "p:$TEST_NAME $BINARY:0x1000" > /sys/kernel/debug/tracing/uprobe_events 2>&1
    
    if [ $? -eq 0 ]; then
        echo "✓ Manual uprobe created"
        echo 1 > /sys/kernel/debug/tracing/events/uprobes/$TEST_NAME/enable 2>/dev/null
        sleep 1
        
        # Check if it appears in trace
        if grep -q "$TEST_NAME" /sys/kernel/debug/tracing/trace 2>/dev/null; then
            echo "✓ Manual uprobe is triggering!"
        else
            echo "⚠ Manual uprobe not triggering (normal for offset 0x1000)"
        fi
        
        echo 0 > /sys/kernel/debug/tracing/events/uprobes/$TEST_NAME/enable 2>/dev/null
        echo "-:$TEST_NAME" > /sys/kernel/debug/tracing/uprobe_events 2>/dev/null
    else
        echo "✗ Failed to create manual uprobe"
        echo "Error:"
        dmesg | tail -3
    fi
fi

# 8. Check BPF programs
echo
echo "Checking loaded BPF programs..."
if command -v bpftool &> /dev/null; then
    BPF_COUNT=$(bpftool prog list | grep -c uprobe || echo 0)
    echo "BPF uprobe programs loaded: $BPF_COUNT"
    if [ $BPF_COUNT -gt 0 ]; then
        echo "Sample:"
        bpftool prog list | grep -A 2 uprobe | head -6
    fi
else
    echo "Install bpftool: sudo apt-get install linux-tools-$(uname -r)"
fi

# 9. Test I/O path
echo
echo "=========================================="
echo "NEXT STEPS:"
echo "=========================================="
echo
echo "1. In Terminal 1, monitor trace_pipe:"
echo "   sudo cat /sys/kernel/debug/tracing/trace_pipe | grep -E 'uprobe|Entered'"
echo
echo "2. In Terminal 2, run osdtrace:"
echo "   sudo ./osdtrace -p $PID -i $DWARF_JSON -x --skip-version-check"
echo
echo "3. In Terminal 3, generate I/O:"
echo "   rados bench -p test 10 write --no-cleanup"
echo
echo "4. Check Terminal 1 for output:"
echo "   - If you see 'Entered into uprobe_*': BPF code is running!"
echo "   - If you see nothing: uprobe is not triggering"
echo
echo "If trace_pipe shows BPF messages but no events in osdtrace:"
echo "  → Problem is in BPF logic (filtering, map operations, etc.)"
echo
echo "If trace_pipe shows nothing:"
echo "  → Uprobe is not triggering (wrong offset or function not called)"
echo

