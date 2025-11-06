#!/bin/bash

# Check namespace isolation issues
# Usage: sudo ./check_namespace.sh <pid>

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
echo "Namespace Isolation Check"
echo "PID: $PID"
echo "=========================================="
echo

# 1. Compare namespaces
echo "Comparing namespaces between host and process:"
echo

HOST_PID=$$
for ns in mnt pid net user; do
    HOST_NS=$(readlink /proc/$HOST_PID/ns/$ns 2>/dev/null)
    PROC_NS=$(readlink /proc/$PID/ns/$ns 2>/dev/null)
    
    printf "%-10s Host: %-20s Process: %-20s " "$ns" "$HOST_NS" "$PROC_NS"
    
    if [ "$HOST_NS" = "$PROC_NS" ]; then
        echo "✓ SAME"
    else
        echo "✗ DIFFERENT"
    fi
done
echo

# 2. Check file system access
echo "File system access check:"
BINARY=$(cat /proc/$PID/maps | grep 'r-xp' | grep -E '(ceph-osd|librados)' | head -1 | awk '{print $NF}')
echo "Binary from maps: $BINARY"
echo

# Test different access methods
echo "Access test 1: Direct path"
if [ -f "$BINARY" ]; then
    INODE1=$(stat -c %i "$BINARY" 2>/dev/null)
    echo "  ✓ Accessible, inode: $INODE1"
else
    echo "  ✗ NOT accessible"
fi

echo "Access test 2: Via /proc/PID/root"
ROOT_PATH="/proc/$PID/root$BINARY"
if [ -f "$ROOT_PATH" ]; then
    INODE2=$(stat -c %i "$ROOT_PATH" 2>/dev/null)
    echo "  ✓ Accessible, inode: $INODE2"
else
    echo "  ✗ NOT accessible"
fi

echo "Access test 3: Via /proc/PID/exe"
EXE_PATH=$(readlink /proc/$PID/exe 2>/dev/null)
if [ ! -z "$EXE_PATH" ]; then
    echo "  Symlink target: $EXE_PATH"
    if [ -f "$EXE_PATH" ]; then
        INODE3=$(stat -c %i "$EXE_PATH" 2>/dev/null)
        echo "  ✓ Accessible, inode: $INODE3"
    fi
fi
echo

# 3. Compare inodes
echo "Inode comparison:"
if [ ! -z "$INODE1" ] && [ ! -z "$INODE2" ]; then
    if [ "$INODE1" = "$INODE2" ]; then
        echo "  ✓ Direct and /proc/PID/root have SAME inode ($INODE1)"
    else
        echo "  ✗ DIFFERENT inodes: $INODE1 vs $INODE2"
        echo "  This indicates namespace isolation issue!"
    fi
fi

if [ ! -z "$INODE1" ] && [ ! -z "$INODE3" ]; then
    if [ "$INODE1" = "$INODE3" ]; then
        echo "  ✓ Direct and /proc/PID/exe have SAME inode ($INODE1)"
    else
        echo "  ✗ DIFFERENT inodes: $INODE1 vs $INODE3"
    fi
fi
echo

# 4. Test actual uprobe creation with each path
echo "Testing uprobe creation with each path:"
TEST_NAME="ns_test_$$"

# Test with direct path
if [ ! -z "$INODE1" ]; then
    echo
    echo "Test A: Direct path ($BINARY)"
    echo "-:$TEST_NAME" > /sys/kernel/debug/tracing/uprobe_events 2>/dev/null
    
    if echo "p:$TEST_NAME $BINARY:0x1000" > /sys/kernel/debug/tracing/uprobe_events 2>&1; then
        if grep -q "$TEST_NAME" /sys/kernel/debug/tracing/uprobe_events 2>/dev/null; then
            echo "  ✓ Uprobe CREATED and REGISTERED"
            cat /sys/kernel/debug/tracing/uprobe_events | grep "$TEST_NAME"
            BEST_PATH="$BINARY"
        else
            echo "  ✗ Created but not registered"
        fi
        echo "-:$TEST_NAME" > /sys/kernel/debug/tracing/uprobe_events 2>/dev/null
    else
        echo "  ✗ Failed to create"
        dmesg | tail -2
    fi
fi

# Test with /proc/PID/root path
if [ ! -z "$INODE2" ]; then
    echo
    echo "Test B: /proc/PID/root path ($ROOT_PATH)"
    echo "-:$TEST_NAME" > /sys/kernel/debug/tracing/uprobe_events 2>/dev/null
    
    if echo "p:$TEST_NAME $ROOT_PATH:0x1000" > /sys/kernel/debug/tracing/uprobe_events 2>&1; then
        if grep -q "$TEST_NAME" /sys/kernel/debug/tracing/uprobe_events 2>/dev/null; then
            echo "  ✓ Uprobe CREATED and REGISTERED"
            cat /sys/kernel/debug/tracing/uprobe_events | grep "$TEST_NAME"
            if [ -z "$BEST_PATH" ]; then
                BEST_PATH="$ROOT_PATH"
            fi
        else
            echo "  ✗ Created but not registered"
        fi
        echo "-:$TEST_NAME" > /sys/kernel/debug/tracing/uprobe_events 2>/dev/null
    else
        echo "  ✗ Failed to create"
    fi
fi

# Test with /proc/PID/exe
if [ ! -z "$INODE3" ]; then
    echo
    echo "Test C: /proc/PID/exe path ($EXE_PATH)"
    echo "-:$TEST_NAME" > /sys/kernel/debug/tracing/uprobe_events 2>/dev/null
    
    if echo "p:$TEST_NAME $EXE_PATH:0x1000" > /sys/kernel/debug/tracing/uprobe_events 2>&1; then
        if grep -q "$TEST_NAME" /sys/kernel/debug/tracing/uprobe_events 2>/dev/null; then
            echo "  ✓ Uprobe CREATED and REGISTERED"
            cat /sys/kernel/debug/tracing/uprobe_events | grep "$TEST_NAME"
            if [ -z "$BEST_PATH" ]; then
                BEST_PATH="$EXE_PATH"
            fi
        else
            echo "  ✗ Created but not registered"
        fi
        echo "-:$TEST_NAME" > /sys/kernel/debug/tracing/uprobe_events 2>/dev/null
    else
        echo "  ✗ Failed to create"
    fi
fi

# Clean up
echo "-:$TEST_NAME" > /sys/kernel/debug/tracing/uprobe_events 2>/dev/null

echo
echo "=========================================="
echo "FINAL RECOMMENDATION:"
echo "=========================================="

if [ ! -z "$BEST_PATH" ]; then
    echo "✓ Working path: $BEST_PATH"
    echo
    echo "Your osdtrace should use:"
    echo "  Path: $BEST_PATH"
    echo "  PID: $PID"
    echo
    echo "Make sure the code outputs this exact path in 'FINAL BINARY PATH'"
else
    echo "✗ No working uprobe path found!"
    echo
    echo "This is a serious issue. Possible causes:"
    echo "  1. Snap confinement blocking uprobe"
    echo "  2. AppArmor restrictions"
    echo "  3. Kernel security modules"
    echo
    echo "Check AppArmor status:"
    echo "  sudo aa-status | grep microceph"
    echo
    echo "Check dmesg for denials:"
    echo "  sudo dmesg | grep -i 'denied\|apparmor\|selinux'"
fi
echo

