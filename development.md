## Building Better Stack Collector locally

### Using Docker Compose for local development

Build and run:

```bash
docker compose down
docker compose build
export HOSTNAME
COLLECTOR_SECRET=your_collector_secret_here \
BASE_URL=https://telemetry.betterstack.ngrok.dev \
docker compose up
```

- See live Vector stats: `docker exec -it better-stack-collector vector top`
- See live eBPF data in Vector: `docker exec -it better-stack-collector vector tap 'ebpf_otel*'`

Tail collector logs:

- Collector container: `docker exec -it better-stack-collector bash -c "tail -f /var/log/supervisor/*"`
- Host agent container: `docker logs -f better-stack-collector-host`

### Pinning the eBPF agent image

`ebpf/Dockerfile` uses one build argument, `EBPF_AGENT_IMAGE`, containing the
complete image reference: `ghcr.io/betterstackhq/ebpf-agent:<version>@sha256:<digest>`.
The version tag is human-readable metadata; the OCI index digest selects the
bytes for both `linux/amd64` and `linux/arm64`. The source stage uses the argument
directly, so a complete digest reference is also valid as a Docker build override:

```bash
docker build --file ebpf/Dockerfile \
  --build-arg EBPF_AGENT_IMAGE="$EBPF_AGENT_IMAGE" .
```

To update the default, log in to GHCR with an account that can read the
`ebpf-agent` package (`docker login ghcr.io`). Inspect the desired version,
then replace the complete reference in the Dockerfile with its version and index digest:

```bash
docker buildx imagetools inspect ghcr.io/betterstackhq/ebpf-agent:<version>
python3 .github/scripts/check_ebpf_image.py
```

The version-sync workflow resolves the version tag separately and requires it to
match the pinned digest. It then reads the pinned image's platform configurations
from the registry and requires their declared versions to match the reference.
Missing metadata, registry access failures, and tag/digest or version mismatches
fail the check; matching text in a Dockerfile is not sufficient. These checks
verify the checked-in default, not arbitrary command-line build overrides, and
do not replace publication provenance or runtime checks.

Offline regression checks for the reference parser and registry metadata rules:

```bash
python3 -m unittest discover -s .github/scripts -p 'test_check_ebpf_image.py'
```

## CI candidates and advisory gauntlet runs

The image workflow keeps the existing publication flow: pull requests publish
`pr-<number>`, main publishes `canary`, and version tags publish the version and
`latest`. Main collector versions retain the `-canary-<short-sha>` suffix; release
tags must match the checked-in collector version. Before either push-event build,
a registry prerequisite verifies the checked-in agent version tag, pinned digest
and platform versions. The existing version-sync checks and PR behavior remain.

Every build also publishes an immutable
`candidate-<run-id>-<attempt>-<full-source-sha>` reference and uploads the build
action's exact output index digest in an attempt-bound artifact. No later lookup
of `canary` or `latest` supplies candidate identity. Candidate tags accumulate in
GHCR; operator-managed retention must preserve digests needed by queued runs and
published versions.

`github-release.yml` retains the existing tag-CI release flow: the image and
docs-script workflows must succeed, and the tag must identify a commit on main.
Release creation does not depend on the advisory workflow or service.

### Advisory submission and configuration

The separate `Submit advisory gauntlet` workflow runs after a successful image
workflow for main or a version tag, never for pull requests. It checks out the
exact upstream source SHA and downloads only that run's attempt-bound build
artifacts. It resolves both platform child digests from the captured immutable
indexes. The full `components.agent` identity comes from the default
`EBPF_AGENT_IMAGE` in that source's eBPF Dockerfile, not an environment override.
Registry verification checks the component version tag and platform versions,
plus both built images' index/child/config digests, source labels and expected
versions, including the collector runtime environment version.

The client submits `{"candidate": candidate}` without provider receipts,
provider API credentials or an attestation exchange. The candidate retains its
kind, CI origin, source repository/SHA, profile/revision, exact image and component
identities, and configuration bundle hash. Submission is idempotent on the
canonical repository, source SHA, bundle hash and profile revision.

| Location | Required advisory values |
|---|---|
| Repository variables | `GAUNTLET_PROFILE`, `GAUNTLET_PROFILE_REVISION`, `GAUNTLET_CONFIG_BUNDLE_HASH`: exact deployed profile identity, without defaults |
| Repository secrets | `GAUNTLET_URL`: HTTPS service origin only; `GAUNTLET_ACCESS_CLIENT_ID`, `GAUNTLET_ACCESS_CLIENT_SECRET`: Access service credentials permitted to trigger/read runs |
| Repository secrets | `GAUNTLET_REGISTRY_READ_USER`, `GAUNTLET_REGISTRY_READ_TOKEN`: read-only access to both candidate packages and the pinned component package |

Existing build secrets (`DEPOT_PROJECT_ID`, `DEPOT_API_TOKEN`) remain confined
to the image build workflow; they are not sent to the gauntlet service.
The advisory workflow uses its built-in `GITHUB_TOKEN` only to download the
upstream CI artifacts. Configure the service, runnable profile/configuration,
Access and registry credentials before expecting successful submissions. This
working tree does not imply that deployment or repository configuration is live.
There is no enable-variable or missing-secret success fallback: missing/invalid
configuration or unavailable service/registry access visibly fails the advisory
job, without blocking image publication or GitHub releases.

