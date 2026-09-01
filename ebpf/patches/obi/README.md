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
* 012-discovery-scoped-sockhash.patch
  Make discovery exclusions real at the socket layer. Upstream puts *every*
  outgoing TCP socket in the instrumented cgroup into the `sock_dir` sockhash,
  which is not passive observation: `sock_hash_update` runs `sk_psock_init` ->
  `tcp_bpf_update_proto` and replaces the socket's `sk_prot` with the tcp_bpf
  one. Those paths have now stalled unrelated workloads three times (a GitHub
  runner's log stream, tailscaled's control-channel long poll; forensics in
  T-20708). After this patch a socket is enrolled only if the process that
  opened it passed `valid_pid`.

  Why the enrolling callback could not just test `valid_pid` itself: it does
  not run in the owner's context, and on the supported kernel floor it cannot
  even ask. `BPF_SOCK_OPS_ACTIVE_ESTABLISHED_CB` is raised by
  `tcp_finish_connect` -> `tcp_init_transfer` (net/ipv4/tcp_input.c:6113), i.e.
  while the SYN-ACK is processed — normally NET_RX softirq on whichever CPU
  took the packet, so the current task is the interrupted one, or 0 for the
  idle task. Deciding discovery there would deny instrumented processes at
  random. `BPF_SOCK_OPS_PASSIVE_ESTABLISHED_CB` is further removed still: it
  fires for a child socket no task has returned from `accept()` yet. And
  `bpf_get_current_pid_tgid()` reaches `BPF_PROG_TYPE_SOCK_OPS` only through
  `bpf_base_func_proto()`, which did not offer it until v6.10 (Yonghong Song,
  "bpf: Allow bpf_get_[ns_]current_pid_tgid() in all program types"); an
  earlier draft of this patch used it and CI caught the consequence on
  ubuntu-22.04 — `unknown func bpf_get_current_pid_tgid#14`, injector not
  loaded.

  So the decision is read from where OBI already takes it correctly.
  `obi_kprobe_tcp_connect` (bpf/generictracer/k_tracer.c) runs at the first
  instruction of `tcp_connect()`, reached only through `sk_prot->connect` from
  `connect(2)` — or `tcp_sendmsg_fastopen()` for TFO — so the current task is by
  construction the process dialling. It already tests `valid_pid()` and, only
  then, records the connection in the `sock_pids` LRU keyed by the sorted
  `connection_info_t`. `bpf_sock_ops_active_est_cb` now looks that key up and
  enrolls only on a hit. The source port is final before `tcp_connect()` runs
  (`inet_hash_connect()` precedes it), so the entry exists and the key is
  stable by the time the established callback fires. The two key derivations
  agree by construction and OBI already relies on that in the other direction:
  `bpf_sock_ops_parse_hdr_cb` writes `incoming_trace_map` with
  `get_connection_info_ops()` + `sort_connection_info()`, and
  `find_trace_for_server_request()` reads it with a key built from
  `parse_sock_info()`.

  Nothing is attached that was not attached before, no new BPF program, no new
  map on the sockops side, and the only helper this adds to any program is
  `bpf_map_lookup_elem`, which has been in the unconditional part of
  `bpf_base_func_proto()` since sockmaps existed. The passive path is untouched,
  so inbound TCP-option parsing on server sockets behaves exactly as before.

  Prevention rather than eviction, because eviction is not available. Removing
  a socket from a sockhash means `bpf_map_delete_elem`, and since v6.10 the
  verifier only permits that for the program types in `may_update_sockmap()` —
  kernel commit 98e948fb60d4 ("bpf: Allow delete from sockmap/sockhash only if
  update is allowed"), which folded delete into the update allow-list after
  syzkaller hit the lock inversion of ff9105993240. `BPF_PROG_TYPE_SK_MSG` is
  not on that list, so `obi_packet_extender` — the one program that always runs
  in the sender's task context — cannot evict the socket it was called for; the
  program fails to load outright with `cannot pass map_type 18 into func
  bpf_map_delete_elem`, which would silently disable the injector. (That was
  measured, not assumed: the eviction design was built and run first.) Not
  enrolling is also strictly better than evicting: there is no window at all,
  rather than "off the tcp_bpf path after the first egress message".

  Exposure window: none for sockets opened while OBI is attached. A socket
  whose `connect()` predates OBI, or predates the discovery of its process, has
  no `sock_pids` entry and is simply never enrolled — losing propagation, never
  corrupting. The residual fail-open is an excluded process reusing a full
  4-tuple while the previous owner's LRU entry is still live, which lands on
  today's behaviour for that one socket. The `AllowPID` backfill is what
  recovers pre-existing connections, and it is scoped the same way: `iter/tcp`
  walks an entire network namespace and `struct sock` records no owner, so
  `AllowPID` now publishes the discovered pid's own socket inodes — read from
  its `/proc/<pid>/fd` links, matched in BPF against
  `sk->sk_socket->file->f_inode->i_ino` — into `iter_allowed_socks` for the
  duration of the walk. That also makes the walk per-pid rather than per-netns,
  since the allow-set is per-pid.

  Verifier cost: the whole sk_msg chain is byte-identical to 011
  (`obi_packet_extender` stays at 851 instructions, every tail-called program
  unchanged); `obi_sockmap_tracker` goes 1801 -> 1881 and `obi_sk_iter_tcp`
  428 -> 468.

  `ebpf/tests/egress-integrity` grows a `sockhash-scoping` scenario that proves
  it with a control: a second copy of the harness binary, at a path discovery
  does not match and reparented onto init (`valid_pid` deliberately inherits
  from the parent, so a direct child would be instrumented and rightly so),
  connects and reports its socket cookie before sending. `sock_dir` is then
  read through `bpf(2)` and must contain the harness's own socket and not the
  bystander's, both at establishment and after the bystander's one request —
  which must also arrive byte-identical and without a Traceparent, while the
  harness's identical request gets one.
