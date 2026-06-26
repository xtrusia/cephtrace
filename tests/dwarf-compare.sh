#!/bin/bash

# This test is meant to be run after building osdtrace and radostrace.
# This generates new dwarf files and compares to the respective
# reference dwarf files in the repository.

set -ex

# Pull a set of dbgsym .ddebs straight from the Launchpad build artefact
# storage for the currently installed ceph source-package version, then
# install them with dpkg -i.  Used as a fallback when ddebs.ubuntu.com
# does not (yet) carry a matching dbgsym for the version on archive.
install_dbgsyms_from_launchpad() {
    local pkgs="$*"
    local ceph_ver arch src_page candidate_paths base_url workdir pkg
    ceph_ver=$(dpkg -l ceph-common | awk '/^ii/ {print $3}')
    arch=$(dpkg --print-architecture)
    src_page="https://launchpad.net/ubuntu/+source/ceph/${ceph_ver}"

    # The source-package page links one build per architecture.  We don't
    # know which build number is the amd64/arm64/... one without parsing
    # arch metadata out of the surrounding HTML, so instead enumerate the
    # build URLs and pick the first whose +files/ actually has a ddeb at
    # our arch — that proves it is the right build.
    candidate_paths=$(curl -fsSL "$src_page" \
                      | grep -oE '/[^"]+/\+build/[0-9]+' \
                      | sort -u)
    base_url=""
    for path in $candidate_paths; do
        local probe="https://launchpad.net${path}/+files/ceph-osd-dbgsym_${ceph_ver}_${arch}.ddeb"
        if curl -fsI -o /dev/null "$probe"; then
            base_url="https://launchpad.net${path}/+files"
            break
        fi
    done

    if [ -z "$base_url" ]; then
        echo "ERROR: no Launchpad build of ceph ${ceph_ver} on ${arch} carries the requested dbgsyms" >&2
        return 1
    fi

    echo "Fetching dbgsyms from $base_url"
    workdir=$(mktemp -d)
    pushd "$workdir" >/dev/null
    for pkg in $pkgs; do
        wget --no-verbose "${base_url}/${pkg}_${ceph_ver}_${arch}.ddeb"
    done

    # The .ddebs pin the matching main packages by exact version.  The CI
    # runner only has ceph-common installed up to this point — the apt
    # path would have pulled ceph-osd in transitively, but `dpkg -i` does
    # not resolve dependencies, so ensure every main package whose dbgsym
    # we're about to install is present first.
    #
    # Derive the main package name by stripping the "-dbgsym" suffix.
    local main_pkgs=""
    for pkg in $pkgs; do
        main_pkgs="$main_pkgs ${pkg%-dbgsym}"
    done
    # shellcheck disable=SC2086  # word-splitting on $main_pkgs is intended
    sudo apt install -y $main_pkgs

    sudo dpkg -i ./*.ddeb
    popd >/dev/null
    rm -rf "$workdir"
}

# Install the ceph package
sudo apt update
sudo apt install ceph-common -y

# Install debug symbols, needed to generate dwarf.json
sudo apt install ubuntu-dbgsym-keyring -y

echo "Types: deb
URIs: http://ddebs.ubuntu.com/
Suites: $(lsb_release -cs) $(lsb_release -cs)-updates
Components: main restricted universe multiverse
Signed-by: /usr/share/keyrings/ubuntu-dbgsym-keyring.gpg" | \
sudo tee -a /etc/apt/sources.list.d/ddebs.sources

sudo apt update

# Try to install dbgsyms via ddebs.ubuntu.com first.  Ubuntu's *-dbgsym
# packages carry a Depends: <main-pkg> (= <exact-version>) clause, so apt
# refuses the install whenever the matching version is missing from
# ddebs.ubuntu.com.  This is recurringly the case for SRU/security updates:
# the main packages reach archive.ubuntu.com noble-updates / noble-security
# weeks before the ddebs publication step runs, and on some uploads the
# ddebs aren't promoted at all (the .ddebs only ever exist inside the
# security-staging PPA build artefacts on Launchpad).  When that happens,
# fall back to fetching the .ddebs straight from the originating Launchpad
# build's +files/ directory.
DBGSYM_PKGS="ceph-osd-dbgsym librados2-dbgsym librbd1-dbgsym"
if sudo apt install -y $DBGSYM_PKGS; then
    echo "Installed dbgsyms from ddebs.ubuntu.com"
else
    echo "ddebs.ubuntu.com lacks a matching dbgsym version; falling back to Launchpad"
    install_dbgsyms_from_launchpad $DBGSYM_PKGS
fi

# Get the ceph version for reference file lookup
matching_ref_version=$(dpkg -l | awk '$2=="ceph-common" {print $3}')

# Stable key of every per-module build-id in a dwarf JSON (sorted,
# comma-joined; empty when the JSON carries no build-id).
dwarf_build_id_key() {
    ./tests/dwarf_build_id.py "$1"
}

# Pick the reference whose per-module build-ids match the generated JSON.
# A version can ship as several binaries (arch, the 26.04 amd64v3 variant,
# a rebuild), each with its own addresses, so the build-id -- not the
# filename -- selects the right one.
find_ref() {
    local dir="$1" prefix="$2" generated="$3" want cand
    want=$(dwarf_build_id_key "$generated")
    [ -n "$want" ] || return 0
    for cand in "${dir}/${prefix}${matching_ref_version}"*_dwarf.json; do
        [ -e "$cand" ] || continue
        if [ "$(dwarf_build_id_key "$cand")" = "$want" ]; then
            echo "$cand"
            return 0
        fi
    done
}

# Compare a freshly generated JSON against its build-id-matched reference.
compare_by_build_id() {
    local label="$1" dir="$2" prefix="$3" generated="$4" ref
    ref=$(find_ref "$dir" "$prefix" "$generated")
    if [ -n "$ref" ]; then
        echo "Comparing $label against reference $ref"
        ./tests/compare_dwarf_json.py "$ref" "$generated"
        echo "$label dwarf json comparison passed!"
    else
        echo "ERROR: no checked-in $label reference matches build-id" \
             "$(dwarf_build_id_key "$generated") of the installed binary;" \
             "generated JSON left at $generated" >&2
        exit 1
    fi
}

# Test osdtrace dwarf json generation
echo "Testing osdtrace dwarf json generation..."
osd_new_dwarf="generated-osd-dwarf.json"
./osdtrace -j $osd_new_dwarf
compare_by_build_id osdtrace ./files/ubuntu/osdtrace osd- "$osd_new_dwarf"

# Test radostrace dwarf json generation
echo "Testing radostrace dwarf json generation..."
rados_new_dwarf="generated-rados-dwarf.json"
./radostrace -j $rados_new_dwarf
compare_by_build_id radostrace ./files/ubuntu/radostrace "" "$rados_new_dwarf"

echo "All dwarf json comparisons passed successfully!"
