#!/bin/bash

# Find debug file for a stripped binary
# Usage: sudo ./find_debug_file.sh <binary_path>

BINARY=$1

if [ -z "$BINARY" ] || [ ! -f "$BINARY" ]; then
    echo "Usage: $0 <binary_path>"
    echo "Example: $0 /snap/microceph/current/bin/ceph-osd"
    exit 1
fi

echo "=========================================="
echo "Debug File Finder"
echo "=========================================="
echo "Binary: $BINARY"
echo

# 1. Get Build ID
if command -v readelf &> /dev/null; then
    BUILD_ID=$(readelf -n "$BINARY" | grep "Build ID" | awk '{print $3}')
    if [ ! -z "$BUILD_ID" ]; then
        echo "Build ID: $BUILD_ID"
        
        # Split Build ID for .build-id path
        BUILD_ID_PREFIX=${BUILD_ID:0:2}
        BUILD_ID_SUFFIX=${BUILD_ID:2}
        echo "Build ID path: /usr/lib/debug/.build-id/$BUILD_ID_PREFIX/$BUILD_ID_SUFFIX.debug"
    fi
else
    echo "Install binutils: sudo apt-get install binutils"
    exit 1
fi
echo

# 2. Check for debuglink
DEBUGLINK=$(readelf -p .gnu_debuglink "$BINARY" 2>/dev/null | grep -v "String dump" | tail -1 | awk '{print $3}')
if [ ! -z "$DEBUGLINK" ]; then
    echo "Debug link: $DEBUGLINK"
fi
echo

# 3. Search for debug files
echo "Searching for debug files..."
BINARY_DIR=$(dirname "$BINARY")
BINARY_NAME=$(basename "$BINARY")

# Search locations
SEARCH_PATHS=(
    "$BINARY_DIR/.debug/$BINARY_NAME.debug"
    "$BINARY_DIR/$BINARY_NAME.debug"
    "/usr/lib/debug$BINARY"
    "/usr/lib/debug$BINARY.debug"
    "/usr/lib/debug/.build-id/$BUILD_ID_PREFIX/$BUILD_ID_SUFFIX.debug"
    "/snap/microceph/current/usr/lib/debug/bin/ceph-osd"
    "/snap/microceph/current/.debug/ceph-osd"
)

FOUND=0
for path in "${SEARCH_PATHS[@]}"; do
    if [ -f "$path" ]; then
        echo "✓ Found: $path"
        
        # Verify it's the right debug file
        if readelf -n "$path" 2>/dev/null | grep -q "$BUILD_ID"; then
            echo "  ✓ Build ID matches!"
            FOUND=1
            DEBUG_FILE="$path"
        else
            echo "  ✗ Build ID mismatch"
        fi
    fi
done

if [ $FOUND -eq 0 ]; then
    echo "✗ No debug file found"
    echo
    echo "Trying wider search..."
    
    # Search in snap directory
    if echo "$BINARY" | grep -q "^/snap/"; then
        SNAP_NAME=$(echo "$BINARY" | cut -d/ -f3)
        SNAP_REV=$(echo "$BINARY" | cut -d/ -f4)
        
        echo "Searching in snap: $SNAP_NAME (revision: $SNAP_REV)"
        find "/snap/$SNAP_NAME/$SNAP_REV" -name "*.debug" 2>/dev/null | head -10
        find "/snap/$SNAP_NAME/$SNAP_REV" -path "*/.debug/*" 2>/dev/null | head -10
        find "/snap/$SNAP_NAME/$SNAP_REV" -name "*dbg*" -o -name "*debug*" 2>/dev/null | head -10
    fi
    
    echo
    echo "Searching system-wide (this may take a while)..."
    find /usr/lib/debug -name "*ceph*" -name "*.debug" 2>/dev/null | head -20
fi
echo

# 4. Check debuginfod
echo "Debuginfod support:"
if [ ! -z "$DEBUGINFOD_URLS" ]; then
    echo "  DEBUGINFOD_URLS is set: $DEBUGINFOD_URLS"
else
    echo "  ✗ DEBUGINFOD_URLS not set"
    echo "  To enable: export DEBUGINFOD_URLS='https://debuginfod.ubuntu.com'"
fi
echo

# 5. Recommendations
echo "=========================================="
echo "RECOMMENDATIONS:"
echo "=========================================="
echo

if [ $FOUND -eq 1 ]; then
    echo "✓ Debug file found: $DEBUG_FILE"
    echo
    echo "To use it with osdtrace:"
    echo "  1. Make sure dwarf_parser can find this debug file"
    echo "  2. Or copy debug info into the binary"
    echo
else
    echo "Debug file not found. Options:"
    echo
    echo "Option 1: Install debug snap (if available)"
    echo "  snap info microceph | grep debug"
    echo "  sudo snap install <debug-snap-name>"
    echo
    echo "Option 2: Use debuginfod (Ubuntu 20.04+)"
    echo "  export DEBUGINFOD_URLS='https://debuginfod.ubuntu.com'"
    echo "  sudo apt-get install debuginfod libdebuginfod-dev"
    echo
    echo "Option 3: Install regular ceph debug package"
    echo "  sudo apt-get install ceph-osd-dbgsym"
    echo "  Note: Version might not match microceph"
    echo
    echo "Option 4: Alternative approach - use kprobes instead"
    echo "  Consider using kfstrace which doesn't need DWARF info"
    echo
    echo "Current status:"
    echo "  - Binary is stripped: YES"
    echo "  - Debug sections in binary: $(readelf -S "$BINARY" 2>/dev/null | grep -c debug)"
    echo "  - Separate debug file: NOT FOUND"
    echo "  - This means DWARF parsing will fail or give incorrect offsets"
fi
echo

