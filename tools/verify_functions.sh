#!/bin/bash

# Verify that functions actually exist in the binary at the expected offsets
# Usage: sudo ./verify_functions.sh <pid> <binary_path>

if [ "$EUID" -ne 0 ]; then
    echo "Error: Must run as root"
    exit 1
fi

if [ $# -lt 2 ]; then
    echo "Usage: $0 <pid> <binary_path>"
    echo "Example: $0 12345 /snap/microceph/current/usr/bin/ceph-osd"
    exit 1
fi

PID=$1
BINARY=$2

echo "=========================================="
echo "Function Verification Tool"
echo "=========================================="
echo "PID: $PID"
echo "Binary: $BINARY"
echo

# 1. Check if binary exists
if [ ! -f "$BINARY" ]; then
    echo "ERROR: Binary not found at $BINARY"
    echo
    echo "Try finding it from /proc/$PID/maps:"
    cat /proc/$PID/maps | grep 'r-xp' | head -5
    exit 1
fi

echo "✓ Binary exists and is accessible"
echo

# 2. Check if binary has symbols
echo "Checking for symbols..."
if command -v nm &> /dev/null; then
    SYMBOL_COUNT=$(nm "$BINARY" 2>/dev/null | wc -l)
    if [ $SYMBOL_COUNT -gt 0 ]; then
        echo "✓ Binary has $SYMBOL_COUNT symbols"
        echo
        echo "Sample function addresses (first 10):"
        nm "$BINARY" 2>/dev/null | grep ' T ' | head -10
    else
        echo "⚠ Binary is stripped (no symbols)"
        echo "This is OK if using DWARF JSON with debug info"
    fi
else
    echo "Install 'binutils' package for symbol checking"
fi
echo

# 3. Check for debug info
echo "Checking for debug information..."
if command -v readelf &> /dev/null; then
    if readelf -S "$BINARY" 2>/dev/null | grep -q debug; then
        echo "✓ Binary has debug sections"
        readelf -S "$BINARY" 2>/dev/null | grep debug | head -5
    else
        echo "⚠ Binary has no debug sections"
        echo "Need DWARF JSON from debug package or separate debug file"
    fi
else
    echo "Install 'binutils' package for debug info checking"
fi
echo

# 4. Check specific OSD functions
echo "Looking for common OSD functions..."
if command -v nm &> /dev/null; then
    echo "Searching for key functions:"
    for func in "dequeue_op" "enqueue_op" "log_op_stats" "queue_transactions"; do
        FOUND=$(nm "$BINARY" 2>/dev/null | grep -i "$func" | head -3)
        if [ ! -z "$FOUND" ]; then
            echo "  ✓ Found $func:"
            echo "$FOUND" | sed 's/^/    /'
        else
            echo "  ✗ Not found: $func"
        fi
    done
fi
echo

# 5. Test a simple uprobe manually
echo "Testing manual uprobe creation..."
TEST_NAME="test_verify_$$"

# Clean up any existing test
echo "-:$TEST_NAME" > /sys/kernel/debug/tracing/uprobe_events 2>/dev/null

# Get base address from /proc/PID/maps
BASE_ADDR=$(cat /proc/$PID/maps | grep -m1 'r-xp.*ceph-osd' | awk '{print $1}' | cut -d'-' -f1)
if [ -z "$BASE_ADDR" ]; then
    echo "ERROR: Could not find base address in /proc/$PID/maps"
    exit 1
fi

echo "Base address from maps: 0x$BASE_ADDR"

# Try to get a function offset
FUNC_OFFSET=""
if command -v nm &> /dev/null; then
    # Try to find a simple function
    FUNC_OFFSET=$(nm "$BINARY" 2>/dev/null | grep -E " T (main|_start)" | head -1 | awk '{print $1}')
    if [ ! -z "$FUNC_OFFSET" ]; then
        echo "Test function offset: 0x$FUNC_OFFSET"
        
        # Try to create uprobe
        echo "p:$TEST_NAME $BINARY:0x$FUNC_OFFSET" > /sys/kernel/debug/tracing/uprobe_events 2>/dev/null
        if [ $? -eq 0 ]; then
            echo "✓ Manual uprobe created successfully"
            # Check if it's registered
            if grep -q "$TEST_NAME" /sys/kernel/debug/tracing/uprobe_events; then
                echo "✓ Uprobe is registered"
                cat /sys/kernel/debug/tracing/uprobe_events | grep "$TEST_NAME"
            fi
            # Clean up
            echo "-:$TEST_NAME" > /sys/kernel/debug/tracing/uprobe_events 2>/dev/null
        else
            echo "✗ Failed to create manual uprobe"
            dmesg | tail -3
        fi
    fi
fi
echo

# 6. Recommendations
echo "=========================================="
echo "RECOMMENDATIONS:"
echo "=========================================="
echo
echo "If functions are not found or binary is stripped:"
echo "  1. Generate DWARF JSON directly from this binary:"
echo "     sudo ./osdtrace -p $PID -j osd_dwarf_$PID.json"
echo
echo "  2. Then use that JSON file:"
echo "     sudo ./osdtrace -p $PID -i osd_dwarf_$PID.json -x --skip-version-check"
echo
echo "If functions exist but events don't appear:"
echo "  1. Functions might be inlined - use a different probe point"
echo "  2. Process might not be executing those code paths"
echo "  3. Check: sudo cat /sys/kernel/debug/tracing/trace_pipe"
echo "  4. Generate I/O: rados bench -p test 10 write"
echo
echo "Binary version mismatch check:"
echo "  Host binary: $(file $BINARY 2>/dev/null | cut -d: -f2)"
echo "  JSON was generated for: [Check your DWARF JSON filename]"
echo

