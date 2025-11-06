#!/bin/bash

# Debug uprobe attachment in detail
# Usage: sudo ./debug_attach.sh <pid>

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
echo "Debugging Uprobe Attachment"
echo "PID: $PID"
echo "=========================================="
echo

# 1. Get binary from maps
BINARY=$(cat /proc/$PID/maps | grep 'r-xp' | grep 'ceph-osd' | head -1 | awk '{print $NF}')
echo "Binary from maps: $BINARY"

if [ -z "$BINARY" ]; then
    echo "ERROR: Could not find ceph-osd in /proc/$PID/maps"
    exit 1
fi

# 2. Check if binary is accessible FROM HOST
echo
echo "Checking binary accessibility from HOST namespace:"
if [ -f "$BINARY" ]; then
    echo "✓ Binary exists at: $BINARY"
    ls -lh "$BINARY"
else
    echo "✗ Binary NOT accessible from host at: $BINARY"
    echo
    echo "This is the problem! The path from /proc/$PID/maps is inside"
    echo "the container's namespace, but the host can't access it."
    echo
    echo "Checking alternative paths..."
    
    # Try with /proc/PID/root prefix
    HOST_PATH="/proc/$PID/root$BINARY"
    if [ -f "$HOST_PATH" ]; then
        echo "✓ Found via: $HOST_PATH"
        BINARY="$HOST_PATH"
    else
        # Try without /snap/microceph/current prefix
        BASE_BINARY=$(echo "$BINARY" | sed 's|/snap/microceph/current||')
        if [ -f "$BASE_BINARY" ]; then
            echo "✓ Found at: $BASE_BINARY"
            BINARY="$BASE_BINARY"
        else
            echo "✗ Cannot find accessible path"
            echo
            echo "Possible locations:"
            find /snap/microceph -name "ceph-osd" -type f 2>/dev/null
        fi
    fi
fi
echo

# 3. Try manual uprobe with both paths
echo "Testing manual uprobe creation..."
echo

TEST_NAME="test_debug_$$"

# Test 1: Original path from maps
echo "Test 1: Using path from maps: $BINARY"
echo "-:$TEST_NAME" > /sys/kernel/debug/tracing/uprobe_events 2>/dev/null
echo "p:$TEST_NAME $BINARY:0x1000" > /sys/kernel/debug/tracing/uprobe_events 2>&1

if [ $? -eq 0 ]; then
    if grep -q "$TEST_NAME" /sys/kernel/debug/tracing/uprobe_events; then
        echo "✓ SUCCESS: Uprobe created with this path!"
        cat /sys/kernel/debug/tracing/uprobe_events | grep "$TEST_NAME"
        WORKING_PATH="$BINARY"
    fi
    echo "-:$TEST_NAME" > /sys/kernel/debug/tracing/uprobe_events 2>/dev/null
else
    echo "✗ FAILED with this path"
    echo "Error:"
    dmesg | tail -2
fi
echo

# Test 2: Try /proc/PID/root prefix
if [ -z "$WORKING_PATH" ]; then
    MAPS_BINARY=$(cat /proc/$PID/maps | grep 'r-xp' | grep 'ceph-osd' | head -1 | awk '{print $NF}')
    ROOT_PATH="/proc/$PID/root$MAPS_BINARY"
    
    echo "Test 2: Using /proc/$PID/root prefix: $ROOT_PATH"
    if [ -f "$ROOT_PATH" ]; then
        echo "-:$TEST_NAME" > /sys/kernel/debug/tracing/uprobe_events 2>/dev/null
        echo "p:$TEST_NAME $ROOT_PATH:0x1000" > /sys/kernel/debug/tracing/uprobe_events 2>&1
        
        if [ $? -eq 0 ]; then
            if grep -q "$TEST_NAME" /sys/kernel/debug/tracing/uprobe_events; then
                echo "✓ SUCCESS: Uprobe created with /proc/PID/root prefix!"
                cat /sys/kernel/debug/tracing/uprobe_events | grep "$TEST_NAME"
                WORKING_PATH="$ROOT_PATH"
            fi
            echo "-:$TEST_NAME" > /sys/kernel/debug/tracing/uprobe_events 2>/dev/null
        else
            echo "✗ FAILED with /proc/PID/root prefix"
        fi
    else
        echo "✗ File doesn't exist at: $ROOT_PATH"
    fi
fi
echo

# Test 3: Try /proc/PID/exe
if [ -z "$WORKING_PATH" ]; then
    EXE_PATH=$(readlink /proc/$PID/exe)
    echo "Test 3: Using /proc/$PID/exe: $EXE_PATH"
    
    echo "-:$TEST_NAME" > /sys/kernel/debug/tracing/uprobe_events 2>/dev/null
    echo "p:$TEST_NAME $EXE_PATH:0x1000" > /sys/kernel/debug/tracing/uprobe_events 2>&1
    
    if [ $? -eq 0 ]; then
        if grep -q "$TEST_NAME" /sys/kernel/debug/tracing/uprobe_events; then
            echo "✓ SUCCESS: Uprobe created with /proc/PID/exe!"
            cat /sys/kernel/debug/tracing/uprobe_events | grep "$TEST_NAME"
            WORKING_PATH="$EXE_PATH"
        fi
        echo "-:$TEST_NAME" > /sys/kernel/debug/tracing/uprobe_events 2>/dev/null
    else
        echo "✗ FAILED with /proc/PID/exe"
    fi
fi
echo

# 4. Final result
echo "=========================================="
echo "RESULT:"
echo "=========================================="

if [ ! -z "$WORKING_PATH" ]; then
    echo "✓ Working path found: $WORKING_PATH"
    echo
    echo "Use this path in your code!"
    echo
    echo "Current code should use:"
    echo "  Binary path: $WORKING_PATH"
    echo "  PID for attach: $PID or -1"
    echo
else
    echo "✗ No working path found"
    echo
    echo "This means uprobe cannot attach to this binary."
    echo "Possible reasons:"
    echo "  1. Binary path is in a namespace not accessible from host"
    echo "  2. Security restrictions (AppArmor, SELinux)"
    echo "  3. Kernel doesn't support this configuration"
    echo
    echo "Alternative approaches:"
    echo "  1. Use kfstrace (kernel-level tracing, no uprobe needed)"
    echo "  2. Run tracing tool inside the same namespace"
    echo "  3. Check snap/container confinement settings"
fi

# Clean up
echo "-:$TEST_NAME" > /sys/kernel/debug/tracing/uprobe_events 2>/dev/null

echo
echo "=========================================="

