ARG EBPF_AGENT_IMAGE=ghcr.io/betterstackhq/ebpf-agent:0.1.10@sha256:824b451ffb71c474f9e5c982146078384a30fee637dfdd6e4d7ada8a73cc0d25
ARG NODE_AGENT_VERSION=v1.30.0
FROM ${EBPF_AGENT_IMAGE} AS ebpf-agent-source

# Node Agent source with our patches
FROM --platform=$BUILDPLATFORM debian:13.5 AS node-agent-source
RUN apt-get update && apt-get install -y git
ARG NODE_AGENT_VERSION
RUN git clone --depth 1 --branch ${NODE_AGENT_VERSION} \
    https://github.com/coroot/coroot-node-agent.git /tmp/node-agent
WORKDIR /tmp/node-agent
COPY ebpf/patches/node-agent/*.patch ./
RUN git apply *.patch

# Regenerate Node Agent's embedded eBPF programs (ebpftracer/ebpf.go) from the patched C
# sources by running the RUN steps of upstream's ebpftracer/Dockerfile on its own base image.
# The output covers every target architecture, so it is built once on the build platform.
FROM --platform=$BUILDPLATFORM alpine:3.14 AS node-agent-ebpf
COPY --from=node-agent-source /tmp/node-agent/ebpftracer /tmp/ebpftracer
RUN grep -qx 'FROM alpine:3.14' /tmp/ebpftracer/Dockerfile || \
    { echo "upstream ebpftracer/Dockerfile changed its base image; update this stage" >&2; exit 1; }
RUN cp -r /tmp/ebpftracer/ebpf /tmp/ebpf && cd /tmp/ebpf && \
    sh -ec "$(sed -e ':a' -e '/\\$/N; s/\\\n//; ta' /tmp/ebpftracer/Dockerfile | sed -n 's/^RUN //p')"

# Build Node Agent
FROM debian:13.5 AS node-agent-builder
RUN apt-get update && apt-get install -y \
    curl git build-essential pkg-config libsystemd-dev
ARG GO_VERSION=1.24.9
RUN curl -fsSL https://go.dev/dl/go${GO_VERSION}.linux-$(dpkg --print-architecture).tar.gz -o go.tar.gz && \
    tar -C /usr/local -xzf go.tar.gz && rm go.tar.gz
ENV PATH="/usr/local/go/bin:${PATH}"
ARG CUSTOMIZATION_TAG="betterstack"
ARG NODE_AGENT_VERSION
COPY --from=node-agent-source /tmp/node-agent /tmp/node-agent
COPY --from=node-agent-ebpf /tmp/ebpf/ebpf.go /tmp/node-agent/ebpftracer/ebpf.go
WORKDIR /tmp/node-agent
RUN CGO_ENABLED=1 go build -mod=readonly \
    -ldflags "-extldflags='-Wl,-z,lazy' -X 'github.com/coroot/coroot-node-agent/flags.Version=${NODE_AGENT_VERSION}-${CUSTOMIZATION_TAG}'" \
    -o /usr/bin/coroot-node-agent .

# Build Cluster Agent from source with patches
FROM debian:13.5 AS cluster-agent-builder
RUN apt-get update && apt-get install -y curl git
ARG GO_VERSION=1.26.8
RUN curl -fsSL https://go.dev/dl/go${GO_VERSION}.linux-$(dpkg --print-architecture).tar.gz -o go.tar.gz && \
    tar -C /usr/local -xzf go.tar.gz && rm go.tar.gz
ENV PATH="/usr/local/go/bin:${PATH}"
ARG CLUSTER_AGENT_VERSION=v1.11.5
RUN git clone --depth 1 --branch ${CLUSTER_AGENT_VERSION} \
    https://github.com/coroot/coroot-cluster-agent.git /tmp/cluster-agent
WORKDIR /tmp/cluster-agent
COPY ebpf/patches/cluster-agent/*.patch ./
RUN git apply *.patch
RUN CGO_ENABLED=0 GOTOOLCHAIN=local go build -mod=readonly \
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

# Add mysqld exporter to the image
FROM prom/mysqld-exporter:v0.20.0 AS mysqld-exporter

# Build OBI from source with patches
FROM ghcr.io/open-telemetry/obi-generator:0.2.16@sha256:3a8959e5253f2445b782b4f720ed54f6396fce350082486442e0b71ac02ff106 AS obi-builder
RUN apk add --no-cache bash git make
ARG TARGETARCH
ARG CUSTOMIZATION_TAG="betterstack"
ARG OBI_VERSION="v0.14.0"
ARG OBI_REVISION="13d9b0c3f600a060bd78820a63ebec882b10757e"
RUN git clone --depth 1 --branch ${OBI_VERSION} \
    https://github.com/open-telemetry/opentelemetry-ebpf-instrumentation.git /tmp/obi && \
    test "$(git -C /tmp/obi rev-parse HEAD)" = "${OBI_REVISION}"
WORKDIR /tmp/obi
RUN --mount=type=cache,target=/go/pkg/mod go mod download
COPY ebpf/patches/obi/ /tmp/obi-patches/
RUN for p in /tmp/obi-patches/*.patch; do [ -e "$p" ] || break; git apply "$p"; done
ENV GOARCH=${TARGETARCH}
RUN --mount=type=cache,target=/root/.cache/go-build \
    --mount=type=cache,target=/go/pkg/mod \
    /generate.sh && \
    make compile RELEASE_VERSION="${OBI_VERSION}-${CUSTOMIZATION_TAG}"

# Final stage - Debian slim for glibc compatibility with node-agent
FROM debian:13.5-slim
ENV CLUSTER_AGENT_VERSION=1.11.5

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

# Copy PgBouncer exporter
COPY --from=pgbouncer-exporter --chmod=755 /bin/pgbouncer_exporter /usr/local/bin/pgbouncer_exporter

# Copy MySQL exporter
COPY --from=mysqld-exporter --chmod=755 /bin/mysqld_exporter /usr/local/bin/mysqld_exporter

COPY ebpf/bootstrap_supervisord.conf /bootstrap/supervisord.conf
COPY --chmod=755 ebpf/run_supervisord.sh /run_supervisord.sh

# Default command
CMD ["/run_supervisord.sh"]
