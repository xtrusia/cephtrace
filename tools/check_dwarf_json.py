#!/usr/bin/env python3

import json
import sys

if len(sys.argv) < 2:
    print("Usage: python3 check_dwarf_json.py <dwarf.json>")
    sys.exit(1)

json_file = sys.argv[1]

try:
    with open(json_file, 'r') as f:
        data = json.load(f)
except Exception as e:
    print(f"Error reading JSON file: {e}")
    sys.exit(1)

print("=" * 50)
print("DWARF JSON File Analysis")
print("=" * 50)
print(f"File: {json_file}")
print()

# Check version info
if 'version' in data:
    print(f"Version: {data['version']}")
else:
    print("Version: Not specified")
print()

# Check for module function mappings
if 'mod_func2pc' in data:
    print("Function offsets (mod_func2pc):")
    for mod_path, funcs in data['mod_func2pc'].items():
        print(f"\n  Module: {mod_path}")
        if not funcs:
            print("    ⚠ No functions found!")
            continue
        
        zero_count = 0
        valid_count = 0
        
        for func_name, offset in funcs.items():
            if offset == "0x0" or offset == 0 or offset == "0":
                zero_count += 1
                print(f"    ✗ {func_name}: {offset} (INVALID!)")
            else:
                valid_count += 1
                if valid_count <= 5:  # Show first 5
                    print(f"    ✓ {func_name}: {offset}")
        
        if valid_count > 5:
            print(f"    ... and {valid_count - 5} more valid functions")
        
        print(f"\n  Summary: {valid_count} valid, {zero_count} invalid (offset=0)")
        
        if zero_count > 0:
            print("  ⚠ WARNING: Functions with offset=0x0 will not work!")
else:
    print("⚠ No mod_func2pc found in JSON!")

print()

# Check for variable field info
if 'mod_func2vf' in data:
    print("Variable field mappings (mod_func2vf):")
    for mod_path, funcs in data['mod_func2vf'].items():
        print(f"  Module: {mod_path}")
        print(f"    Functions with variable info: {len(funcs)}")
else:
    print("⚠ No mod_func2vf found in JSON!")

print()
print("=" * 50)
print("DIAGNOSIS:")
print("=" * 50)

# Final diagnosis
has_valid_offsets = False
if 'mod_func2pc' in data:
    for mod_path, funcs in data['mod_func2pc'].items():
        for func_name, offset in funcs.items():
            if offset not in ["0x0", 0, "0", ""]:
                has_valid_offsets = True
                break

if has_valid_offsets:
    print("✓ JSON file has valid function offsets")
    print("  → This JSON should work")
else:
    print("✗ JSON file has NO valid function offsets!")
    print("  → DWARF parsing failed")
    print()
    print("  Possible reasons:")
    print("  1. Binary was stripped without debug info")
    print("  2. Debug symbols not installed")
    print("  3. DWARF parsing error")
    print()
    print("  Solution:")
    print("  1. Install debug symbols (ceph-osd-dbgsym)")
    print("  2. Enable debuginfod:")
    print("     export DEBUGINFOD_URLS='https://debuginfod.ubuntu.com'")
    print("  3. Regenerate JSON:")
    print("     sudo -E ./osdtrace -p <PID> -j new_dwarf.json")

print()

