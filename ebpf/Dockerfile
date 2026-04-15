# Build Node Agent from source with patches
FROM debian:bullseye AS node-agent-builder
RUN apt-get update && apt-get install -y \
    curl git build-essential pkg-config libsystemd-dev
ARG GO_VERSION=1.24.9
RUN curl -fsSL https://go.dev/dl/go${GO_VERSION}.linux-$(dpkg --print-architecture).tar.gz -o go.tar.gz && \
    tar -C /usr/local -xzf go.tar.gz && rm go.tar.gz
ENV PATH="/usr/local/go/bin:${PATH}"
ARG CUSTOMIZATION_TAG="betterstack"
ARG NODE_AGENT_VERSION=v1.30.0
RUN git clone --depth 1 --branch ${NODE_AGENT_VERSION} \
    https://github.com/coroot/coroot-node-agent.git /tmp/node-agent
WORKDIR /tmp/node-agent
COPY ebpf/patches/node-agent/*.patch ./
RUN git apply *.patch
RUN CGO_ENABLED=1 go build -mod=readonly \
    -ldflags "-extldflags='-Wl,-z,lazy' -X 'github.com/coroot/coroot-node-agent/flags.Version=${NODE_AGENT_VERSION}-${CUSTOMIZATION_TAG}'" \
    -o /usr/bin/coroot-node-agent .

# Build Cluster Agent from source with patches
FROM debian:bullseye AS cluster-agent-builder
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
FROM quay.io/prometheuscommunity/elasticsearch-exporter:v1.10.0 AS elasticsearch-exporter

# Download OBI binary from GitHub release (Docker image otel/ebpf-instrument:v0.5.0 exists but is amd64-only)
FROM debian:12.11-slim AS obi-source
ARG TARGETARCH
ARG OBI_VERSION="v0.7.1"
ADD https://github.com/open-telemetry/opentelemetry-ebpf-instrumentation/releases/download/${OBI_VERSION}/obi-${OBI_VERSION}-linux-${TARGETARCH}.tar.gz /tmp/obi.tar.gz
RUN tar -xzf /tmp/obi.tar.gz -C /tmp

# Final stage - Using Debian 12.11-slim for glibc compatibility with node-agent
FROM debian:12.11-slim

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

# Copy OBI binary and license files from extracted tarball
COPY --from=obi-source --chmod=755 /tmp/obi /usr/local/bin/ebpf-instrument
COPY --from=obi-source /tmp/LICENSE /tmp/NOTICE /usr/share/doc/ebpf-instrument/

# Copy Node Agent
COPY --from=node-agent-builder --chmod=755 /usr/bin/coroot-node-agent /usr/local/bin/node-agent

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

COPY ebpf/bootstrap_supervisord.conf /bootstrap/supervisord.conf
COPY --chmod=755 ebpf/run_supervisord.sh /run_supervisord.sh

# Default command
CMD ["/run_supervisord.sh"]
