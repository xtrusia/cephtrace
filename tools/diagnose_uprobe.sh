#!/bin/bash

# Diagnostic script for uprobe tracing issues
# Usage: sudo ./diagnose_uprobe.sh <pid>

if [ "$EUID" -ne 0 ]; then
    echo "Error: This script must be run as root"
    exit 1
fi

if [ $# -lt 1 ]; then
    echo "Usage: $0 <pid> [binary_name]"
    echo "Example: $0 12345 ceph-osd"
    exit 1
fi

PID=$1
BINARY=${2:-"ceph-osd"}

echo "=========================================="
echo "Uprobe Diagnostic Tool for PID $PID"
echo "=========================================="
echo

# Check if process exists
if [ ! -d "/proc/$PID" ]; then
    echo "ERROR: Process $PID does not exist"
    exit 1
fi

echo "1. Process Information"
echo "----------------------"
CMDLINE=$(cat /proc/$PID/cmdline | tr '\0' ' ')
echo "Command line: $CMDLINE"
EXE=$(readlink /proc/$PID/exe 2>/dev/null)
echo "Executable: $EXE"
echo

echo "2. Memory Mappings for '$BINARY'"
echo "--------------------------------"
echo "Looking in /proc/$PID/maps..."
MAPS=$(grep "$BINARY" /proc/$PID/maps 2>/dev/null)
if [ -z "$MAPS" ]; then
    echo "WARNING: No mappings found for '$BINARY'"
    echo "Try searching for other terms:"
    echo "Available mappings:"
    grep -E '\.(so|exe)' /proc/$PID/maps | awk '{print $NF}' | sort -u | head -20
else
    echo "$MAPS"
    echo
    echo "Executable sections (r-xp):"
    echo "$MAPS" | grep r-xp
    
    # Extract the actual path
    ACTUAL_PATH=$(echo "$MAPS" | grep r-xp | head -1 | awk '{print $NF}')
    if [ ! -z "$ACTUAL_PATH" ]; then
        echo
        echo "Detected binary path: $ACTUAL_PATH"
        
        # Check if file exists
        if [ -f "$ACTUAL_PATH" ]; then
            echo "✓ File exists"
            
            # Get inode
            INODE=$(ls -i "$ACTUAL_PATH" | awk '{print $1}')
            echo "  Inode: $INODE"
            
            # Get file info
            FILE_INFO=$(file "$ACTUAL_PATH")
            echo "  Type: $FILE_INFO"
            
            # Check for debug symbols
            if readelf -S "$ACTUAL_PATH" 2>/dev/null | grep -q debug; then
                echo "  ✓ Has debug symbols"
            else
                echo "  ✗ No debug symbols (DWARF info needed from separate debug package)"
            fi
        else
            echo "✗ File does not exist or not accessible"
        fi
    fi
fi
echo

echo "3. Namespace Information"
echo "------------------------"
if [ -L "/proc/$PID/ns/mnt" ]; then
    HOST_MNT=$(readlink /proc/self/ns/mnt)
    PROC_MNT=$(readlink /proc/$PID/ns/mnt)
    echo "Host mount namespace: $HOST_MNT"
    echo "Process mount namespace: $PROC_MNT"
    if [ "$HOST_MNT" != "$PROC_MNT" ]; then
        echo "⚠ Process is in a DIFFERENT mount namespace (container/snap)"
        echo "  This requires special handling for uprobe attachment"
    else
        echo "✓ Same mount namespace as host"
    fi
else
    echo "Could not read namespace information"
fi
echo

echo "4. Current Uprobes"
echo "------------------"
if [ -f /sys/kernel/debug/tracing/uprobe_events ]; then
    UPROBE_COUNT=$(wc -l < /sys/kernel/debug/tracing/uprobe_events)
    echo "Total uprobes registered: $UPROBE_COUNT"
    if [ $UPROBE_COUNT -gt 0 ]; then
        echo "Sample (first 5):"
        head -5 /sys/kernel/debug/tracing/uprobe_events
    fi
else
    echo "Cannot access /sys/kernel/debug/tracing/uprobe_events"
    echo "Make sure debugfs is mounted: mount -t debugfs none /sys/kernel/debug"
fi
echo

echo "5. BPF Programs"
echo "---------------"
BPF_COUNT=$(ls /sys/fs/bpf 2>/dev/null | wc -l)
echo "BPF programs loaded: $BPF_COUNT"
if command -v bpftool &> /dev/null; then
    echo "Loaded BPF programs (bpftool prog list | head -10):"
    bpftool prog list | head -10
else
    echo "Install bpftool for more detailed BPF information"
fi
echo

echo "6. Recommendations"
echo "------------------"
if [ ! -z "$ACTUAL_PATH" ] && [ -f "$ACTUAL_PATH" ]; then
    echo "To trace this process, use:"
    echo "  sudo ./osdtrace -i <dwarf.json> -p $PID -x --skip-version-check"
    echo
    echo "The tool should automatically use: $ACTUAL_PATH"
    echo
    echo "To verify events are being generated:"
    echo "  Terminal 1: sudo cat /sys/kernel/debug/tracing/trace_pipe"
    echo "  Terminal 2: sudo ./osdtrace -i <dwarf.json> -p $PID -x"
    echo "  Terminal 3: Generate I/O (e.g., rados bench -p test 10 write)"
else
    echo "Could not find binary path in process memory maps"
    echo "Make sure the process is actually running $BINARY"
fi
echo

echo "=========================================="
echo "Diagnostic complete"
echo "=========================================="

