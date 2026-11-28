# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Better Stack Collector is a Docker-based monitoring solution that collects metrics, logs, and traces. This repo contains the **container scaffolding and deployment scripts** only — the actual application logic (Ruby scripts, supervisor configs, healthcheck, etc.) is delivered at runtime via the Better Stack manifest API.

Two containers are built here:
- **Collector** (`collector/Dockerfile`) — Vector + Cluster Agent + Ruby on Debian, bootstrapped via manifest API
- **eBPF** (`ebpf/Dockerfile`) — OBI + Better Stack eBPF Agent + Cluster Agent + Node Exporter + Postgres Exporter + Ruby on Debian, provisioned by the collector's bootstrap

## Repository Structure

```
install.sh                  # Docker Compose installation (downloads compose file from GitHub, deploys)
uninstall.sh                # Docker Compose uninstall
deploy-to-swarm.sh          # Docker Swarm deployment (SSH to manager + nodes)
docker-compose.yml          # Standard compose: collector + ebpf services
docker-compose.seccomp.yml  # Same with seccomp for Docker < 20.10.10
collector-seccomp.json      # Seccomp profile allowing clone3 for Tokio/Vector
collector/
  Dockerfile                # Multi-stage: Vector 0.47.0 + Cluster Agent 1.11.9 + Ruby 4.0.10 + Debian 13.5-slim
  bootstrap.sh              # Downloads manifest from API, provisions both containers
  bootstrap_supervisord.conf
  run_supervisord.sh
  versions/0-default/       # Default Vector config + empty databases.json
  kubernetes-discovery/0-default/
ebpf/
  Dockerfile                # Multi-stage: OBI 0.15.2 + eBPF Agent 1.1.1 + exporters + Ruby 4.0.10 + Debian 13.5-slim
  bootstrap_supervisord.conf
  run_supervisord.sh
swarm/
  docker-compose.swarm-collector.yml  # Swarm global service for collector
  docker-compose.swarm-ebpf.yml      # Regular docker-compose for eBPF (needs host network)
```

> **These version numbers are duplicated in several places — keep them in sync.** The source of truth is the `FROM`/`ARG` pins in `collector/Dockerfile` and `ebpf/Dockerfile`. When you bump one, also update its `ENV *_VERSION` line in `collector/Dockerfile` (if it has one) and the summary above.

## Development Commands

```bash
# Build collector image
docker build -t better-stack-collector -f collector/Dockerfile .

# Build eBPF image
docker build -t better-stack-ebpf -f ebpf/Dockerfile .

# Run locally with Docker Compose
export HOSTNAME
COLLECTOR_SECRET=your_secret BASE_URL=https://telemetry.betterstack.ngrok.dev docker compose up

# Tail collector logs
docker exec -it better-stack-collector bash -c "tail -f /var/log/supervisor/*"

# Live Vector stats
docker exec -it better-stack-collector vector top

# Live eBPF data in Vector
docker exec -it better-stack-collector vector tap 'ebpf_otel*'
```

There are no tests in this repository. The Ruby application code and its tests live in a separate repo (telemetry).

## Architecture

### Bootstrap Architecture

On container start:
1. `run_supervisord.sh` starts supervisord with `bootstrap_supervisord.conf`
2. Bootstrap config only runs `bootstrap.sh`
3. `bootstrap.sh` calls the Better Stack manifest API to download all application files (Ruby scripts, real supervisor configs, healthchecks, etc.) into `/var/lib/better-stack/`
4. Reloads supervisor with the real config, which starts Vector, updater, proxy, etc.
5. Also provisions the eBPF container via shared Unix socket on `/var/lib/better-stack/`

### Container Communication

- **eBPF → Collector**: Via host network mode
  - Cluster Agent polls `http://localhost:33000/v1/cluster-agent-enabled`
  - Cluster Agent fetches database config from `http://localhost:33000/v1/config`
  - Better Stack eBPF Agent pushes metrics to the collector proxy at `http://localhost:33000` and serves Prometheus metrics at `http://localhost:39100/metrics`
  - OBI sends traces on port 34320 (localhost only)
- **Shared Volume**: `/var/lib/better-stack` for bootstrap provisioning and supervisor socket
- **Shared Volume**: `docker-metadata` for container enrichment tables

### Container Naming Conventions

- **Docker Compose** (install.sh): containers named `better-stack-collector` and `better-stack-collector-host` (hyphens); older names `better-stack-ebpf` and `better-stack-beyla` are removed on upgrade
- **Docker Swarm** (deploy-to-swarm.sh): service appears as `better-stack_collector` (underscore, from stack name `better-stack` + service `collector`)

Both install.sh and deploy-to-swarm.sh check for the other's naming convention to prevent double-installation.

### Deployment Modes

