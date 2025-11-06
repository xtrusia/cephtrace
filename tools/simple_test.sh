#!/bin/bash

# Simple test to verify basic uprobe functionality
# Usage: sudo ./simple_test.sh <pid>

if [ "$EUID" -ne 0 ]; then
    echo "Error: Must run as root"
    exit 1
fi

PID=$1

if [ -z "$PID" ]; then
    echo "Usage: $0 <pid>"
    exit 1
fi

echo "=========================================="
echo "Simple Uprobe Test for PID $PID"
echo "=========================================="
echo

# 1. Check process
if [ ! -d "/proc/$PID" ]; then
    echo "ERROR: Process $PID does not exist"
    exit 1
fi

CMDLINE=$(cat /proc/$PID/cmdline | tr '\0' ' ')
echo "Process: $CMDLINE"
echo

# 2. Find binary
BINARY=$(cat /proc/$PID/maps | grep 'r-xp' | grep -E '(ceph-osd|librados)' | head -1 | awk '{print $NF}')
echo "Binary: $BINARY"
echo

if [ ! -f "$BINARY" ]; then
    echo "ERROR: Cannot access binary"
    exit 1
fi

# 3. Get base address
BASE_ADDR=$(cat /proc/$PID/maps | grep -m1 'r-xp' | awk '{print $1}' | cut -d'-' -f1)
echo "Base address: 0x$BASE_ADDR"
echo

# 4. Try different test offsets
echo "Testing uprobe at different offsets..."
echo

# Clear trace
echo > /sys/kernel/debug/tracing/trace 2>/dev/null

# Test offset 1: 0x1000 (always safe)
TEST_NAME="test_simple_1000"
echo "-:$TEST_NAME" > /sys/kernel/debug/tracing/uprobe_events 2>/dev/null
echo "p:$TEST_NAME $BINARY:0x1000" > /sys/kernel/debug/tracing/uprobe_events 2>&1
if [ $? -eq 0 ]; then
    echo "✓ Uprobe created at offset 0x1000"
    echo 1 > /sys/kernel/debug/tracing/events/uprobes/$TEST_NAME/enable 2>/dev/null
    
    # Wait a bit
    sleep 2
    
    # Check if triggered
    COUNT=$(grep "$TEST_NAME" /sys/kernel/debug/tracing/trace 2>/dev/null | wc -l)
    echo "  Trigger count: $COUNT"
    
    if [ $COUNT -gt 0 ]; then
        echo "  ✓ Uprobe is working!"
        grep "$TEST_NAME" /sys/kernel/debug/tracing/trace 2>/dev/null | head -3
    else
        echo "  Note: Not triggered yet (this is normal for offset 0x1000)"
    fi
    
    echo 0 > /sys/kernel/debug/tracing/events/uprobes/$TEST_NAME/enable 2>/dev/null
    echo "-:$TEST_NAME" > /sys/kernel/debug/tracing/uprobe_events 2>/dev/null
else
    echo "✗ Failed to create uprobe"
    dmesg | tail -5
fi
echo

# 5. Check current uprobe_events
echo "Currently registered uprobes:"
UPROBE_COUNT=$(wc -l < /sys/kernel/debug/tracing/uprobe_events 2>/dev/null)
echo "Total: $UPROBE_COUNT"
if [ $UPROBE_COUNT -gt 0 ]; then
    head -10 /sys/kernel/debug/tracing/uprobe_events
    if [ $UPROBE_COUNT -gt 10 ]; then
        echo "... ($((UPROBE_COUNT - 10)) more)"
    fi
fi
echo

# 6. Check if trace_pipe has any activity
echo "Checking trace_pipe activity..."
echo "Run this in another terminal:"
echo "  sudo cat /sys/kernel/debug/tracing/trace_pipe | head -20"
echo
echo "Then generate some I/O:"
echo "  rados bench -p test 10 write"
echo
echo "If you see 'Entered into uprobe_' messages, uprobes ARE working"
echo "If you see nothing, the function is not being called"
echo

# 7. Specific OSD check
if echo "$BINARY" | grep -q ceph-osd; then
    echo "OSD-specific checks:"
    
    # Check if OSD is in the cluster
    OSD_ID=$(echo "$CMDLINE" | grep -oP '(?<=--id )\d+')
    if [ ! -z "$OSD_ID" ]; then
        echo "  OSD ID: $OSD_ID"
        
        # Check OSD status
        if command -v ceph &> /dev/null; then
            echo "  OSD status:"
            ceph osd tree | grep "osd.$OSD_ID" || echo "    (ceph command not available)"
            
            echo
            echo "  To send I/O to this OSD:"
            echo "    1. Find a PG on this OSD: ceph pg dump | grep 'active+clean' | grep '\[$OSD_ID,'"
            echo "    2. Write to that pool: rados bench -p <pool> 10 write"
        fi
    fi
fi
echo

echo "=========================================="
echo "Test complete"
echo "=========================================="

