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

## CI candidates and release eligibility

The image workflow builds both architectures of both images from the same source
SHA. Every main push, version-tag push and pull-request build creates immutable
`candidate-<run-id>-<attempt>-<full-source-sha>` references; advancing main never
skips a candidate build or submission. Pull requests additionally publish the
mutable `pr-<number>` aliases and do not submit or promote. Main collector versions
retain the `-canary-<short-sha>` suffix; release tags must match the checked-in
version. Version tags may include prereleases but not `+build` metadata, which OCI
tags cannot represent.

Candidate tags accumulate in GHCR for both agent and collector, including PR
candidates; this workflow does not expire them. Package storage and full tag-list
lookups during publication grow with that history. Plan operator-managed
retention without deleting digests needed by queued submissions, retained proofs,
release assets or published versions; no automatic garbage collection is provided.

The receipt records the build action's output index digest and both actual
platform child digests, not a later lookup of `canary`. The full
`components.agent` image identity comes from the default `EBPF_AGENT_IMAGE` in the
actual eBPF Dockerfile. CI supplies no build-argument override. The service must
independently select an archived eligible agent proof for that exact image and
configuration; a client-side eligibility flag cannot authorize inclusion.

### Required configuration and rollout order

Configure these before merging/enabling the image workflow. Missing configuration,
credentials, registry metadata or service/provider evidence fails CI; there is no
success fallback or CI bootstrap bypass.

| Location | Required values |
|---|---|
| Repository variables | `GAUNTLET_PROFILE`, `GAUNTLET_PROFILE_REVISION`, `GAUNTLET_CONFIG_BUNDLE_HASH`: exact deployed profile identity, without defaults |
| Repository secrets | `GAUNTLET_URL`: HTTPS service origin only; `GAUNTLET_ACCESS_CLIENT_ID`, `GAUNTLET_ACCESS_CLIENT_SECRET`: Access service credentials permitted to trigger/read runs |
| Repository secrets | `GAUNTLET_REGISTRY_READ_USER`, `GAUNTLET_REGISTRY_READ_TOKEN`: read-only access to both candidate packages and the pinned component package |
| Existing build secrets | `DEPOT_PROJECT_ID`, `DEPOT_API_TOKEN`; package-write permission on the build and alias/publication jobs' `GITHUB_TOKEN` |
| Service configuration | Authorized source/image repositories, read-only GitHub/provider and registry credentials, artifact download hosts, and the exact provenance policy below |

Deploy the matching service policy and runnable, versioned profile/configuration
first. Complete the operator-approved server-side initial base validation and
ordinary eligible agent validation before submitting a collector containing that
agent. Bootstrap records cannot authorize release. Configure Access, registry
access and repository values, then merge the workflow/client. Consumers of the
standalone client must pin an actually published full 40-hex collector commit in
`GAUNTLET_CLIENT_REVISION`, validate that value **before** fetching
`https://raw.githubusercontent.com/BetterStackHQ/collector/<revision>/.github/scripts/gauntlet.py`,
and never default to a branch or a guessed revision. No concrete published client
revision is implied by this working tree.

The collector profile's `provenance_policy` must contain:

```json
{
  "provider": "github",
  "workflow_path": ".github/workflows/docker-build.yml",
  "main_branch": "main",
  "release_tag_pattern": "v[0-9]+[.][0-9]+[.][0-9]+(?:-[0-9A-Za-z.-]+)?",
  "build_jobs": ["build-collector", "build-ebpf"],
  "receipt_job": "gauntlet-receipt",
  "suite_jobs": {"collector-image-prerequisites": "collector-prerequisites"},
  "prerequisites": {
    "collector-image-prerequisites": [
      "collector.registry.agent-version",
      "collector.registry.build-identity"
    ]
  }
}
```

Those are the actual provider display names, including the matrix build names.
The prerequisite command verifies the agent version tag against its pinned index
and both platform version configurations, then verifies both built images'
index/child/config digests, source labels and expected build versions (including
the collector runtime environment version). Its summary contains exactly the two
IDs above only after those checks execute successfully. These are registry/build
prerequisites, **not** runtime coverage. The service separately verifies the
CI-owned artifact and successful upstream job attempts; an arbitrary summary or
green check label is not provenance.

