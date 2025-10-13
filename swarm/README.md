# Better Stack Collector - Swarm Deployment

This guide explains how to deploy Better Stack Collector with a separated Cluster Agent architecture suitable for Docker Swarm environments.

## Architecture

The deployment is split into three components:

1. **Collector Container** - Runs Vector for data pipeline (deployed via docker-compose)
2. **Beyla Container** - Runs eBPF-based monitoring (deployed via docker-compose, requires privileged mode)
3. **Cluster Agent Container** - Monitors cluster resources (deployed to Docker Swarm)

## Why This Architecture?

- **Beyla requires privileged mode** which is not recommended in Swarm services
- **Cluster Agent doesn't need privileged mode** and can run as a regular Swarm service
- **Network isolation** - Uses Docker overlay network for secure communication

## Prerequisites

- Docker Swarm initialized (`docker swarm init`)
- `COLLECTOR_SECRET` environment variable set
- Docker Compose v2

## Quick Deployment

The easiest way to deploy is using the automated script:

```bash
# Set required environment variables
export COLLECTOR_SECRET=your_secret_here

# Deploy to all swarm nodes
MANAGER_NODE=user@manager-node COLLECTOR_SECRET=$COLLECTOR_SECRET ./deploy-to-swarm.sh
```

This will:
1. Create the overlay network on the swarm
2. Deploy the cluster agent as a swarm service
3. Deploy collector and beyla containers on each node

### Network Selection

By default, the cluster agent automatically attaches to `better_stack_collector_overlay` and to all other overlay networks.
If you have more than 2 overlay networks, you need to specify networks to attach to explicitly:

```bash
# Specify additional networks explicitly (better_stack_collector_overlay is added automatically)
SWARM_NETWORKS=my_app_network,frontend_network \
MANAGER_NODE=user@manager-node COLLECTOR_SECRET=$COLLECTOR_SECRET ./deploy-to-swarm.sh
```

The script will:
- Always include `better_stack_collector_overlay` (not counted in the 2 network limit)
- Auto-detect additional swarm overlay networks
- Refuse deployment if more than 2 additional networks exist without explicit selection

## Manual Deployment

### 1. Create the Overlay Network

```bash
docker network create -d overlay --attachable better_stack_collector_overlay
```

### 2. Build Images

```bash
# Build collector image
docker build -t betterstack/collector:latest -f Dockerfile .

# Build beyla image  
docker build -t betterstack/collector-beyla:latest -f Dockerfile.beyla .

# Build cluster agent image
docker build -t betterstack/cluster-agent:latest -f Dockerfile.cluster-agent .
```

Note: When using `deploy-to-swarm.sh`, images are pulled from Docker Hub automatically.

### 3. Deploy Collector and Beyla

```bash
docker compose -f swarm/docker-compose.collector-beyla.yml up -d
```

### 4. Deploy Cluster Agent to Swarm

```bash
docker stack deploy -c swarm/docker-compose.swarm-cluster-agent.yml better-stack
```

## Network Communication

- **Cluster Agent → Collector**: Via overlay network on `http://collector:33000`
- **Beyla → Collector**: Via localhost (host network mode)
- **External → Collector**: Via exposed ports on localhost

## Configuration

### Environment Variables

- `COLLECTOR_SECRET` - Authentication token (required)
- `COLLECTOR_HOST` - Hostname of collector container (default: collector)
- `COLLECTOR_PORT` - Port of collector proxy (default: 33000)
- `CLUSTER_COLLECTOR` - Force cluster collector mode
- `SWARM_NETWORKS` - Comma-separated list of networks for cluster agent (optional)

### Cluster Agent Placement

By default, the cluster agent runs on manager nodes. To change this, modify the placement constraints in `swarm/docker-compose.swarm-cluster-agent.yml`:

```yaml
deploy:
  placement:
    constraints:
      - node.role == manager  # or worker, or custom labels
```

## Monitoring

### Check Service Status

```bash
# Collector and Beyla status (on each node)
docker compose -f /opt/better-stack/docker-compose.collector-beyla.yml ps

# Cluster Agent status
docker service ls | grep better-stack
docker service ps better-stack_cluster-agent
```

### View Logs

```bash
# Collector logs (on specific node)
docker compose -f /opt/better-stack/docker-compose.collector-beyla.yml logs collector

# Beyla logs (on specific node)
docker compose -f /opt/better-stack/docker-compose.collector-beyla.yml logs beyla

# Cluster Agent logs
docker service logs better-stack_cluster-agent
```

## Troubleshooting

### Cluster Agent Can't Connect

1. Check if overlay network exists:
   ```bash
   docker network ls | grep better_stack_collector_overlay
   ```

2. Verify collector is accessible:
   ```bash
   curl http://localhost:33000/v1/cluster-agent-enabled
   ```

3. Check cluster agent logs:
   ```bash
   docker service logs better-stack_cluster-agent
   ```

### Network Issues

- Ensure the overlay network is attachable
- Verify firewall rules allow communication on port 33000
- Check that both services are on the same overlay network

## Cleanup

Use the automated script:

```bash
# Uninstall from all nodes
MANAGER_NODE=user@manager-node COLLECTOR_SECRET=$COLLECTOR_SECRET ACTION=uninstall ./deploy-to-swarm.sh
```

Or manually:

```bash
# Remove cluster agent from swarm
docker stack rm better-stack

# Stop collector and beyla (on each node)
docker compose -f /opt/better-stack/docker-compose.collector-beyla.yml down

# Remove overlay network (only after all services are stopped)
docker network rm better_stack_collector_overlay
```

## Rolling Updates

### Update Cluster Agent

```bash
# Update the image
docker build -t betterstack/cluster-agent:latest -f Dockerfile.cluster-agent .

# Update the service
docker service update --image betterstack/cluster-agent:latest better-stack_cluster-agent
```

### Update Collector/Beyla

Use the automated script:

```bash
# Force upgrade on all nodes
MANAGER_NODE=user@manager-node COLLECTOR_SECRET=$COLLECTOR_SECRET ACTION=force_upgrade ./deploy-to-swarm.sh
```

Or manually on each node:

```bash
# Update images
docker compose -f /opt/better-stack/docker-compose.collector-beyla.yml pull

# Recreate containers
docker compose -f /opt/better-stack/docker-compose.collector-beyla.yml up -d
```