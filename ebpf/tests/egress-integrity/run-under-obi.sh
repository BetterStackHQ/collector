#!/usr/bin/env bash
set -euo pipefail

obi=$1
payload=$2
config=$3
obi_log=/tmp/obi.log
payload_log=/tmp/egress-integrity.log
start_file=/tmp/egress-integrity.start
obi_pid=
payload_pid=

cleanup() {
  status=$?
  set +e
  [ -n "$payload_pid" ] && kill "$payload_pid" 2>/dev/null
  [ -n "$obi_pid" ] && kill "$obi_pid" 2>/dev/null
  sleep 1
  [ -n "$payload_pid" ] && kill -9 "$payload_pid" 2>/dev/null
  [ -n "$obi_pid" ] && kill -9 "$obi_pid" 2>/dev/null
  if [ "$status" -ne 0 ]; then
    echo "::group::OBI log"
    cat "$obi_log"
    echo "::endgroup::"
    echo "::group::egress-integrity log"
    cat "$payload_log"
    echo "::endgroup::"
    echo "::group::container dmesg tail"
    dmesg 2>&1 | tail -n 100
    echo "::endgroup::"
  fi
  exit "$status"
}
trap cleanup EXIT

# A private cgroup namespace exposes the container cgroup as hierarchy root.
# OBI attaches sock_ops to this root, so it cannot convert host runner sockets.
grep -qx '0::/' /proc/1/cgroup
test -r /sys/kernel/btf/vmlinux
mkdir -p /sys/fs/bpf
if ! grep -q ' /sys/fs/bpf bpf ' /proc/mounts; then
  mount -t bpf bpf /sys/fs/bpf
fi
# OBI's FIONREAD compensation attaches syscall tracepoints; without tracefs it
# fails and OBI then disables context propagation entirely, which the
# positive-control scenario (rightly) reports as zero Traceparents.
if ! grep -q ' /sys/kernel/tracing tracefs ' /proc/mounts; then
  mount -t tracefs tracefs /sys/kernel/tracing
fi

rm -f "$start_file"
"$obi" -config "$config" >"$obi_log" 2>&1 &
obi_pid=$!
timeout --signal=TERM --kill-after=10s 150s \
  "$payload" -start-file "$start_file" >"$payload_log" 2>&1 &
payload_pid=$!

ready=
for _ in {1..60}; do
  if grep -q "tpinjector started" "$obi_log"; then
    ready=1
    break
  fi
  if ! kill -0 "$obi_pid" 2>/dev/null; then
    echo "OBI exited before tpinjector readiness"
    exit 1
  fi
  sleep 1
done
if [ -z "$ready" ]; then
  echo "timed out waiting for tpinjector readiness"
  exit 1
fi

# OBI logs a BPF load failure as a warning and carries on with that tracer
# disabled. If an injector program is the one that failed, every byte-integrity
# scenario below passes for the wrong reason — nothing is attached that could
# corrupt anything — so treat it as a hard failure. Typical cause: a tpinjector
# patch pushing a program past the verifier's complexity limit ("BPF program is
# too large. Processed 1000001 insn"). Scoped to the injector's own programs so
# an unrelated optional tracer failing on some kernel does not fail the run.
if grep -qE "couldn't load tracer.*Obi(PacketExtender|SockmapTracker)" "$obi_log"; then
  echo "OBI failed to load an injector program; the integrity scenarios would pass vacuously"
  grep -E "couldn't load tracer.*Obi(PacketExtender|SockmapTracker)" "$obi_log"
  exit 1
fi

touch "$start_file"
wait "$payload_pid"
cat "$payload_log"