**Docker Compose** (`install.sh`):
- Downloads docker-compose.yml from GitHub raw URL
- Adjusts ports, volumes, mounts via awk/sed
- Handles Docker Compose v1 compatibility
- Sets the container sizes through variables in the compose files (`${COLLECTOR_HOST_CPUS:-1.0}` and so on). A size comes from the environment, then from `/var/lib/better-stack/sizing.env`, then from the default; a size from the environment is saved to that file
- Memory values that are not set follow the container's memory limit: reservation, `GOMEMLIMIT` and the OBI restart threshold of the `better-stack-collector-host` container keep the proportions of the defaults
- Lowers a default memory limit to the host's memory, and any CPU limit to the host's CPU count (Docker rejects a higher one)
- On an IPv6-only host (IPv6 default route, no IPv4 one) with Docker >= 27, turns on IPv6 for the Compose default network and recreates an existing IPv4-only one. A network that already has IPv6 keeps it on later runs. The committed compose files stay IPv4-only because `enable_ipv6` without a subnet fails on Docker < 27
- Skips that, with a warning, when other containers use the existing network (Docker cannot remove it then), or when the kernel keeps the host's IPv6 default route alive from router advertisements (`proto ra`, `accept_ra=1`, forwarding off): Docker turns on IPv6 forwarding for an IPv6 network and the kernel would then drop the route
- Project name: `better-stack-collector`

**Docker Swarm** (`deploy-to-swarm.sh`):
- SSHes into manager node, discovers swarm nodes
- Optional node filtering via `better-stack.collector=true` label
- Collector deployed as global swarm service via `docker stack deploy`
- eBPF deployed per-node via docker-compose (swarm doesn't support privileged/host network)
- Supports install/uninstall/force_upgrade/collector_host_only actions; `collector_host_only` deploys the `better-stack-collector-host` container on each node again without `COLLECTOR_SECRET`
- Each node sizes its `better-stack-collector-host` container from its own `/var/lib/better-stack/sizing.env`; the collector service has one size for all nodes
- `SWARM_SIZING_FILE` points to a file on the operator's machine with `[node names]` sections of `COLLECTOR_HOST_*` keys. The script checks the whole file before it deploys anything, then replaces the sizing file of every node: a node the file names gets its section, any other node gets the defaults
- The sizing functions are the same text in `install.sh` and `deploy-to-swarm.sh` (between the `sizing functions` markers), and CI checks that

### Script layout

`install.sh` and `deploy-to-swarm.sh` hold all their code in a `main` function that the last line calls. Bash reads a function to its end before it runs it, so a cut-off `curl | bash` download, or a file that changes during a run, runs nothing. Keep new code inside `main`, and do not indent the body: the here-documents in it must end at the start of a line.

## Key Environment Variables

### Installation (install.sh / deploy-to-swarm.sh)
- `COLLECTOR_SECRET` (required) — Authentication token
- `BASE_URL` — API endpoint (default: https://telemetry.betterstack.com)
- `CLUSTER_COLLECTOR` — Force cluster collector mode (default: false)
- `MOUNT_HOST_PATHS` (optional) — Comma-separated host paths instead of default `/:/host:ro`
- `COLLECT_OTEL_HTTP_PORT` / `COLLECT_OTEL_GRPC_PORT` (optional) — OTel ingestion ports
- `COLLECTOR_CPUS`, `COLLECTOR_MEM_LIMIT`, `COLLECTOR_MEM_RESERVATION`, `COLLECTOR_HOST_CPUS`, `COLLECTOR_HOST_MEM_LIMIT`, `COLLECTOR_HOST_MEM_RESERVATION`, `COLLECTOR_HOST_GOMEMLIMIT`, `COLLECTOR_HOST_OBI_RESTART_MIB` (optional) — container sizes; `deploy-to-swarm.sh` reads the `COLLECTOR_HOST_*` ones from each node's sizing file only
- `COLLECT_OTEL_BIND_ADDRESS` (optional) — Listen address of the OTel receiver, e.g. `[::]`; unset lets the collector pick it

### Swarm-specific (deploy-to-swarm.sh)
- `MANAGER_NODE` (required) — SSH target for swarm manager (user@host)
- `ACTION` — install (default), uninstall, force_upgrade, or collector_host_only
- `SSH_CMD` — Custom SSH command (default: ssh), e.g., `tsh ssh` for Teleport
- `ATTACH_NETWORKS` — Comma-separated overlay networks (auto-detected if not set)
- `SWARM_SIZING_FILE` — Local file with `better-stack-collector-host` container sizes per node, pushed to the nodes on install, force_upgrade and collector_host_only

## CI/CD

Three GitHub Actions workflows:
- `docker-build.yml` — Builds and pushes images to GHCR via Depot (amd64 + arm64)
- `docker-compose-match.yml` — Verifies compose files stay in sync, and that both scripts carry the same sizing functions
- `check-docs-scripts.yml` — Verifies install/uninstall/deploy scripts exist

## Seccomp

On Docker < 20.10.10, the `clone3` syscall is blocked by default seccomp, breaking Tokio (Vector). For these versions, `install.sh` uses `docker-compose.seccomp.yml` + `collector-seccomp.json`.

## Development Troubleshooting

- **Container failing to start?** Disable `fatal_handler` in the runtime-delivered supervisord.conf, then check `/var/log/supervisor/*` logs.
- **Vector loses configuration?** Health check (runtime-delivered) runs every 30s, restarts after 3 failures. Check sinks: `docker exec -it better-stack-collector curl -s http://localhost:8686/graphql -H "Content-Type: application/json" -d '{"query":"{ sinks { edges { node { componentId } } } }"}'`
- **Debug config updates**: `docker exec -it better-stack-collector tail -f /var/log/supervisor/updater.out.log`
- **Check current config**: `docker exec -it better-stack-collector ls -la /vector-config/current/`
