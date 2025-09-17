## Building Better Stack Collector locally

Run the mock test server locally with

```
INGESTING_HOST=s123456.eu-nbg-2.betterstackdata.com COLLECTOR_SECRET=your_real_collector_secret SOURCE_TOKEN=your_real_production_source_token ruby test/test_server.rb
```

and

```
ngrok http 3010
```

### Using Docker Compose for local development

Build and run:

```bash
docker-compose down
docker-compose build
export HOSTNAME
COLLECTOR_SECRET=your_collector_secret_here \
BASE_URL=https://telemetry.betterstack.ngrok.dev \
docker-compose up
```

- See live Vector stats: `docker exec -it better-stack-collector vector top`
- See live Beyla data in Vector: `docker exec -it better-stack-collector vector tap 'beyla_otel*'`

Tail collector logs:

- Collector container: `docker exec -it better-stack-collector bash -c "tail -f /var/log/supervisor/*"`
- Beyla container: `docker logs -f better-stack-beyla`

## Development troubleshooting

- **Docker image failing to start because one of the processes crashes?**
  Disable the `fatal_handler` in supervisor.conf, start the collector again, log into the container and look into /var/log/supervisor/\* logs.

## Environment Variables

- `COLLECTOR_SECRET` (required): Your Better Stack collector secret
- `BASE_URL` (optional): Better Stack base URL (default: <https://telemetry.betterstack.com>)
- `CLUSTER_COLLECTOR` (optional): Should we collect metrics from databases in the cluster? Only one collector instance per cluster should have the variable set to true. By default betterstack.com chooses one of the collector instances automatically, use this ENV variable if you want to override this behavior (default: false)

### Domain-based TLS (optional)

- SSL certificate domain is now managed remotely via Better Stack API (no longer uses `TLS_DOMAIN` env var)
- `PROXY_PORT` (optional): Host port mapped to the in-container proxy. Must be an integer and must not equal `80`, `33000` or `34320`.
- Domain configuration:
  - Domain is received in `ssl_certificate_host.txt` file with other configuration files
  - Stored at `/etc/ssl_certificate_host.txt` in the container
  - Certbot reads domain from this file instead of environment variable
- Certificate locations after issuance or renewal:
  - `/etc/ssl/<domain>.pem` (symlink to fullchain.pem)
  - `/etc/ssl/<domain>.key` (symlink to privkey.pem)
- Vector reload behavior:
  - On successful issuance or renewal, Vector is signaled (HUP) to reload without container restart.
  - When domain changes, Vector validation is skipped for one ping cycle (30s) to allow certificate acquisition
- Retry cadence:
  - Issuance attempts: immediate on domain change, then every 10 minutes until a valid cert exists
  - Renewals: every 6 hours when a valid cert exists

## Topology

- Beyla container talks to collector via host network on port 34320. Only localhost is allowed to connect to this port.
- Cluster agent and node agent run in the beyla container and connect to the collector via host network on port 33000.
- Cluster agent obtains configuration from the collector via the /v1/config endpoint.
- Cluster agent checks if it should run via the /v1/cluster-agent-enabled endpoint.

## Seccomp

- On Docker versions `< 20.10.10`, seccomp forbids the use of `clone3` syscall, which is required by Tokio (in Vector)
- For these versions, we ship a custom seccomp profile that allows the use of `clone3` syscall via `docker-compose.seccomp.yml` + `collector-seccomp.json`
- For Docker versions `>= 20.10.10`, we use the default seccomp profile
