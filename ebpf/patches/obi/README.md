# OBI patches

Patches here are applied in lexical order (`NNN-description.patch`) on top of the OBI
tag pinned by `ARG OBI_VERSION` / `OBI_REVISION` in `ebpf/Dockerfile`. The build and
`obi-patch-ci.yml` tolerate an empty directory.

Currently contains patches:

* 008-never-inject-after-http-upgrade.patch
  Prevent OBI from injecting after HTTP upgrade (e.g. WebSocket) requests, which
  would break the connection.
