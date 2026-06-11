==========
radostrace
==========

------------------------------------
trace any librados based Ceph client
------------------------------------

:Version: @VERSION@
:Date: @DATE@
:Manual section: 8


SYNOPSIS
========

| **radostrace** [-t <seconds>] [-j [filename]] [-i <filename>] [-o [filename]] [-p <pid>] [--skip-version-check] [--list] [--list-embedded] [-V] [-h]


DESCRIPTION
===========

**radostrace** can trace any librados based Ceph client, including
virtual machines with rbd backed volumes attached, rgw, cinder and glance.
DWARF data for many Ceph releases is compiled into the binary (matched by the
libceph-common ELF build-id), so covered versions - including clients running
in containers or snaps - can be traced without debug symbols or DWARF JSON
files.


OPTIONS
=======

-t, --timeout <seconds>

   Set execution timeout in seconds

-j, --export-json <file>

   Export DWARF info to JSON (default: radostrace_dwarf.json)

-i, --import-json <file>

   Import DWARF info from JSON file

-o, --output <file>

   Export events data info to CSV (default: radostrace_events.csv)

-p, --pid <pid>

   Attach uprobes only to the specified process ID (mandatory for
   container-based process tracing)

--skip-version-check

   Skip the version check when importing DWARF JSON (needed when the host and
   container package versions differ)

--list

   List client processes using libceph-common (PID, container status,
   traceability, Ceph version) and exit

--list-embedded

   List the Ceph versions with DWARF data compiled into this binary and exit

-V, --version

   Print version information and exit

-h, --help

   Show this help message


AVAILABILITY
============

**radostrace** is part of Cephtrace, a project that delivers various eBPF based ceph tracing tools.
These tools can be used to trace different Ceph components dynamically, without the need to restart
or reconfigure any of the Ceph related services. See https://github.com/taodd/cephtrace/ for more
information.


BUGS
====

Report issues at https://github.com/taodd/cephtrace/issues


SEE ALSO
========

osdtrace (8)
