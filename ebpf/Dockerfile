ARG EBPF_AGENT_VERSION=0.1.4
FROM ghcr.io/betterstackhq/ebpf-agent:${EBPF_AGENT_VERSION} AS ebpf-agent-source

# Build Cluster Agent from source with patches
FROM debian:13.5 AS cluster-agent-builder
RUN apt-get update && apt-get install -y curl git
ARG GO_VERSION=1.24.9
RUN curl -fsSL https://go.dev/dl/go${GO_VERSION}.linux-$(dpkg --print-architecture).tar.gz -o go.tar.gz && \
    tar -C /usr/local -xzf go.tar.gz && rm go.tar.gz
ENV PATH="/usr/local/go/bin:${PATH}"
ARG CLUSTER_AGENT_VERSION=v1.6.1
RUN git clone --depth 1 --branch ${CLUSTER_AGENT_VERSION} \
    https://github.com/coroot/coroot-cluster-agent.git /tmp/cluster-agent
WORKDIR /tmp/cluster-agent
COPY ebpf/patches/cluster-agent/*.patch ./
RUN git apply *.patch
RUN CGO_ENABLED=0 go build -mod=readonly \
    -o /usr/bin/coroot-cluster-agent .

# Add node exporter to the image
FROM prom/node-exporter:v1.10.2 AS node-exporter-source

# Add postgres exporter to the image
FROM prometheuscommunity/postgres-exporter:v0.18.1 AS postgres-exporter

# Add kafka exporter to the image
FROM danielqsj/kafka-exporter:v1.9.0 AS kafka-exporter

# Add elasticsearch exporter to the image
FROM quay.io/prometheuscommunity/elasticsearch-exporter:v1.11.0 AS elasticsearch-exporter

# Add pgbouncer exporter to the image
FROM prometheuscommunity/pgbouncer-exporter:v0.12.0 AS pgbouncer-exporter

# Build OBI from source with patches
FROM ghcr.io/open-telemetry/obi-generator:0.2.15@sha256:9cbb1b567377d5779b04e6bcdb87431c77a19e797b4630eba30f5417de96ea33 AS obi-builder
RUN apk add --no-cache bash git make
ARG TARGETARCH
ARG CUSTOMIZATION_TAG="betterstack"
ARG OBI_VERSION="v0.10.0"
ARG OBI_REVISION="4a4dc7ecdb2aeba6791d02fbebb5048c0f0c1261"
RUN git clone --depth 1 --branch ${OBI_VERSION} \
    https://github.com/open-telemetry/opentelemetry-ebpf-instrumentation.git /tmp/obi && \
    test "$(git -C /tmp/obi rev-parse HEAD)" = "${OBI_REVISION}"
WORKDIR /tmp/obi
RUN --mount=type=cache,target=/go/pkg/mod go mod download
COPY ebpf/patches/obi/*.patch /tmp/obi-patches/
RUN git apply /tmp/obi-patches/*.patch
ENV GOARCH=${TARGETARCH}
RUN --mount=type=cache,target=/root/.cache/go-build \
    --mount=type=cache,target=/go/pkg/mod \
    /generate.sh && \
    make compile RELEASE_VERSION="${OBI_VERSION}-${CUSTOMIZATION_TAG}"

# Final stage
FROM debian:13.5-slim

# Install supervisor, ca-certificates, curl, procps, and Ruby
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        supervisor \
        ca-certificates \
        curl \
        procps \
        ruby \
        ruby-json \
        jq && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Download AWS RDS CA bundle and update system CA store
RUN curl -sS https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem \
    -o /usr/local/share/ca-certificates/aws-rds.crt \
    && update-ca-certificates

# Create necessary directories
RUN mkdir -p /etc/supervisor/conf.d /var/log/supervisor /enrichment /bootstrap

# Copy OBI binary and license files
COPY --from=obi-builder --chmod=755 /tmp/obi/bin/obi /usr/local/bin/ebpf-instrument
COPY --from=obi-builder /tmp/obi/LICENSE /tmp/obi/NOTICE /usr/share/doc/ebpf-instrument/

# Copy Better Stack eBPF Agent
COPY --from=ebpf-agent-source --chmod=755 /ebpf-agent /usr/local/bin/ebpf-agent

# Copy Cluster Agent
COPY --from=cluster-agent-builder --chmod=755 /usr/bin/coroot-cluster-agent /usr/local/bin/cluster-agent

# Copy Node exporter
COPY --from=node-exporter-source --chmod=755 /bin/node_exporter /usr/local/bin/node_exporter

# Copy Postgres exporter
COPY --from=postgres-exporter --chmod=755 /bin/postgres_exporter /usr/local/bin/postgres_exporter

# Copy Kafka exporter
COPY --from=kafka-exporter --chmod=755 /bin/kafka_exporter /usr/local/bin/kafka_exporter

# Copy Elasticsearch exporter
COPY --from=elasticsearch-exporter --chmod=755 /bin/elasticsearch_exporter /usr/local/bin/elasticsearch_exporter

# Copy PgBouncer exporter
COPY --from=pgbouncer-exporter --chmod=755 /bin/pgbouncer_exporter /usr/local/bin/pgbouncer_exporter

COPY ebpf/bootstrap_supervisord.conf /bootstrap/supervisord.conf
COPY --chmod=755 ebpf/run_supervisord.sh /run_supervisord.sh

# Default command
CMD ["/run_supervisord.sh"]
