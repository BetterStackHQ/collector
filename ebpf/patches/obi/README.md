# OBI patches

Patches here are applied in lexical order (`NNN-description.patch`) on top of the OBI
tag pinned by `ARG OBI_VERSION` / `OBI_REVISION` in `ebpf/Dockerfile`. The build and
`obi-patch-ci.yml` tolerate an empty directory.

## v0.14.0 rebase

Pinned to `13d9b0c3f600a060bd78820a63ebec882b10757e`, using
`obi-generator:0.2.16` (the v0.14.0 Makefile default). The generator's multi-arch
digest is pinned in `ebpf/Dockerfile`.

| Patch | Decision | Upstream comparison |
| --- | --- | --- |
| 008 | Keep unchanged | No HTTP/1 upgrade parking upstream. |
| 009 | Already removed | [#3257](https://github.com/open-telemetry/opentelemetry-ebpf-instrumentation/pull/3257) gates both HTTP detector paths on a fresh fill. [#3298](https://github.com/open-telemetry/opentelemetry-ebpf-instrumentation/pull/3298) bounds copies by the mapped window; [#3304](https://github.com/open-telemetry/opentelemetry-ebpf-instrumentation/pull/3304) invalidates failed fills for the other readers. |
| 010 | Restack | Preserve upstream buffer, socket-cookie, and HTTP/2 ownership changes while retaining the default-deny injection gate and copied-window scan bounds. |
| 011 | Keep unchanged | Upstream still checks discovery after the existing-trace and Go-gRPC routes. |
| 012 | Restack | Preserve upstream socket-cookie handling while retaining discovery-scoped enrollment and inode-scoped backfill. |
| 013 | Restack | Adapt to the `DynamicSelector` rename and new matcher test callers. Explicit exclusions still take precedence over admitted parents. |
| 014 | Remove | [#3514](https://github.com/open-telemetry/opentelemetry-ebpf-instrumentation/pull/3514) sizes the environment map with `validEnvCount()`, ignoring empty entries left by `setproctitle`. |
| 015 | Restack | Preserve upstream socket-cookie includes and tracer detach lifecycle state while retaining injector-owned Go PID admission and connect tracking. |
| 016 | New | Keeps OBI's own cgroup out of the traces. Upstream candidate; no upstream equivalent yet. |
| 017 | New | Names MongoDB spans from cut-short captures and adds `db.query.text`. Upstream candidate; no upstream equivalent yet. |
| 018 | New | Accepts the whole int32 range of MongoDB request ids. Upstream candidate; no upstream equivalent yet. |

Do not restore 009 ahead of 010: the upstream fill invalidation and mapped-window
bounds are part of the base now. A successful fill can copy less than `msg->size`
after a failed pull; `http1_buf_size` carries that copied length across the gate's
tail calls so they cannot classify stale bytes beyond it.

## Go discovery admission correction

Patch 015 corrects the admission assumptions in 011 and 012. Go-specific
tracing registers `PIDTypeGo` in userspace; the generic tracer publishes only
`PIDTypeKProbes` to `valid_pids` and only records its own connections in
`sock_pids`. Requiring those maps therefore suppresses socket-level propagation
for Go-specific tracing, including when no generic tracer is loaded.

The injector now publishes its own namespace/PID allow-list from the common
tracer's `AllowPID` and retracts it from `BlockPID`. Explicit exclusions are
checked before admission on every send. Non-excluded workers still inherit
from a discovered parent in the same PID namespace. The generic tracer's
filter remains separate so admitting Go cannot enable duplicate generic spans.

A required injector `tcp_connect` kprobe records socket admission in the dialing
task. The established sockops callback consumes that decision by socket pointer,
without depending on generic tracing or confusing identical network tuples.
Pre-existing sockets retain 012's per-process inode-scoped backfill.

The matcher also retries deferred exclusions once per second, independently of
new process events. Otherwise exclusions discovered before BPF maps load can
remain unpublished indefinitely on a quiet host.

Go HTTP/1 header injection also retracts its pending socket context using
sorted ports, matching publication. With a higher server port, the original
unsorted deletion left the socket injector armed and produced two headers.

The privileged socket tests cover HTTP headers, TCP options, and Go/gRPC with
Go and generic admission, removal, explicit denials, parent inheritance, denied
children, and PID filtering disabled. Egress-integrity CI runs separately with
Go-specific tracing enabled and disabled, including a real Go HTTP client in both port orderings.

## Current patches

* 008-never-inject-after-http-upgrade.patch
  Prevent OBI from injecting after HTTP upgrade (e.g. WebSocket) requests, which
  would break the connection.
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

  `Upgrade: h2c` is the exception and does not park. h2c is HTTP/2, not a
  tunnel, and the request asking for it is still plain HTTP/1.1, so it is
  injected into. Parking it only cost propagation, and that hit Java's
  `HttpClient` hardest: with its default version it asks for h2c on every
  cleartext request, servers refuse, and the keep-alive connection stayed
  HTTP/1 with no traceparent on any request. Whether the server accepted is
  still unknowable from egress, and after a 101 the injector's HTTP/2
  detection can miss a preface split across sends while a DATA payload opens
  with a complete request line. So the request moves the socket to an h2c gate
  state instead, in which only a request that itself asks for h2c is mutated.
  Everything else passes untouched, the HTTP/2 chain included, and drops any
  TCP option an earlier h2c request left pending on the socket (parking does
  the same). So an accepted h2c connection keeps the no-propagation it had when
  the request parked it, and clients that ask once and carry on in HTTP/1.1
  after a refusal lose propagation on the later requests. The first Upgrade
  field must be exactly `h2c` followed by CRLF: a list such as
  `h2c, websocket`, or a field cut off at the end of the copied window, parks.
  A later Upgrade field is not read, since scanning on blew the verifier's 1M
  limit; a request offering `h2c` and then a tunnel in a second field lands in
  the h2c state, where tunnel bytes stay untouched unless one message is itself
  a complete HTTP/1 request asking for h2c. The egress-integrity
  `declined-h2c`, `accepted-h2c`, `accepted-h2c-split` and
  `h2c-and-tunnel-upgrade` scenarios cover these.

  Parking stops injection, not observation. A parked socket, or one that left
  HTTP/1 through a 101, still gets the read-only `msg_buffers` fill before the
  program returns: once a socket is in the sockhash the `tcp_sendmsg` kprobe
  cannot read the payload itself and the generic tracer parses that copy
  instead. Returning before the fill dropped the client span of every later
  request on the connection, for example after a refused WebSocket upgrade.
  The egress-integrity `declined-upgrade` scenario covers this.

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
  Its early gate is retained; 015 replaces its generic-only PID filter.
  Check OBI's discovery filter (`valid_pid`) at the top of
  `obi_packet_extender`. Upstream checks it only on the fall-through route, so
  the existing-trace and Go-gRPC coordination routes could mutate messages of
  processes that were never selected for instrumentation.
* 012-discovery-scoped-sockhash.patch
  Its inode-scoped backfill is retained. 015 replaces the original
  `sock_pids` enrollment dependency described below with injector-owned tracking.
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
* 013-deny-before-parent-fallback.patch
  Make discovery's exclusions real in the kernel. `valid_pid()` (bpf/pid/pid.h)
  looks the calling process up in the allow bitmap and, on a miss, retries with
  its namespaced parent pid. That fallback is deliberate — it is how OBI follows
  an instrumented process into its workers, and 012's scenario depends on it
  staying intact — but userspace only ever *declined to add* an excluded process
  to the allow-list; nothing ever told BPF what had been excluded. So with
  `open_ports` discovery, where pid 1 is routinely instrumented and every
  process on the machine descends from pid 1, `exclude_instrument` meant nothing
  below the userspace pipeline. Observed live before this patch: an excluded
  `tailscaled` enrolled 2/2 into the sockhash, because systemd was discovered
  through open_ports.

  Semantics. A new `denied_pids` hash, keyed exactly like the allow-list
  (`pid_data_t` = namespaced pid + pid-namespace inode), is consulted in
  `valid_pid` ahead of both the allow bitmap and the parent fallback. Only the
  caller's *own* identity is looked up: a denied parent does not taint its
  children, because a supervisor the user excluded may legitimately fork the
  workload they asked for, and that workload has its own allow-list entry.
  Allowed processes and their non-excluded children are unaffected — the
  fork-following fallback is untouched, and the per-event hot path is unchanged
  because a `pid_cache` hit still returns before any of this.

  An exact hash rather than a second copy of the bitmap: `valid_pids` hashes
  (ns, pid) into 192053 bits with no collision resolution, which upstream can
  afford because a collision there fails *open* and merely lets an extra process
  through. The same collision in a deny structure fails closed and would
  silently stop instrumenting a process the user did select.

  Who publishes it. The criteria matcher (`filterCreated` in
  pkg/appolly/discover/matcher.go) is the only component that evaluates
  `exclude_instrument`, and the only one that ever sees the processes it drops:
  an excluded process never becomes an Instrumentable, so it never reaches the
  attacher and `BlockPID` could not carry this. It publishes when a process
  matches an exclusion and retracts when the same pid matches the criteria
  instead; `filterDeleted` retracts on exit, because pids are reused and a
  denial that outlived its process would silently stop instrumenting the next
  owner. The keys are every NSpid level of the process under its pid-namespace
  inode, exactly as `PIDsFilter.addPID()` records the allow side, so the two
  sides agree whichever level the kernel derives. The map is reached by name
  through `EBPFEventContext.EBPFMaps` — the agent-wide store of
  OBI_PIN_INTERNAL maps that `ResolveMaps()` fills — which is one map object
  shared by every collection that includes pid.h, with a lifetime independent of
  any single ProcessTracer.

  Each denial also evicts the pid from `pid_cache`, and that is not
  housekeeping. `pid_cache` is a positive memo of a `valid_pid` pass, consulted
  before anything else; an excluded process that made egress before discovery
  reached it was accepted on its parent's ticket and cached, so publishing the
  denial alone would change nothing for that process for as long as the entry
  lives. The eviction is what makes the cheap check order safe.

  Residual staleness, all of it fail-open, and none of it removable without
  matching executables inside BPF:
  - Discovery lag. The watcher polls every `discovery.poll_interval` (5s by
    default; its only BPF accelerator is a `sys_bind` kprobe that forces a port
    refetch) and holds back processes younger than `discovery.min_process_age`
    (5s), so a just-`exec`ed excluded process still passes on an ancestor's
    ticket until it is seen. Measured in the harness: 4.3s for a process that
    predates OBI, 10.1s for one started mid-run.
  - Pid reuse within one poll interval. If an excluded pid dies and the number
    is taken by another process before the next poll, the watcher reports
    neither the exit nor the creation and the denial stands for the new owner.
    That direction loses instrumentation rather than corrupting bytes, the
    reverse case (an allowed pid reused by an excluded process) is upstream's
    existing behaviour, and the retraction on any later match closes it as soon
    as the pipeline sees the pid again.
  - A process that exits between the poll and the publish has no
    `/proc/<pid>/{status,ns/pid}` left to read, so nothing is published — and it
    generates no more egress either.
  - A full `denied_pids` (3001 entries, sized like `valid_pids`) refuses new
    denials and logs a warning. It is a plain hash, not an LRU, so an existing
    denial can never quietly lapse.

  Kernel floor: the only thing new anywhere is one `bpf_map_lookup_elem` on a
  `BPF_MAP_TYPE_HASH`. The helper is in the unconditional part of
  `bpf_base_func_proto()` and the map type is as old as BPF maps, so every
  program type that already compiles `valid_pid` keeps loading; nothing here is
  younger than the 5.15 support floor. No new program, no new attachment, no new
  helper, and the per-program map count is unchanged in kind (one more shared
  map, far below MAX_USED_MAPS). The programs that consult `valid_pid` are
  generictracer's kprobes/uprobes and tpinjector's sk_msg entry; the Go uprobes
  are scoped by being attached per discovered executable and their objects come
  out byte-identical.

  Verifier cost vs 012: `obi_packet_extender` 851 -> 860, every tail-called
  sk_msg program unchanged, `obi_sockmap_tracker` and `obi_sk_iter_tcp`
  unchanged. generictracer's programs move by +8..+82 where `valid_pid` is
  inlined (its largest, `obi_kprobe_tcp_close`, 29506 -> 29516) and a handful
  shrink by up to 139 as LLVM re-lays them out; the collection's total falls by
  58 instructions.

  `ebpf/tests/egress-integrity` grows a `deny-child` scenario, with a control on
  both sides. The instrumented harness spawns a *direct* child — no reparenting,
  unlike 012's bystander, so its parent is genuinely allowed — running a copy of
  the payload at `/tmp/deny-child`, which run-under-obi.sh excludes in the OBI
  config it composes. The child announces its pid and waits before opening any
  socket, because `valid_pid` is consulted at `connect()` time in
  `obi_kprobe_tcp_connect`: it is released only once its exclusion is visible in
  `denied_pids`, so the scenario waits on an observable rather than a sleep.
  Then its one HTTP/1.1 request must arrive byte-identical and without a
  Traceparent, its socket must be absent from `sock_dir` both at establishment
  and after that request, while the parent's identical request in the same
  scenario gets a Traceparent and the parent's socket is enrolled — and the
  parent must not itself be in `denied_pids`. run-under-obi.sh also starts an
  excluded process *before* OBI, which is the production shape of the bug and
  the only way to exercise the publisher's deferral, since the first discovery
  poll runs before any BPF collection exists; its exclusion must reach the map
  too. Against pristine+008..012 the scenario reports all four differences from
  one run: the child's socket enrolled in `sock_dir`, one Traceparent on its
  request, 61 bytes arriving as 131, and the socket still enrolled afterwards.
* 015-discovery-admission-for-go.patch
  Restore socket-level propagation for Go-specific tracing while retaining
  discovery exclusions. Adds injector-owned PID admission and connect tracking;
  see the correction above. Also fixes sorted-key cleanup in the Go HTTP/1 probes. The generic PID filter
  remains unchanged.
* 016-exclude-own-cgroup.patch
  Keep the instrumentation's own container out of the traces. OBI runs in a
  container next to the collector's probes: the cluster agent scraping Redis
  (`INFO`, `SLOWLOG`, `CONFIG`) and Memcached (`STATS`), the metric exporters,
  the Node inspector session OBI itself opens on port 9229. None of that is the
  application's traffic, yet it was reported twice over: as client spans of
  whichever probe matched `open_ports` discovery (`mysqld_exporter` listens, so
  it became a service), and as root server spans of every instrumented Redis,
  Memcached or Node process the probes talked to. Path-based
  `exclude_instrument` entries only ever addressed the first half, one binary
  at a time, and can do nothing about the second: the server is legitimately
  instrumented, and nothing in its span says who the client was.

  A new `discovery.exclude_own_cgroup` option (`OTEL_EBPF_EXCLUDE_OWN_CGROUP`,
  default on) resolves the cgroup v2 node OBI runs in, which is its container
  when it has one, and uses it on both sides:

  - Discovery excludes every process in that cgroup ahead of any criteria, and
    publishes the exclusion to `denied_pids` like any other, so neither the
    Go uprobes nor the kernel's parent fallback instrument them.
  - `obi_kprobe_tcp_connect` runs in the dialling task, so it can ask
    `bpf_get_current_cgroup_id()`; a connect from OBI's cgroup is recorded in
    a new `own_cgroup_conns` LRU and the kprobe returns before the pid filter.
    `obi_handle_buf_with_args`, which every protocol parser is reached
    through, drops any buffer on a recorded connection, so no request is ever
    started on it and nothing later can finish one. Both ends' `tcp_close`
    retract the entry.
  - The generic tracer's existing `iter/tcp` iterator, which already walks
    each discovered network namespace once for listening ports, also records
    the established sockets whose `sk_cgrp_data` names OBI's cgroup: the
    connections the cluster agent's pool already held when OBI loaded, which
    the connect kprobe never saw. An accepted socket inherits its listener's
    cgroup rather than its peer's, so sockets whose local port is one of the
    namespace's listening ports (visited earlier in the same walk) are left
    alone: a server inside OBI's container does not claim the application
    clients that talk to it. The tracer also runs the iterator in OBI's own
    network namespace at start, since discovery may select nothing there.

  The key is the sorted tuple with the server address blanked. Destination
  NAT on a published container port or a Kubernetes service IP rewrites that
  address between the client's connect and the server's accept, while the
  client's address and port and the server port survive, and the sort looks at
  ports only, so both ends spell the key the same way. What still defeats it
  fails open, i.e. the span is kept: a port-remapping NAT, source NAT, a
  userland proxy terminating the connection (Docker's `docker-proxy` serving
  a port published on 127.0.0.1), and a server on another host, whose kernel
  never saw the client. A collision with an unrelated connection needs the
  same client address and port towards the same server port on a different
  server at the same time; its cost is one connection's server spans until
  either end closes. The key carries no network namespace, so the same
  collision can also come from another container reusing the same loopback
  or private address and ephemeral port at the same moment.

  Resolving the cgroup is the subtle part. `/proc/self/cgroup` renders the
  path relative to the reader's cgroup namespace, and the collector-host
  container runs in a private one with the host's `/sys/fs/cgroup`
  bind-mounted, so it reads `0::/` for a cgroup two levels down the mount.
  `procs.OwnCgroup` therefore treats the path as a first guess and otherwise
  walks the hierarchy for the directory whose `cgroup.procs` lists its pid;
  the directory's inode is the id BPF compares against. Membership of other
  processes is a string comparison of their `0::` line against OBI's, read by
  the same reader, which is exact in both the private-namespace and the
  host-namespace case.

  The feature turns itself off, with an info log, wherever that cgroup would
  not be the container. The root of the hierarchy (inode 1) is shared by every
  process on a host without cgroup v2 containers. A hybrid host, which mounts
  the v1 controllers next to the unified hierarchy, is only trusted when
  OBI's v1 paths equal its unified path, which is what a systemd-driven
  runtime produces by creating its scope in every hierarchy. Docker's
  cgroupfs driver, its default on such hosts, populates only the v1
  controllers and leaves every container's processes in the unified cgroup
  inherited from the runtime's service, where "own cgroup" would mean every
  container on the host; and behind a private cgroup namespace on a hybrid
  host every path reads `/`, so nothing can be compared. Both stay off. A
  process that the criteria select but the cgroup excludes is reported once at
  info level, so an agent that shares its cgroup with the application it was
  meant to instrument does not go quiet without a word. The dynamic (API)
  selector does not apply the exclusion in userspace, while the BPF constant
  still does; a process in OBI's own cgroup selected that way is not a
  supported case.

  Kernel floor: `bpf_get_current_cgroup_id()` has been available to kprobes
  since 4.18 and has equalled the cgroup directory's inode since 5.5, well
  below the 5.15 support floor. The iterator reads `sock_cgroup_data.cgroup`
  behind `bpf_core_field_exists`, so a kernel whose `struct sock_cgroup_data`
  still packs that pointer into a word (before 5.15's explicit layout) loads
  and merely skips the backfill. The Go tracer's server spans are untouched
  by this patch: a Go server scraped by the collector still reports the
  scrape.

  The egress-integrity harness now starts OBI in a child cgroup of the
  container's root, as a runtime would, because everything in that container
  otherwise shares one cgroup and the payload would be excluded along with
  OBI. Its `own-cgroup` scenario runs the payload binary, which discovery
  matches, from that cgroup: it waits for its exclusion to reach
  `denied_pids`, sends one request to the instrumented payload, which must
  arrive byte-identical without a Traceparent, and run-under-obi.sh then
  requires OBI to have printed a server span for the control request the
  payload sends itself and none for the subject's. The iterator's half is
  covered by connections older than OBI: before OBI starts, the runner
  launches the payload as a parent whose children connect to it from OBI's
  cgroup and from the root cgroup, and a third child listens from OBI's
  cgroup with the parent connected to it. Once the payload proper is done
  each connection carries one request, and OBI must have printed a server
  span for the root child's, none for the one from its cgroup, and a client
  span for the parent's request to the listener in its cgroup.
* 017-mongo-partial-capture.patch
  Name MongoDB spans from what the capture actually holds. The generic TCP
  tracer hands the userspace parser the first `k_tcp_max_len` (256) bytes of
  a request and `k_tcp_res_len` (128) of its reply unless `buffer_sizes.tcp`
  raises them, and the OP_MSG parser used `bson.Unmarshal`, which refuses a
  document whose declared length exceeds the bytes it is given, and failed a
  message outright when a kind-1 document sequence ran past the capture. A
  cut request body therefore became a span named `*` with no collection, a
  cut reply body (`errMongoNoResponseBody`) dropped the span altogether, and
  an insert whose documents travel in a kind-1 section (pymongo, Java, C#)
  was lost whenever they did not fit. Which of these a driver hits depends on
  how it reads and writes: pymongo reads the 16-byte reply header first,
  which the parser already treats as "reply seen, assume success", so its
  finds were named; the Node driver reads the whole reply at once, so every
  find whose reply held more than 128 bytes vanished, and a find request long
  enough (a regex filter plus session and read-preference fields) came out as
  `*`.

  The patch adds `bsonPrefix`, a walk over a BSON document prefix that keeps
  every complete top-level element, descends into embedded documents and
  arrays the same way, and reports that it ran out of bytes. It replaces the
  empty document for cut and otherwise unreadable bodies. The command name and
  collection are the first element of a request, so they are almost always
  present; `$db` near the end is kept when it is. A kind-1 section the
  capture cuts ends the sections instead of failing the message; the body
  before it is all the span needs. A reply cut before its `ok` field, which
  is last, is treated as a success unless an `errmsg` is visible, like the
  header-only path; one cut after `ok: 0` is a failure that says its message
  was not captured; a complete reply without `ok` is still rejected, as is a
  reply whose first section is not a body. `getMore` takes its collection
  from the `collection` field, a database-level `{aggregate: 1}` keeps its
  name without a collection, and pymongo's lowercase `ismaster` is a
  heartbeat like `isMaster`. Numeric `ok` fields of any width are accepted.
  The walk bounds nesting at 32 levels and never splits a character when
  capping the text.

  Spans also gain `db.query.text`: the command's shape with every value
  replaced by `?`, the collection a collection command names kept (the first
  value of any other command, a user name for `createUser` say, is not),
  session and routing fields (`lsid`, `$clusterTime`, `$db`,
  `$readPreference`, transaction and API fields) left out, arrays shown by
  their first element, capped at 2048 bytes and ending in `…` when the
  capture cut the command. Field names are kept as SQL identifiers are, which
  includes names an application derives from data. The traces exporter emits
  it for MongoDB spans when `db.query.text` is selected, as it already does
  for SQL. A cut-short command still yields its full shape up to the cut.

  Server-side MongoDB spans (the `mongod` process reporting requests) remain
  unsupported, as before. `buffer_sizes.tcp` in the runtime configuration
  still decides how much of a command the text can show; 256 bytes cover a
  typical find or insert's shape but not a long aggregation pipeline. The
  unit tests use messages captured from the mongodb npm 6.12 and pymongo 4.15
  drivers, cut at the capture sizes, and a fuzz target covers the walk.
* 018-mongo-request-ids.patch
  Accept MongoDB request ids from the whole int32 range. The OP_MSG header
  check rejected any message whose `requestID` or `responseTo` was negative,
  as if the wire protocol promised them positive; it only promises an int32.
  pymongo draws its ids at random from that range, so half of its requests
  failed the check and lost their span, replies included, whatever the
  command. The other drivers count their ids up from a small number, so
  this only ever affected pymongo; what they share with it is 017's cut
  document sequence, which is where pymongo, the Java, C#, Ruby and PHP
  drivers carry an insert's documents, and that is why inserts from all of
  them were mostly missing while Node's, with documents in the body, were
  not. The pairing of a reply with its request already keys on the full
  int32, so nothing else changes; the fuzz invariant that encoded the old
  rule is updated, and a test uses a pymongo find captured with a negative
  id.
