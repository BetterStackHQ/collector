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

### Development Tips

- Use `should_run_cluster_collector.rb` exit codes: 0=yes, 1=no, 2=error
- Check `/errors.txt` for persistent error messages
- Disable `fatal_handler` in supervisord.conf for debugging startup issues
- Vector validation: `vector validate -c /path/to/vector.yaml`
