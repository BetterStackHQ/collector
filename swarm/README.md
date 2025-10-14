# Docker Swarm Deployment

Deploy Better Stack Collector across a Docker Swarm cluster.

## Quick Start

```bash
# Deploy to all nodes
curl -sSL https://raw.githubusercontent.com/BetterStackHQ/collector/main/swarm/deploy-to-swarm.sh | \
  MANAGER_NODE="user@swarm-manager" \
  COLLECTOR_SECRET="your-secret-here" \
  bash
```

## What It Does

- Installs Beyla container on **each node** for eBPF traces and metrics
- Deploys collector as a **global service** (one per node)
- Auto-detects and attaches to overlay networks for service discovery

## Configuration

### Environment Variables

- `MANAGER_NODE` - SSH target for swarm manager (required)
- `COLLECTOR_SECRET` - Your Better Stack secret (required)
- `ACTION` - `install` (default), `uninstall`, or `force_upgrade`
- `IMAGE_TAG` - Docker image tag (default: `latest`)
- `SWARM_NETWORKS` - Comma-separated overlay networks (auto-detected if not set)

### Examples

```bash
# Force upgrade with specific image
ACTION=force_upgrade IMAGE_TAG=pr-59 ./deploy-to-swarm.sh

# Uninstall from all nodes
ACTION=uninstall ./deploy-to-swarm.sh

# Specify networks manually
SWARM_NETWORKS=app_network,db_network ./deploy-to-swarm.sh
```

## Architecture

- **Beyla containers**: Run with host network mode for eBPF access
- **Collector service**: Global mode with host port binding
- **Communication**: Beyla → Collector via localhost (127.0.0.1:33000/34320)
- **Data sharing**: Enrichment directory at `/var/lib/better-stack/enrichment`

## Troubleshooting

```bash
# Check service status
docker service ls | grep better-stack

# View collector logs
docker service logs better-stack_collector

# Check specific node
ssh user@node docker ps --filter "name=better-stack"
```