# Use Vector as the base image
FROM timberio/vector:0.47.0-debian AS vector

# Use Cluster Agent as another base
FROM ghcr.io/coroot/coroot-cluster-agent:1.2.4 AS cluster-agent

# Build mdprobe
FROM golang:1.24.4-alpine3.22 AS mdprobe-builder
WORKDIR /src
COPY mdprobe/go.mod mdprobe/go.sum ./
RUN go mod download
COPY mdprobe/main.go ./
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags='-s -w' -o /bin/mdprobe .

# Final stage
FROM debian:12.11-slim

# Install required packages
RUN apt-get update && apt-get install -y \
  ruby \
  supervisor \
  curl \
  bash \
  tini \
  jq \
  && rm -rf /var/lib/apt/lists/*

# Copy Vector from vector image
COPY --from=vector --chmod=755 /usr/bin/vector /usr/local/bin/vector
COPY --from=vector /etc/vector /etc/vector

# Copy Cluster Agent
COPY --from=cluster-agent --chmod=755 /usr/bin/coroot-cluster-agent /usr/local/bin/cluster-agent

# Copy mdprobe
COPY --from=mdprobe-builder --chmod=755 /bin/mdprobe /usr/local/bin/mdprobe

# Create necessary directories
RUN mkdir -p /versions/0-default \
  && mkdir -p /etc/supervisor/conf.d \
  && mkdir -p /var/lib/vector \
  && mkdir -p /var/log/supervisor \
  && mkdir -p /kubernetes-discovery/0-default \
  && mkdir -p /vector-config \
  && mkdir -p /enrichment-defaults

# Set environment variables
ENV BASE_URL=https://telemetry.betterstack.com
ENV CLUSTER_COLLECTOR=false
ENV COLLECTOR_VERSION=1.0.16
ENV VECTOR_VERSION=0.47.0
ENV BEYLA_VERSION=2.2.4
ENV CLUSTER_AGENT_VERSION=1.2.4

# The environment variable TINI_SUBREAPER=true is related to Tini, which is the init system being used in this Docker container.
# When TINI_SUBREAPER is set to true, it enables Tini's "subreaper" functionality. Here's what that means:
# In Linux, when a parent process dies, its child processes are typically "re-parented" to PID 1 (the init process)
# With subreaper enabled, Tini will become a "subreaper", meaning it will "adopt" any orphaned child processes from processes that it spawned
# This is particularly useful in Docker containers where you're running multiple processes (as this Dockerfile is, using supervisord)
# It helps ensure proper cleanup of all child processes when the container is stopped
# In this specific Dockerfile, it's important because:
# The container is running multiple processes (Vector, Coroot agents, and Ruby scripts) via supervisord
# If any of these processes spawn child processes that then become orphaned, Tini will properly manage and clean them up
# This prevents potential zombie processes and ensures clean container shutdown
# This is considered a best practice when running multi-process containers with Tini as the init system.
ENV TINI_SUBREAPER=true

# Copy supervisor configuration
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf

# Copy Ruby scripts
COPY --chmod=755 updater.rb /updater.rb
COPY --chmod=755 proxy.rb /proxy.rb
COPY --chmod=755 vector.sh /vector.sh
COPY versions/0-default/vector.yaml /versions/0-default/vector.yaml
COPY versions/0-default/databases.json /versions/0-default/databases.json
COPY kubernetes-discovery/0-default/discovered_pods.yaml /kubernetes-discovery/0-default/discovered_pods.yaml
COPY engine /engine
COPY should_run_cluster_collector.rb /should_run_cluster_collector.rb
COPY --chmod=755 cluster-collector.sh /cluster-collector.sh
COPY --chmod=755 ebpf.sh /ebpf.sh
# Copy default enrichment files to both locations
# /enrichment-defaults is the source for copying at runtime
# /enrichment is for Kubernetes compatibility, since it's volume mounts work differently from compose/swarm
COPY dockerprobe/docker-mappings.default.csv /enrichment-defaults/docker-mappings.csv
COPY dockerprobe/databases.default.csv /enrichment-defaults/databases.csv
COPY dockerprobe/docker-mappings.default.csv /enrichment/docker-mappings.csv
COPY dockerprobe/databases.default.csv /enrichment/databases.csv

# Create initial vector-config with symlinks to defaults
RUN mkdir -p /vector-config/0-default \
  && mkdir -p /vector-config/latest-valid-upstream \
  && ln -s /versions/0-default/vector.yaml /vector-config/0-default/vector.yaml \
  && ln -s /kubernetes-discovery/0-default /vector-config/0-default/kubernetes-discovery \
  && ln -s /vector-config/0-default /vector-config/current \
  && cp /versions/0-default/vector.yaml /vector-config/latest-valid-upstream/vector.yaml

# Install tini and use it as init to handle signals properly
ENTRYPOINT ["/usr/bin/tini", "-s", "--"]

# Start supervisor
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"]
