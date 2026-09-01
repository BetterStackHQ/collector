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
* 010-default-deny-injection-gate.patch
  Invert tpinjector's HTTP/1 trust model. Upstream mutates any egress message
  whose first bytes look like a request method, which is why binary streams get
  corrupted; this makes injection opt-in instead. A new per-socket
  `sk_inject_gate` SK_STORAGE byte parks sockets permanently, checked at the top
  of `obi_packet_extender` before the existing-trace route can schedule a TCP
  option. On unparked sockets HTTP/1 injection now requires a complete request
  line — method, target, `HTTP/1.<digit>`, CRLF — in the freshly filled scratch
  buffer, and a request carrying an `Upgrade:` header parks the socket without
  being injected into. That last part is the client-side half of 008: the
  server's 101 arrives on ingress, which an egress-only sk_msg program never
  sees, so `tailscaled`'s control channel (Noise) and DERP client (binary
  frames) were unprotected. The confirmed-HTTP/2 chain is untouched, it is
  already default-deny.

  The gate's two bounded scans and the dispatch that follows them are three
  separate sk_msg programs (`k_tail_http1_request_line`,
  `k_tail_http1_upgrade`, `k_tail_http1_dispatch`). That is not decoration: the
  verifier keeps the exact loop offset each scan ends on, so a scan inlined
  ahead of other code re-verifies all of it once per possible offset. Inlined,
  `obi_packet_extender` hit the 1M complexity limit and the whole verdict
  program failed to load — which disables the injector silently rather than
  restricting it. A tail call ends the program, so each scan's fan-out reaches
  only the few instructions after it. For the same reason the request line is
  matched backwards from the message's first CRLF instead of forwards from the
  method token, whose seven possible lengths would enter the loop as seven
  states.
* 011-valid-pid-first.patch
  Check OBI's discovery filter (`valid_pid`) at the top of
  `obi_packet_extender`. Upstream checks it only on the fall-through route, so
  the existing-trace and Go-gRPC coordination routes could mutate messages of
  processes that were never selected for instrumentation.
