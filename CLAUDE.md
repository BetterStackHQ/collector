# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Better Stack Collector is a Docker-based monitoring solution that collects metrics, logs, and traces using multiple collection agents (Vector, Coroot Node/Cluster Agents, and Beyla). All components are managed by Supervisor within a single container.

## Common Development Commands

### Build and Run
```bash
# Build Docker image
docker build -t better-stack-collector .

# Run tests
bundle exec rake test

# Start local test server (requires env vars)
INGESTING_HOST=s123456.eu-nbg-2.betterstackdata.com SOURCE_TOKEN=<token> ruby test/test_server.rb

# Expose test server via ngrok
ngrok http 3010
```

### Testing
```bash
# Run all tests
rake test

# Run specific test file
ruby -Ilib:test test/better_stack_client_test.rb

# Run with verbose output
rake test TESTOPTS="-v"
```

## Architecture Overview

### Core Components

1. **updater.rb** - Runs a 30-second loop calling `client.ping` to check for configuration updates
2. **proxy.rb** - WEBrick server on port 33000 providing:
   - `/v1/config` - Latest database configuration (databases.json)
   - `/v1/cluster-agent-enabled` - Returns "yes" or "no" based on BetterStackClient.cluster_collector?
   - `/v1/metrics` - Proxy to Vector metrics (localhost:39090)
3. **engine/better_stack_client.rb** - API client handling all Better Stack communication
4. **engine/utils.rb** - Shared utilities for version management, file operations, and error handling

### Configuration Management

- Configuration stored in `/vector-config/` directory structure:
  - `/vector-config/current/` - Active configuration directory
  - `/vector-config/current/vector.yaml` - Main Vector configuration
  - `/vector-config/current/manual.vector.yaml` - Optional manual overrides
  - `/vector-config/current/kubernetes-discovery/` - Kubernetes discovery configs
  - `/vector-config/latest-valid-upstream/` - Latest validated upstream configuration
- Version management:
  - New configs created in `/vector-config/new_[timestamp]/` directories
  - Validated configs promoted to `/vector-config/current/`
  - Upstream files stored in `/versions/[timestamp]/` but copied to vector-config for use
- Atomic updates: download → validate → promote → reload Vector (HUP signal)
- Security: Validates configs to prevent `command:` directives

### Process Management

**Collector Container** - Supervisor manages:
- Vector (main data pipeline)
- Ruby proxy (serves configuration endpoints)
- Ruby updater (checks for configuration updates)
- Certbot (TLS certificate management)

**Beyla Container** - Supervisor manages:
- Beyla (eBPF application traces)
- Node Agent (system metrics collection)
- Cluster Agent (Kubernetes/database monitoring)
- Dockerprobe (container metadata collection)

Logs available in `/var/log/supervisor/*` in each container

### Container Communication

- **Beyla → Collector**: Via host network mode
  - Cluster Agent polls `http://localhost:33000/v1/cluster-agent-enabled` to check if it should run
  - Cluster Agent fetches database config from `http://localhost:33000/v1/config`
  - Node Agent sends metrics to `http://localhost:33000`
- **Shared Volume**: `docker-metadata` volume for enrichment tables
  - Dockerprobe writes container metadata CSV
  - Vector reads metadata for log/metric enrichment

### API Communication Patterns

1. **Ping**: Returns 204 (no updates) or 200 (new version available)
2. **Configuration Update**: Downloads all files, validates, then atomically switches
3. **Cluster Collector Detection**: Returns 204/200 (yes) or 409 (no)

### Testing Approach

- Minitest framework with WebMock for API stubbing
- Test files in `test/` directory
- Comprehensive coverage including error scenarios and edge cases

### Key Environment Variables

