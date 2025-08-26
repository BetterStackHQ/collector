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

- Versions stored in `/versions/YYYY-MM-DDTHH:MM:SS/` directories
- Active configuration via symlink: `/vector.yaml` → `/versions/[timestamp]/vector.yaml`
- Atomic updates: download → validate → promote → reload Vector (HUP signal)
- Security: Validates configs to prevent `command:` directives

### Process Management

**Collector Container** - Supervisor manages:
- Vector (main data pipeline)
- Ruby proxy (serves configuration endpoints)
- Ruby updater (checks for configuration updates)

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
- `TLS_DOMAIN` (optional) - Fully-qualified domain name for TLS certificate management
- `PROXY_PORT` (required with TLS_DOMAIN) - Host port for upstream proxy (cannot be 80, 33000, 34320, or 39090)

### TLS Certificate Management (Certbot)

When `TLS_DOMAIN` environment variable is set, the collector automatically manages TLS certificates via Let's Encrypt:

#### Configuration
- **TLS_DOMAIN**: Fully-qualified domain name (e.g., `collector.example.com`)
- **PROXY_PORT**: Host port for upstream proxy traffic (required when TLS_DOMAIN is set)
  - Must not be 80 (reserved for ACME validation)
  - Must not conflict with internal ports (33000, 34320, 39090)

#### Certificate Behavior
- **Initial acquisition**: Attempts every 10 minutes until successful
- **Renewals**: Checked every 6 hours once a valid certificate exists
- **Certificate locations**:
  - `/etc/ssl/<TLS_DOMAIN>.pem` - Symlink to fullchain certificate
  - `/etc/ssl/<TLS_DOMAIN>.key` - Symlink to private key
  - Both files have 0644 permissions for Vector access
- **Vector reload**: Automatically signaled (HUP) after certificate updates

#### Port Exposure
When TLS is configured, the container exposes:
- Port 80: ACME HTTP-01 validation (certbot standalone mode)
- Port specified by PROXY_PORT: Upstream proxy traffic
- Existing localhost-only ports remain unchanged (33000, 34320)

#### Troubleshooting TLS Issues
- Check certbot logs: `docker logs <container> | grep certbot`
- Verify domain DNS points to host's public IP
- Ensure port 80 is accessible from internet for ACME validation
- Certificate status: `docker exec <container> certbot certificates`
- Manual renewal test: `docker exec <container> certbot renew --dry-run`

### Development Tips

- Use `should_run_cluster_collector.rb` exit codes: 0=yes, 1=no, 2=error
- Check `/errors.txt` for persistent error messages
- Disable `fatal_handler` in supervisord.conf for debugging startup issues
- Vector validation: `vector validate -c /path/to/vector.yaml`
