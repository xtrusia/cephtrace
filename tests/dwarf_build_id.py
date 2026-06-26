#!/usr/bin/env python3
"""
Print the build-id key of a cephtrace dwarf JSON.

The key is every per-module build-id, sorted and comma-joined (empty when
the JSON carries no build-id).  dwarf-compare.sh uses it to match a freshly
generated JSON to the checked-in reference for the same binary.
"""

import json
import sys


def build_id_key(file_path: str) -> str:
    """Return the sorted, comma-joined per-module build-id of a dwarf JSON."""
    with open(file_path, 'r', encoding='utf-8') as f:
        data = json.load(f)
    return ",".join(sorted(
        v["build_id"] for v in data.values()
        if isinstance(v, dict) and "build_id" in v
    ))


def main():
    """Main entry point"""
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <dwarf.json>", file=sys.stderr)
        sys.exit(2)
    print(build_id_key(sys.argv[1]))


if __name__ == "__main__":
    main()