- `COLLECTOR_SECRET` (required) - Authentication token
- `BASE_URL` - API endpoint (default: https://telemetry.betterstack.com)
- `CLUSTER_COLLECTOR` - Force cluster collector mode
- `INGESTING_HOST`, `SOURCE_TOKEN` - Required for test server
- `PROXY_PORT` (optional) - Host port for upstream proxy (cannot be 80 when USE_TLS is set, cannot be 33000, 34320, or 39090)
- `USE_TLS` (optional) - Indicates TLS should be used; when set, port 80 will be exposed for ACME validation. Only used by install.sh.

### TLS Certificate Management (Certbot)

The collector automatically manages TLS certificates via Let's Encrypt when configured remotely:

#### Configuration
- **Remote Management**: SSL certificate domain is now configured remotely via Better Stack API
- **ssl_certificate_host.txt**: Domain configuration file downloaded with other configs
- **PROXY_PORT**: Host port for upstream proxy traffic (optional)
  - Must not be 80 (reserved for ACME validation)
  - Must not conflict with internal ports (33000, 34320, 39090)

#### Certificate Behavior
- **Domain changes**: When domain changes, certbot restarts immediately to acquire new certificate
- **Grace period**: Vector validation skipped for one ping cycle (30s) when domain changes
- **Initial acquisition**: Attempts immediately on domain change, then every 10 minutes if failed
- **Renewals**: Checked every 6 hours once a valid certificate exists
- **Certificate locations**:
  - `/etc/ssl/<domain>.pem` - Symlink to fullchain certificate
  - `/etc/ssl/<domain>.key` - Symlink to private key
  - `/etc/ssl_certificate_host.txt` - Current domain configuration
  - Certificate files have 0644 permissions for Vector access
- **Vector reload**: Automatically signaled (HUP) after certificate updates

#### Port Exposure
The container always exposes:
- Port 80: ACME HTTP-01 validation (certbot standalone mode) - always available for potential use
- Port specified by PROXY_PORT (if configured): Upstream proxy traffic
- Existing localhost-only ports remain unchanged (33000, 34320)

#### Troubleshooting TLS Issues
- Check current domain: `docker exec <container> cat /etc/ssl_certificate_host.txt`
- Check certbot logs: `docker logs <container> | grep certbot`
- Verify domain DNS points to host's public IP
- Ensure port 80 is accessible from internet for ACME validation
- Certificate status: `docker exec <container> certbot certificates`
- Manual renewal test: `docker exec <container> certbot renew --dry-run`
- Force certbot restart: `docker exec <container> supervisorctl restart certbot`

### Vector Crash Recovery Mechanisms

The collector includes multiple layers of protection against Vector configuration loss:

#### 1. Configuration Validation at Startup (`vector.sh`)
- Validates `/vector-config/current/` directory exists before starting Vector
- Checks for actual YAML config files (not just directory presence)
- Attempts to restore from `/vector-config/latest-valid-upstream/` if current is missing
- Exits with code 127 (critical failure) if no configs found, triggering supervisor retry

#### 2. Atomic Configuration Updates (`engine/vector_config.rb`)
- Uses symlinks for `/vector-config/current` instead of moving directories
- Creates temp symlink first, then atomically renames to 'current'
- Backs up previous config to 'previous' link before switching
- Restores backup if promotion fails, preventing partial states

#### 3. Supervisor Restart Policy (`supervisord.conf`)
- `startretries=3`: Attempts 3 restarts before giving up
- `startsecs=10`: Vector must stay up 10 seconds to be considered started
- `stopwaitsecs=30`: Gives Vector 30 seconds for graceful shutdown
- `exitcodes=0,1,2`: Only retries for normal errors, not persistent failures
- Exit codes 3+ trigger FATAL state → container restart via fatal_handler

#### 4. Health Monitoring (`healthcheck.sh`)
- **Docker Compose/Swarm**: Health check runs every 30s, container restarts after 3 consecutive failures
- **Kubernetes**: Liveness probe runs every 30s, pod restarts after 3 consecutive failures
- Checks Vector's `/health` endpoint and GraphQL API sink configuration
- Detects unhealthy states:
  - Vector not responding
  - No sinks configured
  - Console-only sink (indicates lost configuration)
  - Missing Better Stack HTTP sinks (warning only)
- Returns exit code 0 (healthy) or 1 (unhealthy)

### Known Issues and Solutions

**Problem**: Vector loses configuration after SIGHUP reload in Kubernetes
- **Cause**: Vector loses filesystem access to `/vector-config/current/` directory
- **Symptoms**: Vector running with console-only sink, buffer directory missing
- **Recovery**: Health check detects and restarts Vector, or pod restarts after retries exhausted

### Development Tips

- Use `should_run_cluster_collector.rb` exit codes: 0=yes, 1=no, 2=error
- Check `/errors.txt` for persistent error messages
- Disable `fatal_handler` in supervisord.conf for debugging startup issues
- Vector validation: `vector validate -c /path/to/vector.yaml`
- Vector config location: `/vector-config/current/vector.yaml` (not `/vector.yaml`)
- Monitor Vector sinks: `curl -s http://localhost:8686/graphql -H "Content-Type: application/json" -d '{"query":"{ sinks { edges { node { componentId } } } }"}'`
