#!/usr/bin/env python3
"""Detect Ceph point releases for which we don't yet ship embedded DWARF JSONs.

Phase 1: centos-stream el9 only.  Probes download.ceph.com for the ceph-osd
RPMs of each (major.2.patch) candidate version and diffs against the JSONs
already present under files/centos-stream/{osdtrace,radostrace}/.

Output (one row per (version, missing-tool-list)) is TSV on stdout so the
companion shell driver can read it line-by-line:

  centos-stream  osdtrace,radostrace  17.2.4  2:17.2.4-0.el9  <rpm-url>

The columns are: distro, comma-joined-tool-list, upstream-version,
package-version-string (matches what `osdtrace -j` records as the JSON's
`version` field), and the RPM URL the row's existence was inferred from
(included for traceability / debuggability of CI runs).
"""

from __future__ import annotations

import argparse
import sys
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
CENTOS_DIR = REPO_ROOT / "files" / "centos-stream"
DOWNLOAD_BASE = "https://download.ceph.com"

# We only care about the modern lines (quincy, reef, squid, tentacle).
# Each major has a single (X.2) minor line.
MAJOR_VERSIONS = [17, 18, 19, 20]

# Centos-stream el9 ceph-osd RPM URL template.
RPM_URL_TMPL = "{base}/rpm-{ver}/el9/x86_64/ceph-osd-{ver}-0.el9.x86_64.rpm"

# Probe up to this many patch releases per major.  20 is generous; quincy
# topped out at 17.2.9 and the longest historical Ceph line (octopus) ran
# through 15.2.17 so this leaves plenty of headroom.
CANDIDATE_PATCHES = list(range(0, 20))


def head(url: str, *, timeout: float = 15.0) -> int:
    """HTTP HEAD returning the status code, or 0 on network error.

    Used to probe whether a given RPM URL exists; HEAD is much cheaper than
    GET and download.ceph.com supports it.  A 0 return means we treat the
    URL as unavailable -- safer than retrying the workflow with a partial
    discovery on a flaky run.
    """
    req = urllib.request.Request(url, method="HEAD")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status
    except OSError:
        return 0


def upstream_el9_versions() -> list[str]:
    """Versions that have an el9 ceph-osd RPM published upstream.

    Probes every (major.2.0 .. major.2.19) combination; cheap (~80 HEAD
    requests, ~10 s total) and avoids fragile HTML scraping of the directory
    index.  Returns a sorted (version-tuple-ascending) list.
    """
    out: list[str] = []
    for maj in MAJOR_VERSIONS:
        for patch in CANDIDATE_PATCHES:
            ver = f"{maj}.2.{patch}"
            url = RPM_URL_TMPL.format(base=DOWNLOAD_BASE, ver=ver)
            if head(url) == 200:
                out.append(ver)
    return out


def existing_versions(tool: str) -> set[str]:
    """Versions already covered by JSONs under files/centos-stream/<tool>/."""
    d = CENTOS_DIR / tool
    if not d.is_dir():
        return set()
    prefix = {"osdtrace": "osd-2:", "radostrace": "rados-2:"}[tool]
    suffix = "-0.el9_dwarf.json"
    return {
        name[len(prefix):-len(suffix)]
        for name in (p.name for p in d.iterdir())
        if name.startswith(prefix) and name.endswith(suffix)
    }


def version_key(v: str) -> tuple[int, ...]:
    """Sort key turning a dotted version string into an int tuple."""
    return tuple(int(x) for x in v.split("."))


def covered_ceiling(
    osd_have: set[str], rados_have: set[str]
) -> dict[int, int]:
    """Highest *fully covered* patch (both tools present) per major.

    "Fully covered" = a version we ship JSONs for in BOTH osdtrace and
    radostrace.  A major absent from the result has no fully-covered version
    at all (a brand-new line, or one we've never backfilled).
    """
    ceiling: dict[int, int] = {}
    for ver in osd_have & rados_have:
        try:
            major, _minor, patch = (int(x) for x in ver.split("."))
        except ValueError:
            continue
        ceiling[major] = max(ceiling.get(major, -1), patch)
    return ceiling


def is_new_release(ver: str, ceiling: dict[int, int]) -> bool:
    """True when ver is a point release *newer* than our ceiling for its major.

    Used by --new-only to pick up only freshly-published point releases on
    lines we already maintain.  A major with no fully-covered version (not in
    ``ceiling``) is treated as historical/backlog and left to the backfill
    workflow, so this never auto-grabs an entire uncovered line.
    """
    major, _minor, patch = (int(x) for x in ver.split("."))
    return major in ceiling and patch > ceiling[major]


def main() -> None:
    """Probe upstream, diff against shipped JSONs, print missing TSV rows."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--new-only",
        action="store_true",
        help="emit only point releases newer than the highest fully-covered "
             "patch of each major (skip historical gaps and uncovered lines)",
    )
    args = parser.parse_args()

    upstream = upstream_el9_versions()
    if not upstream:
        # Treat a fully-empty probe set as a hard error: it almost always
        # means download.ceph.com is unreachable from the runner, and
        # opening a PR that deletes nothing is harmless but auto-merging
        # against an empty diff would be misleading.
        print("ERROR: no upstream RPMs detected; aborting", file=sys.stderr)
        sys.exit(1)

    osd_have = existing_versions("osdtrace")
    rados_have = existing_versions("radostrace")

    # --new-only: restrict to point releases above each major's fully-covered
    # ceiling, so the scheduled bot picks up only freshly-published releases
    # and leaves the historical backlog to the backfill workflow.
    ceiling = covered_ceiling(osd_have, rados_have) if args.new_only else {}

    # Group missing-tool sets by version so one container session can
    # generate both JSONs for the same version.
    missing: dict[str, list[str]] = {}
    for ver in upstream:
        if args.new_only and not is_new_release(ver, ceiling):
            continue
        tools: list[str] = []
        if ver not in osd_have:
            tools.append("osdtrace")
        if ver not in rados_have:
            tools.append("radostrace")
        if tools:
            missing[ver] = tools

    for ver in sorted(missing, key=version_key):
        tools = missing[ver]
        url = RPM_URL_TMPL.format(base=DOWNLOAD_BASE, ver=ver)
        print(
            "\t".join(
                [
                    "centos-stream",
                    ",".join(sorted(tools)),
                    ver,
                    f"2:{ver}-0.el9",
                    url,
                ]
            )
        )


if __name__ == "__main__":
    main()
