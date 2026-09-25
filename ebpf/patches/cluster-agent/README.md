# Cluster agent patches

These patches apply to coroot-cluster-agent v1.11.4 in both image builders.

* `001`: omit the Postgres startup `statement_timeout` parameter, which poolers can reject. The agent still uses context deadlines for its queries. Upstream has no flag or environment variable for omitting the startup parameter; `PGOPTIONS` does not override an explicit DSN parameter.
* `002`: preserve the existing database and Kubernetes collection scope. Skip the new MongoDB server-status, current-operation, profiler, replica-config and oplog scans; MySQL active-statement, lock-wait, transaction, InnoDB counter, binlog and group-replication queries; Postgres checkpoint, WAL, wraparound, table-stat and vacuum-progress queries; and the new Argo CD, CloudNativePG and Percona resource watchers. Keep Flux watchers and existing database status, replication, query and size metrics. Additional counters derived from already-collected data remain available.
* `003`: preserve a nil change-emitter interface when schema tracking is disabled. Upstream passes a typed nil pointer to database constructors, which enables schema tracking and can panic when a change is emitted.

Runtime launcher scripts set `TRACK_DATABASE_BLOAT=false`, `PROFILES_SCRAPE_INTERVAL=0s`, `COLLECT_KUBERNETES_EVENTS=false` and `KUBE_STATE_METRICS_MIN_AGE=0s`. Keep `TRACK_DATABASE_SIZES=true` for database size metrics. Only set `TRACK_DATABASE_CHANGES=false` on images with patch 003: both final images expose `CLUSTER_AGENT_VERSION` for this compatibility check. Older images must keep schema tracking enabled.

After applying the patches, run `go test -mod=readonly ./...` in the upstream checkout. The added tests check MongoDB commands and dashboard metrics, Kubernetes watcher scope, and the nil-emitter regression. Build with `CGO_ENABLED=0 GOTOOLCHAIN=local go build -mod=readonly .`.
