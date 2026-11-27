# Postgres exporter patches

These patches apply to postgres_exporter v0.18.1 in the eBPF image builder.

* `001`: read the server fingerprint (`host:port`) straight from a `postgres://` or `postgresql://` DSN. v0.18.1 turned the URL into `key='value'` text and split that text on spaces, so a password with a space made every probe fail with `malformed dsn`, and the error included the connection string. The error no longer includes it. This is the `parseFingerprint` change from upstream [#1349](https://github.com/prometheus-community/postgres_exporter/pull/1349), released in v0.21.0, without its lib/pq upgrade. Drop this patch when the image moves to v0.21.0 or newer.

After applying the patches, run `go test ./...` in the upstream checkout. Build with `CGO_ENABLED=0 GOTOOLCHAIN=local go build -mod=readonly ./cmd/postgres_exporter`.
