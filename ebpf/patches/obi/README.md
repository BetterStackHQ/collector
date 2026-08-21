# OBI patches

Patches here are applied in lexical order (`NNN-description.patch`) on top of the OBI
tag pinned by `ARG OBI_VERSION` / `OBI_REVISION` in `ebpf/Dockerfile`. The build and
`obi-patch-ci.yml` tolerate an empty directory.

Currently empty: patches 001–005 were upstreamed in OBI v0.11.0; 006 and 007 in
v0.12.1 (open-telemetry/opentelemetry-ebpf-instrumentation#3076, #3059).
