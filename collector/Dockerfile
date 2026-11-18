# Use Vector as the base image
FROM timberio/vector:0.47.0-debian AS vector

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

# Ruby 4.0 from the official image. Debian 13 ships Ruby 3.3, whose TCPSocket
# never tries IPv6 when IPv4 fails at once, so it can't connect on IPv6-only hosts.
FROM ruby:4.0.9-slim-trixie AS ruby
# webrick left the standard library in Ruby 3.0; Debian's ruby package brought it in
RUN gem install --install-dir /usr/local/lib/ruby/gems/4.0.0 --no-document webrick -v 1.9.2
# The official build keeps debug info (~50 MB); Debian's ruby package ships without it
RUN apt-get update && apt-get install -y --no-install-recommends binutils \
  && find /usr/local/bin/ruby /usr/local/lib -type f \( -name ruby -o -name '*.so*' \) \
  -exec strip --strip-debug {} +

# Final stage
FROM debian:13.5-slim

# Install required packages (the lib* ones are what Ruby and its extensions link against)
RUN apt-get update && apt-get install -y \
  libcrypt1 \
  libffi8 \
  libgmp10 \
  libssl3t64 \
  libyaml-0-2 \
  libzstd1 \
  zlib1g \
  supervisor \
  curl \
  bash \
  tini \
  jq \
  certbot \
  openssl \
  traceroute \
  ca-certificates \
  && rm -rf /var/lib/apt/lists/*

# Download AWS RDS CA bundle and update system CA store; fail the build if the
# roots behind the compromised eMudhra intermediates are still trusted
RUN apt-get update && apt-get install -y --only-upgrade ca-certificates \
  && rm -rf /var/lib/apt/lists/* \
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
  && /usr/bin/ruby -ropenssl -rpsych -rzlib -rfiddle -rwebrick -rcsv -rbase64 -e 'exit 0'

# Copy Vector from vector image
COPY --from=vector --chmod=755 /usr/bin/vector /usr/local/bin/vector
COPY --from=vector /etc/vector /etc/vector

# Copy Cluster Agent
COPY --from=cluster-agent-builder --chmod=755 /usr/bin/coroot-cluster-agent /usr/local/bin/cluster-agent

# Create necessary directories
RUN mkdir -p /versions/0-default \
  && mkdir -p /etc/supervisor/conf.d \
  && mkdir -p /var/lib/vector \
  && mkdir -p /var/log/supervisor \
  && mkdir -p /kubernetes-discovery/0-default \
  && mkdir -p /vector-config \
  && mkdir -p /enrichment-defaults \
  && mkdir -p /etc/ssl

# Set environment variables
ENV BASE_URL=https://telemetry.betterstack.com
ENV CLUSTER_COLLECTOR=false
ENV COLLECTOR_VERSION=1.2.2
ENV VECTOR_VERSION=0.47.0
ENV CLUSTER_AGENT_VERSION=1.11.9
ENV OBI_VERSION=0.15.2

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

# Copy bootstrap supervisor configuration and necessary initialization scripts
COPY collector/bootstrap_supervisord.conf /bootstrap/supervisord.conf
COPY --chmod=755 collector/bootstrap.sh /bootstrap.sh
COPY --chmod=755 collector/run_supervisord.sh /run_supervisord.sh

COPY collector/versions/0-default/vector.yaml /versions/0-default/vector.yaml
COPY collector/versions/0-default/databases.json /versions/0-default/databases.json
COPY collector/kubernetes-discovery/0-default/discovered_pods.yaml /kubernetes-discovery/0-default/discovered_pods.yaml

# Create initial vector-config with symlinks to defaults
RUN mkdir -p /vector-config/0-default \
  && mkdir -p /vector-config/latest-valid-upstream \
  && ln -s /versions/0-default/vector.yaml /vector-config/0-default/vector.yaml \
  && ln -s /kubernetes-discovery/0-default /vector-config/0-default/kubernetes-discovery \
  && ln -s /vector-config/0-default /vector-config/current \
  && cp /versions/0-default/vector.yaml /vector-config/latest-valid-upstream/vector.yaml \
  && touch /first-boot.txt

# Install tini and use it as init to handle signals properly
ENTRYPOINT ["/usr/bin/tini", "-s", "--"]

# Start supervisor
CMD ["/run_supervisord.sh"]
