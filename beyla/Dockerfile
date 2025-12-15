# Add Node Agent to the image
FROM ghcr.io/coroot/coroot-node-agent:1.27.0 AS node-agent

# Add Cluster Agent to the image
FROM ghcr.io/coroot/coroot-cluster-agent:1.2.4 AS cluster-agent

# Add node exporter to the image
FROM prom/node-exporter:v1.10.2 AS node-exporter-source

# Add postgres exporter to the image
FROM prometheuscommunity/postgres-exporter:v0.18.1 AS postgres-exporter

# Add OBI to the image
FROM otel/ebpf-instrument:v0.3.0 AS obi-source

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

# Create necessary directories
RUN mkdir -p /etc/supervisor/conf.d /var/log/supervisor /enrichment /bootstrap

# Copy Beyla files from official image and set permissions
COPY --from=obi-source --chmod=755 /ebpf-instrument /usr/local/bin/ebpf-instrument
COPY --from=obi-source /LICENSE /LICENSE
COPY --from=obi-source /NOTICE /NOTICE

# Copy Node Agent
COPY --from=node-agent --chmod=755 /usr/bin/coroot-node-agent /usr/local/bin/node-agent

# Copy Cluster Agent
COPY --from=cluster-agent --chmod=755 /usr/bin/coroot-cluster-agent /usr/local/bin/cluster-agent

# Copy Node exporter
COPY --from=node-exporter-source --chmod=755 /bin/node_exporter /usr/local/bin/node_exporter

# Copy Postgres exporter
COPY --from=postgres-exporter --chmod=755 /bin/postgres_exporter /usr/local/bin/postgres_exporter

COPY beyla/bootstrap_supervisord.conf /bootstrap/supervisord.conf
COPY --chmod=755 beyla/run_supervisord.sh /run_supervisord.sh

# Default command
CMD ["/run_supervisord.sh"]
