# Tracing MicroCeph Snap-based Deployments

MicroCeph deploys Ceph as a self-contained snap package. The cephtrace binary
runs on the host while the target process runs inside the snap's confinement.
cephtrace resolves the libraries a snap-confined process actually loaded from
`/proc/<pid>/maps` (e.g. `/snap/microceph/<rev>/lib/...`, or LXD's qemu under
`/snap/lxd/<rev>/...`), so the only thing that determines the workflow is
whether the snap's Ceph version has **embedded DWARF data**.

**Key points:**
- The binary runs on the host; the traced process runs inside the snap.
- DWARF data must match the *snap's* Ceph version, not the host's.
- If the version is embedded (Part 1), there is nothing to download or
  configure. If it is not (Part 2), supply a matching DWARF file and skip the
  host version check.

---

## Part 1: Default - Embedded DWARF (no setup)

cephtrace ships with DWARF data for many common Ceph releases compiled into the
binary, matched by the ELF build-id of the library the snap process loaded. For
covered versions no manifest lookup, DWARF download, or `--skip-version-check`
is needed.

### 1. Discover processes and check coverage

`--list` shows each process's host PID, snap/container status, Ceph version, and
a `Traceable` column - `yes` means embedded DWARF data already covers this
version.

```bash
# Clients (radosgw, qemu, ...)
sudo ./radostrace --list

# ceph-osd processes, with their OSD IDs
sudo ./osdtrace --list
```

Use `--list-embedded` to see every Ceph version with compiled-in DWARF data.

### 2. Trace directly

Use the host PID (and, for OSDs, the OSD ID) reported by `--list`:

```bash
# Client process - -p is mandatory for snap-confined tracing
sudo ./radostrace -p <HOST_PID>

# OSD - by OSD ID, by host PID, or every traceable OSD on the host
sudo ./osdtrace --id <OSD_ID>
sudo ./osdtrace -p <HOST_PID>
sudo ./osdtrace -a
```

If the `Traceable` column shows `yes`, you are done - skip Part 2 entirely.

---

## Part 2: Non-embedded versions (manual DWARF data)

When `--list` shows `Traceable = no` (the snap's Ceph version isn't in
`--list-embedded`), supply DWARF data matching the *snap's* Ceph version and
trace a specific PID with `--skip-version-check`.

### 1. Determine the snap's Ceph version

The snap bundles specific package versions that may differ from the host. Read
them from the snap manifest:

```bash
# librados version (for radostrace)
grep librados2 /snap/microceph/current/snap/manifest.yaml
# Example: librados2: 17.2.6-0ubuntu0.22.04.3

# ceph-osd version (for osdtrace)
grep ceph-osd /snap/microceph/current/snap/manifest.yaml
```

The version string (e.g. `17.2.6-0ubuntu0.22.04.3`) is what selects the correct
DWARF file.

### 2. Get a DWARF file matching that version

Pre-generated files live in the repo under `files/ubuntu/<tool>/`, named by the
snap's Ceph package version:

```bash
# radostrace (librados2 version)
wget https://raw.githubusercontent.com/taodd/cephtrace/main/files/ubuntu/radostrace/17.2.6-0ubuntu0.22.04.3_dwarf.json

# osdtrace (ceph-osd version)
wget https://raw.githubusercontent.com/taodd/cephtrace/main/files/ubuntu/osdtrace/osd-17.2.6-0ubuntu0.22.04.3_dwarf.json
```

If no matching file exists, generate one (see [Generating DWARF data](#generating-dwarf-data) below).

### 3. Trace with --skip-version-check

```bash
# Client
sudo ./radostrace -i 17.2.6-0ubuntu0.22.04.3_dwarf.json -p <HOST_PID> --skip-version-check

# OSD
sudo ./osdtrace -i osd-17.2.6-0ubuntu0.22.04.3_dwarf.json -p <HOST_PID> --skip-version-check
```

**Why `--skip-version-check`?** The tool compares against the host's library
version, which differs from the version isolated inside the snap. The check
would otherwise fail even though the DWARF file is correct for the snap, so it
must be skipped.

### Generating DWARF data

If no pre-generated DWARF file exists for your snap's Ceph version, build one on
an Ubuntu system matching the snap's base and Ceph version (from the manifest):

```bash
# Install the exact Ceph version and its debug symbols
sudo apt-get install ceph-osd=17.2.6-0ubuntu0.22.04.3 \
                     ceph-osd-dbgsym=17.2.6-0ubuntu0.22.04.3

# Export the DWARF JSON
sudo ./osdtrace -j osd-17.2.6-0ubuntu0.22.04.3_dwarf.json
```

Copy the JSON to your MicroCeph host and use it with `--skip-version-check`. See
[DWARF JSON Files](dwarf-json-files.md) for more detail.

---

## kfstrace with MicroCeph

**kfstrace works normally with MicroCeph - no special steps.** It traces the
kernel module (`ceph.ko`), which runs on the host rather than inside the snap,
so none of the above snap complexity applies.

```bash
wget https://github.com/taodd/cephtrace/releases/latest/download/kfstrace
chmod +x kfstrace
sudo ./kfstrace
```

## See Also

- [Tracing Containerized Ceph](tracing-containerized-ceph.md) - Similar concepts for container deployments
- [DWARF JSON Files](dwarf-json-files.md) - Generating and managing DWARF files
