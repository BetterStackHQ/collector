# Build Commands for Better Stack Collector

## Local Build (for development)
```bash
docker build -t better-stack-collector .
```

## Production Build (for Kubernetes cluster)
The Kubernetes cluster runs on amd64 architecture, so always build for that platform:

```bash
# Build for amd64 architecture (required for DO Kubernetes cluster)
docker buildx build --platform linux/amd64 -t better-stack-collector:latest . --load

# Tag for DigitalOcean registry
# Note: Repository name is "better-stack-collector" not "collector"
docker tag better-stack-collector:latest registry.digitalocean.com/betterstack-collector/better-stack-collector:latest

# Login to DigitalOcean registry (if needed)
doctl registry login

# Push to registry
docker push registry.digitalocean.com/betterstack-collector/better-stack-collector:latest

# Restart the DaemonSet to pull new image
kubectl rollout restart daemonset/better-stack-collector -n default
```

## Important Notes
- The Kubernetes nodes are amd64 (x86_64) architecture
- The helm chart uses repository: `registry.digitalocean.com/betterstack-collector/better-stack-collector`
- Always use `--platform linux/amd64` when building for production
- The image tag should be `latest` as configured in the helm chart