### Submission, waiting and publication

`gauntlet-receipt` uploads `gauntlet-receipt.json` in
`gauntlet-receipt-<run-id>-<attempt>` before the downstream submit job uses the
provider-returned artifact ID. The JSON binds the source, full bundle and executed
prerequisite IDs/counts. Submission is idempotent on the canonical repository,
source SHA, bundle hash and profile revision. Main submission prints the durable
run URL and exits; submission is not approval. Keep the URL in a GitHub secret so
GitHub masks its hostname in public logs. Evidence remains in the protected
service and CI artifacts.

Only alias jobs share concurrency; candidate builds/receipts/submissions are
independent. Inside the serialized canary job, one remote-main tip check at
**publication start** linearizes the pair: an already-stale queued job skips both
aliases, so it cannot roll a newer published pair backward. Once that check passes,
the job finishes both aliases even if main advances between writes; it does not
deliberately split the pair on a concurrent push. Registry writes are not atomic:
a transport failure can still leave a partial pair and fails CI. Canary is a
candidate convenience, never release approval. Both alias jobs use GitHub's documented
[`queue: max`](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency)
with cancellation disabled, so new canaries do not replace pending releases.
The provider limit is 100 pending jobs; overflow cancels additional jobs and
requires operator recovery, not a claimed successful publication.

Release waiters poll every 30 seconds for up to 330 minutes in a 360-minute
GitHub-hosted job, allowing the normal four-to-five-hour window. They have no
registry-write credential or package-write permission. Transport failures and
HTTP 502/503/504/524 retry on the existing polling interval within the same absolute
deadline; they never restart the timeout or rerun scientific work. Timeout,
authentication, identity, validation and other API failures block publication
without cancelling the durable run. A completed all-passed run whose verdict is
still `incomplete` and whose evidence is not yet archived continues polling;
eligibility is never inferred from completion alone. Actual
failed/error/interrupted/cancelled outcomes fail immediately.

The successful submission is retained as `gauntlet-submission-<run-id>` without
a transport-attempt suffix. Re-running only the waiter, canary or publisher reads
that retained submission and rechecks its source/run, required current
profile/configuration and exact service bundle. A full new build/receipt attempt
overwrites that run's retained submission only after successful submission.
Build, prerequisite and receipt proof artifacts remain attempt-bound.

Submission uses the actual upstream receipt job's attempt, never the current
transport attempt relabelled as build evidence. A submission-only workflow rerun
can locate its original prerequisites, but the service's current-attempt
provenance policy may reject the older receipt. If no successful submission was
retained, create a complete new build/prerequisite/receipt attempt rather than
forging current-attempt proof. Transport recovery within a submit invocation uses
the same request and idempotency key as described below.

Only the downstream `publish` job authenticates release writes. It also retains
the existing docs-script release gate. Immediately before publication it rechecks
the service's archived `eligible` verdict, exact run/bundle/profile/config and
contract/workload revisions, the Git tag/source and main ancestry. It copies all
existing image digests with digest preservation, then verifies the destination
index and both children. No release rebuild occurs. Existing version aliases
must already name those same bytes; they cannot be overwritten with other bytes.
Stable `latest` updates require nondecreasing version **and** source ancestry
across both images; older completions keep their version aliases but skip
`latest`. Prereleases never update `latest`. Existing latest images must expose
consistent stable `org.opencontainers.image.version` and full
`org.opencontainers.image.revision` labels on both platforms; absent or conflicting
metadata blocks publication rather than guessing ordering. Serialize all external
writers with this workflow or disable them. A network failure between the two
registry writes is reported, never treated as atomic publication.

GitHub releases are created only after gated registry publication. The separate
build-success-only release workflow is removed.

### Shared client and safe local checks

