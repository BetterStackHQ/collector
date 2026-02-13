# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Better Stack Collector is a Docker-based monitoring solution that collects metrics, logs, and traces. This repo contains the **container scaffolding and deployment scripts** only — the actual application logic (Ruby scripts, supervisor configs, healthcheck, etc.) is delivered at runtime via the Better Stack manifest API.

Two containers are built here:
- **Collector** (`collector/Dockerfile`) — Vector + Cluster Agent on Debian, bootstrapped via manifest API
- **eBPF** (`ebpf/Dockerfile`) — OBI + Node Agent + Cluster Agent + Node Exporter + Postgres Exporter on Debian, provisioned by the collector's bootstrap

## Repository Structure

```
install.sh                  # Docker Compose installation (downloads compose file from GitHub, deploys)
uninstall.sh                # Docker Compose uninstall
deploy-to-swarm.sh          # Docker Swarm deployment (SSH to manager + nodes)
docker-compose.yml          # Standard compose: collector + ebpf services
docker-compose.seccomp.yml  # Same with seccomp for Docker < 20.10.10
collector-seccomp.json      # Seccomp profile allowing clone3 for Tokio/Vector
collector/
  Dockerfile                # Multi-stage: Vector 0.47.0 + Cluster Agent 1.2.4 + Debian 12.11-slim
  bootstrap.sh              # Downloads manifest from API, provisions both containers
  bootstrap_supervisord.conf
  run_supervisord.sh
  versions/0-default/       # Default Vector config + empty databases.json
  kubernetes-discovery/0-default/
ebpf/
  Dockerfile                # Multi-stage: OBI 0.4.1 + Node Agent 1.27.0 + exporters + Debian 12.11-slim
  bootstrap_supervisord.conf
  run_supervisord.sh
swarm/
  docker-compose.swarm-collector.yml  # Swarm global service for collector
  docker-compose.swarm-ebpf.yml      # Regular docker-compose for eBPF (needs host network)
```

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
  - Node Agent sends metrics to `http://localhost:33000`
  - eBPF agent sends traces on port 34320 (localhost only)
- **Shared Volume**: `/var/lib/better-stack` for bootstrap provisioning and supervisor socket
- **Shared Volume**: `docker-metadata` for container enrichment tables

### Container Naming Conventions

- **Docker Compose** (install.sh): containers named `better-stack-collector` and `better-stack-ebpf` (hyphens)
- **Docker Swarm** (deploy-to-swarm.sh): service appears as `better-stack_collector` (underscore, from stack name `better-stack` + service `collector`)

Both install.sh and deploy-to-swarm.sh check for the other's naming convention to prevent double-installation.

### Deployment Modes

**Docker Compose** (`install.sh`):
- Downloads docker-compose.yml from GitHub raw URL
- Adjusts ports, volumes, mounts via awk/sed
- Handles Docker Compose v1 compatibility
- Project name: `better-stack-collector`

**Docker Swarm** (`deploy-to-swarm.sh`):
- SSHes into manager node, discovers swarm nodes
- Optional node filtering via `better-stack.collector=true` label
- Collector deployed as global swarm service via `docker stack deploy`
- eBPF deployed per-node via docker-compose (swarm doesn't support privileged/host network)
- Supports install/uninstall/force_upgrade actions

## Key Environment Variables

### Installation (install.sh / deploy-to-swarm.sh)
- `COLLECTOR_SECRET` (required) — Authentication token
- `BASE_URL` — API endpoint (default: https://telemetry.betterstack.com)
- `CLUSTER_COLLECTOR` — Force cluster collector mode (default: false)
- `PROXY_PORT` (optional) — Host port for upstream proxy (cannot be 80 with USE_TLS, cannot be 33000/34320/39090)
- `USE_TLS` (optional) — Enable TLS; port 80 exposed for ACME validation. Only used by install.sh.
- `MOUNT_HOST_PATHS` (optional) — Comma-separated host paths instead of default `/:/host:ro`
- `COLLECT_OTEL_HTTP_PORT` / `COLLECT_OTEL_GRPC_PORT` (optional) — OTel ingestion ports

### Swarm-specific (deploy-to-swarm.sh)
- `MANAGER_NODE` (required) — SSH target for swarm manager (user@host)
- `ACTION` — install (default), uninstall, or force_upgrade
- `SSH_CMD` — Custom SSH command (default: ssh), e.g., `tsh ssh` for Teleport
- `ATTACH_NETWORKS` — Comma-separated overlay networks (auto-detected if not set)

## CI/CD

Three GitHub Actions workflows:
- `docker-build.yml` — Builds and pushes images to GHCR via Depot (amd64 + arm64)
- `docker-compose-match.yml` — Verifies compose files stay in sync
- `check-docs-scripts.yml` — Verifies install/uninstall/deploy scripts exist

## Seccomp

On Docker < 20.10.10, the `clone3` syscall is blocked by default seccomp, breaking Tokio (Vector). For these versions, `install.sh` uses `docker-compose.seccomp.yml` + `collector-seccomp.json`.

## Development Troubleshooting

- **Container failing to start?** Disable `fatal_handler` in the runtime-delivered supervisord.conf, then check `/var/log/supervisor/*` logs.
- **Vector loses configuration?** Health check (runtime-delivered) runs every 30s, restarts after 3 failures. Check sinks: `docker exec -it better-stack-collector curl -s http://localhost:8686/graphql -H "Content-Type: application/json" -d '{"query":"{ sinks { edges { node { componentId } } } }"}'`
- **Debug config updates**: `docker exec -it better-stack-collector tail -f /var/log/supervisor/updater.out.log`
- **Check current config**: `docker exec -it better-stack-collector ls -la /vector-config/current/`
