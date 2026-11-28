ARG EBPF_AGENT_IMAGE=ghcr.io/betterstackhq/ebpf-agent:1.1.2@sha256:62c57fd4901f77955f1d6d1c1f4e9f6452df35844cb7baedbc199f0373734930
FROM ${EBPF_AGENT_IMAGE} AS ebpf-agent-source

# Build Cluster Agent from source with patches
FROM debian:13.5 AS cluster-agent-builder
RUN apt-get update && apt-get install -y curl git
ARG GO_VERSION=1.26.8
RUN curl -fsSL https://go.dev/dl/go${GO_VERSION}.linux-$(dpkg --print-architecture).tar.gz -o go.tar.gz && \
    tar -C /usr/local -xzf go.tar.gz && rm go.tar.gz
ENV PATH="/usr/local/go/bin:${PATH}"
ARG CLUSTER_AGENT_VERSION=v1.11.9
RUN git clone --depth 1 --branch ${CLUSTER_AGENT_VERSION} \
    https://github.com/coroot/coroot-cluster-agent.git /tmp/cluster-agent
WORKDIR /tmp/cluster-agent
COPY ebpf/patches/cluster-agent/*.patch ./
RUN git apply *.patch
RUN CGO_ENABLED=0 GOTOOLCHAIN=local go build -mod=readonly \
    -o /usr/bin/coroot-cluster-agent .

# Add node exporter to the image
FROM prom/node-exporter:v1.10.2 AS node-exporter-source

# Build Postgres exporter from source with patches
FROM debian:13.5 AS postgres-exporter
RUN apt-get update && apt-get install -y curl git
ARG GO_VERSION=1.26.8
RUN curl -fsSL https://go.dev/dl/go${GO_VERSION}.linux-$(dpkg --print-architecture).tar.gz -o go.tar.gz && \
    tar -C /usr/local -xzf go.tar.gz && rm go.tar.gz
ENV PATH="/usr/local/go/bin:${PATH}"
ARG POSTGRES_EXPORTER_VERSION=v0.18.1
RUN git clone --depth 1 --branch ${POSTGRES_EXPORTER_VERSION} \
    https://github.com/prometheus-community/postgres_exporter.git /tmp/postgres-exporter
WORKDIR /tmp/postgres-exporter
COPY ebpf/patches/postgres-exporter/*.patch ./
RUN git apply *.patch
RUN CGO_ENABLED=0 GOTOOLCHAIN=local go build -mod=readonly \
    -ldflags "-X github.com/prometheus/common/version.Version=${POSTGRES_EXPORTER_VERSION#v}-betterstack -X github.com/prometheus/common/version.Revision=$(git rev-parse HEAD) -X github.com/prometheus/common/version.Branch=HEAD" \
    -o /bin/postgres_exporter ./cmd/postgres_exporter

# Add kafka exporter to the image
FROM danielqsj/kafka-exporter:v1.9.0 AS kafka-exporter

# Add elasticsearch exporter to the image
FROM quay.io/prometheuscommunity/elasticsearch-exporter:v1.11.0 AS elasticsearch-exporter

# Add pgbouncer exporter to the image
FROM prometheuscommunity/pgbouncer-exporter:v0.12.0 AS pgbouncer-exporter

# Add mysqld exporter to the image
FROM prom/mysqld-exporter:v0.20.0 AS mysqld-exporter

# Build OBI from source with patches
FROM ghcr.io/open-telemetry/obi-generator:0.2.17@sha256:1ae9406f2566e32ccf5d8ba8e5ff0586a322300ae82870988ad605429021174a AS obi-builder
RUN apk add --no-cache bash git make
ARG TARGETARCH
ARG CUSTOMIZATION_TAG="betterstack"
ARG OBI_VERSION="v0.15.2"
ARG OBI_REVISION="b28e4e7fe0a01f1961b7c4747a13b8ff486d6fec"
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

# Ruby 4.0 from the official image, the same release the collector image ships
FROM ruby:4.0.10-slim-trixie AS ruby
# The official build keeps debug info (~50 MB); Debian's ruby package ships without it
RUN apt-get update && apt-get install -y --no-install-recommends binutils \
  && find /usr/local/bin/ruby /usr/local/lib -type f \( -name ruby -o -name '*.so*' \) \
  -exec strip --strip-debug {} +

# Final stage - Debian slim: the eBPF agent links against glibc
FROM debian:13.5-slim
ENV CLUSTER_AGENT_VERSION=1.11.9

# Install supervisor, ca-certificates, curl, procps, and the libraries Ruby and its extensions link against
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        supervisor \
        ca-certificates \
        curl \
        procps \
        libcrypt1 \
        libffi8 \
        libgmp10 \
        libssl3t64 \
        libyaml-0-2 \
        libzstd1 \
        zlib1g \
        jq && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Download AWS RDS CA bundle and update system CA store; fail the build if the
# roots behind the compromised eMudhra intermediates are still trusted
RUN apt-get update && apt-get install -y --no-install-recommends --only-upgrade ca-certificates \
    && apt-get clean && rm -rf /var/lib/apt/lists/* \
    && curl -sS https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem \
    -o /usr/local/share/ca-certificates/aws-rds.crt \
    && update-ca-certificates \
    && ! test -e /etc/ssl/certs/emSign_ECC_Root_CA_-_G3.pem \
    && ! test -e /etc/ssl/certs/Comodo_AAA_Services_root.pem

# Copy Ruby; scripts run both as `ruby` (PATH) and as `/usr/bin/ruby`.
# Fail the build if a shared library is missing or a library the scripts need doesn't load.
COPY --from=ruby /usr/local/bin/ /usr/local/bin/
COPY --from=ruby /usr/local/etc/gemrc /usr/local/etc/gemrc
COPY --from=ruby /usr/local/lib/ /usr/local/lib/
RUN ln -s /usr/local/bin/ruby /usr/bin/ruby \
    && ldconfig \
    && ! { ldd /usr/local/bin/ruby; find /usr/local/lib/ruby -name '*.so' -exec ldd {} \; ; } | grep 'not found' \
    && /usr/bin/ruby -ropenssl -rpsych -rzlib -rjson -rcsv -rlogger -rerb -ropen3 -rnet/http -e 'exit 0'

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

# Copy MySQL exporter
COPY --from=mysqld-exporter --chmod=755 /bin/mysqld_exporter /usr/local/bin/mysqld_exporter

COPY ebpf/bootstrap_supervisord.conf /bootstrap/supervisord.conf
COPY --chmod=755 ebpf/run_supervisord.sh /run_supervisord.sh

# Default command
CMD ["/run_supervisord.sh"]