`.github/scripts/gauntlet.py` is a standalone stdlib client using `skopeo` for OCI
inspection/copy and `git` for publication ancestry. API credentials are
environment-only: `GAUNTLET_URL`, `CF_ACCESS_CLIENT_ID`,
`CF_ACCESS_CLIENT_SECRET`. All service-bound commands also require the three
profile variables above and reject retained candidates that differ from them.
Registry commands use `REGISTRY_AUTH_FILE` when set. API requests require HTTPS,
reject redirects without forwarding credentials, bound response size, and fail
nonzero on unavailable evidence. GET requests have a 30-second timeout; the
synchronous provenance-verifying POST has a 300-second timeout. Submission makes
at most three identical idempotent POST attempts, with 5- and 10-second backoffs,
only for transport timeout/disconnection/HTTP-protocol errors or HTTP 502/503/504/524.
Authentication, validation and other HTTP failures are not retried. These retries
do not rerun tests, change the candidate/receipt, or turn missing proof into success.
Cloudflare's [524 response](https://developers.cloudflare.com/support/troubleshooting/http-status-codes/cloudflare-5xx-errors/error-524/)
is an origin-response timeout, not a successful submission or validation failure.

The CLI commands are:

```text
bundle --kind collector --repository OWNER/REPO --source-sha SHA --image collector=REPO@DIGEST --image collector-ebpf=REPO@DIGEST --dockerfile ebpf/Dockerfile --output candidate.json
prerequisite --candidate candidate.json --ref REF --output collector-prerequisites.json
receipt --candidate candidate.json --provider github --run-id ID --run-attempt ATTEMPT --ref REF --summary collector-prerequisites.json --output gauntlet-receipt.json
submit --candidate candidate.json --provider github --run-id ID --run-attempt ATTEMPT --artifact-id ARTIFACT --output submission.json
wait --submission submission.json --timeout-seconds 19800
```

Single-image consumers use `--kind agent --image agent=REPO@DIGEST` without
`--dockerfile`. Depot receipts use opaque provider IDs plus
`--prerequisite-attempts attempts.json` (exact upstream job-key → actual attempt-ID
map); GitHub IDs are positive integers. Summaries are a standard suite object or
array; repeat `--summary` for multiple files. Unknown/missing/duplicate IDs,
failed/skipped checks, wrong SHA and inconsistent executed counts are rejected.
The trusted server policy, not the caller's summary, defines the required set.

Consumers that cannot retain every pending cross-version publication job can
separate phases: `promote --tag vSEMVER --skip-latest` writes only immutable
version aliases, while `promote --tag vSEMVER --latest-only` requires those exact
version aliases to exist first and writes only stable `latest`. Both retain all
eligibility, source and digest checks. Serialize the first phase per version and
the second across all stable releases; canary may use its own lock because it
writes only `canary`. A coalescing latest-only job must reselect the newest
actually published stable release, rather than using its potentially stale
triggering release. Retain the real `gauntlet-submission.json` as a release asset
and verify that asset's repository, tag commit and archived eligible exact bundle.
After checking out the selected candidate source, use `--latest-only
--published-release`: this permits the triggering SHA/run ID to differ from the
selected published release, but retains repository/current-profile/config checks,
exact server eligibility, local and remote tag/source/ancestry binding, and the
already-published semver/index/children checks. The flag is invalid outside
latest-only publication and cannot authorize new version aliases.

Offline smoke commands (no registry reads/writes, builds or deployment):

```bash
python3 .github/scripts/gauntlet.py --help
python3 -m unittest discover -s .github/scripts -p 'test_gauntlet.py'
```

For an explicitly authorized read-only service/registry smoke, set the required
environment and use `bundle` with **actual retained build-output digests**, then
`prerequisite` and `receipt` as above. `submit` creates a durable run; it is not a
read-only smoke. `promote --submission submission.json --tag canary|vSEMVER`
**writes the registry** and belongs only in the gated, serialized CI job, never a
local smoke. The offline checks substitute transports and cannot certify live
provider authorization, job limits, registry access or runtime eligibility.

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
