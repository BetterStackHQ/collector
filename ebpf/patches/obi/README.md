# OBI patches

Patches here are applied in lexical order (`NNN-description.patch`) on top of the OBI
tag pinned by `ARG OBI_VERSION` / `OBI_REVISION` in `ebpf/Dockerfile`. The build and
`obi-patch-ci.yml` tolerate an empty directory.

Currently contains patches:

* 008-never-inject-after-http-upgrade.patch
  Prevent OBI from injecting after HTTP upgrade (e.g. WebSocket) requests, which
  would break the connection.
* 009-never-inject-on-stale-msg-buffer.patch
  Only run tpinjector's HTTP request detection when fill_msg_buffers actually
  refreshed the per-CPU scratch buffer from the current message. On SSL
  connections the fill deliberately bails, so the detector would otherwise judge
  stale bytes from a previous message and could splice a Traceparent header into
  TLS ciphertext, corrupting the stream (peer-side bad_record_mac).
