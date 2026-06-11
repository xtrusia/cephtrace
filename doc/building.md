# Building Cephtrace

This guide provides information about building cephtrace from source.

## Install dependencies
### Debian/Ubuntu

```bash
sudo apt-get install \
    g++ \
    clang \
    libelf-dev \
    libc6-dev \
    libc6-dev-i386 \
    libdw-dev \
    libssl-dev \
    make
```

### RHEL/CentOS/Rocky Linux/Fedora

```bash
sudo dnf config-manager --enable crb  # Only for RHEL 9/CentOS Stream 9
sudo dnf install \
    g++ \
    clang \
    elfutils-libelf-devel \
    glibc-devel \
    glibc-devel.i686 \
    elfutils-devel \
    openssl-devel \
    make
```

## Build

```bash
git clone https://github.com/taodd/cephtrace
cd cephtrace
git submodule update --init --recursive
make
```

## Kernel BTF requirement (kfstrace)

The `GEN-BTF` build step generates `src/ceph_btf_local.h` from the **ceph
kernel module** of the newest kernel installed under `/lib/modules`, using
that kernel's vmlinux BTF as the base. The build host therefore needs:

- a kernel package providing `ceph.ko` (on Ubuntu:
  `linux-modules-extra-<version>`), and
- a readable base BTF for that same kernel - one of
  `/lib/modules/<ver>/vmlinux`, `/usr/lib/debug/.../vmlinux`,
  `/boot/vmlinux-<ver>`, or `/sys/kernel/btf/vmlinux` when the installed
  kernel is also the running one.

This works in containers and CI runners as long as a matching kernel package
is installed - the kernel does not have to be running. The generated header is
CO-RE relocatable: binaries built against one kernel's `ceph.ko` run on other
kernels with BTF support (the field offsets are re-resolved at load time).
