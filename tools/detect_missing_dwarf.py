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
    except Exception:
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
    return tuple(int(x) for x in v.split("."))


def main() -> None:
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

    # Group missing-tool sets by version so one container session can
    # generate both JSONs for the same version.
    missing: dict[str, list[str]] = {}
    for ver in upstream:
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