Submission prints the durable run URL and exits. Dashboard/history and service
notifications provide advisory start, finish and failure results; an operator
decides how to act on them. No run verdict automatically approves, promotes or
authorizes a release. Keep the service URL in a GitHub secret so GitHub masks its
hostname in public logs. Candidate/submission artifacts are retained for 90 days
after successful submission.

For recovery of a partially failed image matrix, use **Re-run all jobs** on the
upstream build workflow. Advisory submission requires both image artifacts from
the triggering attempt; a failed-jobs-only retry can leave one missing and fails
submission visibly rather than silently assembling images from different attempts.

### Shared client and safe local checks

`.github/scripts/gauntlet.py` is a standalone stdlib client using `skopeo` for
read-only OCI inspection. Service credentials are environment-only:
`GAUNTLET_URL`, `CF_ACCESS_CLIENT_ID`, `CF_ACCESS_CLIENT_SECRET`. Bundle and
submit also require the three profile variables above and reject candidates
that differ from the configured profile. Only the advisory workflow runs this
client; publication never calls it or depends on its configuration.

Registry commands use `REGISTRY_AUTH_FILE` when set and validate repository and
reference inputs. API requests require an HTTPS origin, reject redirects without
forwarding credentials, and bound response size. GET requests have a 30-second
timeout; POST has a 300-second timeout. Submission makes at most three identical
idempotent POST attempts, with 5- and 10-second backoffs, only for transport
timeout/disconnection/HTTP-protocol errors or HTTP 502/503/504/524.
Authentication, validation and other HTTP failures are not retried. Retries do
not rebuild images, change the candidate, or turn a failed submission into success.

The CLI commands are:

```text
bundle --kind collector --repository OWNER/REPO --source-sha SHA --image collector=REPO@DIGEST --image collector-ebpf=REPO@DIGEST --dockerfile ebpf/Dockerfile --output candidate.json
prerequisite --candidate candidate.json --ref REF
submit --candidate candidate.json --output submission.json
```

Single-image consumers use `--kind agent --image agent=REPO@DIGEST` without
`--dockerfile`. Consumers of the standalone client must validate and fetch an
actually published full 40-hex collector commit, never a moving branch or a
guessed revision. No concrete published client revision is implied by this tree.

Offline smoke commands (no registry reads/writes, builds or deployment):

```bash
python3 .github/scripts/gauntlet.py --help
python3 -m unittest discover -s .github/scripts -p 'test_gauntlet.py'
python3 -m unittest discover -s .github/scripts -p 'test_check_ebpf_image.py'
```

An explicitly authorized read-only service/registry smoke requires Python 3,
`skopeo`, registry read authentication and the advisory environment above. Use
`bundle` with actual retained build-output digests, then `prerequisite` as above.
`submit` creates a durable run and is not a read-only smoke. Offline checks
substitute transports and cannot certify live configuration, registry access or
runtime results.

## Development troubleshooting

- **Docker image failing to start because one of the processes crashes?**
  Disable the `fatal_handler` in supervisor.conf, start the collector again, log into the container and look into /var/log/supervisor/\* logs.

- **Vector loses configuration and shows only console sink?**
  This indicates Vector lost access to `/vector-config/current/`. The collector includes several recovery mechanisms:
  - Health check (`healthcheck.sh`) runs every 30s via Docker/Kubernetes health probes
  - Container/pod restarts after 3 consecutive health check failures
  - Supervisor will retry Vector 3 times before triggering container restart via fatal_handler (in case Vector reports exit code 3+ on restart)
  - Check Vector sinks: `docker exec -it better-stack-collector curl -s http://localhost:8686/graphql -H "Content-Type: application/json" -d '{"query":"{ sinks { edges { node { componentId } } } }"}'`

- **Debugging configuration updates:**
  - Check updater logs: `docker exec -it better-stack-collector tail -f /var/log/supervisor/updater.out.log`
  - Verify current config: `docker exec -it better-stack-collector ls -la /vector-config/current/`
  - Check symlink target: `docker exec -it better-stack-collector readlink /vector-config/current`

## Environment Variables

- `COLLECTOR_SECRET` (required): Your Better Stack collector secret
- `BASE_URL` (optional): Better Stack base URL (default: <https://telemetry.betterstack.com>)
- `CLUSTER_COLLECTOR` (optional): Should we collect metrics from databases in the cluster? Only one collector instance per cluster should have the variable set to true. By default betterstack.com chooses one of the collector instances automatically, use this ENV variable if you want to override this behavior (default: false)

## Topology

- OBI sends traces to the collector via host network on port 34320. Only localhost is allowed to connect to this port.
- Runtime-delivered supervisor configuration selects either Node Agent, which sends metrics to the collector on port 33000, or Better Stack eBPF Agent, which serves Prometheus metrics at `http://localhost:39100/metrics`.
- Cluster agent connects to the collector on port 33000.
- Cluster agent obtains configuration from the collector via the /v1/config endpoint.
- Cluster agent checks if it should run via the /v1/cluster-agent-enabled endpoint.

## Seccomp

- On Docker versions `< 20.10.10`, seccomp forbids the use of `clone3` syscall, which is required by Tokio (in Vector)
- For these versions, we ship a custom seccomp profile that allows the use of `clone3` syscall via `docker-compose.seccomp.yml` + `collector-seccomp.json`
- For Docker versions `>= 20.10.10`, we use the default seccomp profile
