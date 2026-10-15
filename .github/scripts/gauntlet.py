"""CI receipts and exact-digest promotion. Python stdlib + skopeo + git only."""

import argparse
import hashlib
import http.client
import json
import os
from pathlib import Path
import re
import subprocess
import socket
import time
from urllib.parse import quote, urlsplit


SHA = re.compile(r"[0-9a-f]{40}")
DIGEST = re.compile(r"sha256:[0-9a-f]{64}")
REPOSITORY = re.compile(r"[a-z0-9.-]+(?::[0-9]+)?/[a-z0-9._/-]+")
VERSION = re.compile(r"v?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-([0-9A-Za-z.-]+))?")
PLATFORMS = {"linux/amd64", "linux/arm64"}
COLLECTOR_CHECKS = ["collector.registry.agent-version", "collector.registry.build-identity"]
MAX_BYTES = 16 * 1024 * 1024


class TransientAPIError(ConnectionError):
    """An idempotent submission or bounded waiter may retry this transport failure."""


def require(condition, message):
    if not condition:
        raise ValueError(message)


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()


def digest(raw):
    return "sha256:" + hashlib.sha256(raw).hexdigest()


def hashed(value):
    return hashlib.sha256(canonical(value)).hexdigest()


def pairs(items):
    result = {}
    for key, value in items:
        require(key not in result, "duplicate JSON key")
        result[key] = value
    return result


def decode(raw):
    require(len(raw) <= MAX_BYTES, "JSON exceeds byte limit")
    return json.loads(raw, object_pairs_hook=pairs,
                      parse_constant=lambda _: require(False, "nonfinite JSON value"))


def load(path):
    return decode(Path(path).read_bytes())


def save(path, value):
    Path(path).write_bytes(canonical(value) + b"\n")


def environment(name):
    value = os.environ.get(name, "")
    require(value and not any(ord(c) < 32 or ord(c) == 127 for c in value), "set " + name)
    return value


def command(args, *, timeout=120):
    result = subprocess.run(args, check=True, capture_output=True, timeout=timeout)
    return result.stdout


def api(method, path, body=None, headers=None):
    # No redirects at all: Access credentials never leave the configured origin.
    url = urlsplit(environment("GAUNTLET_URL"))
    require(url.scheme == "https" and url.hostname and url.port in (None, 443)
            and not url.username and not url.password and not url.query and not url.fragment
            and url.path in ("", "/"), "GAUNTLET_URL must be an HTTPS origin")
    auth = {"CF-Access-Client-Id": environment("CF_ACCESS_CLIENT_ID"),
            "CF-Access-Client-Secret": environment("CF_ACCESS_CLIENT_SECRET"),
            "Accept": "application/json", "Content-Type": "application/json", **(headers or {})}
    conn = http.client.HTTPSConnection(url.hostname, timeout=300 if method == "POST" else 30)
    try:
        conn.request(method, path, body=canonical(body) if body is not None else None, headers=auth)
        response = conn.getresponse()
        if response.status in (502, 503, 504, 524):
            raise TransientAPIError(f"gauntlet HTTP {response.status}; service unavailable")
        require(response.status == 200, f"gauntlet HTTP {response.status}; no promotion")
        raw = response.read(MAX_BYTES + 1)
        return decode(raw)
    finally:
        conn.close()


def profile(candidate):
    require(candidate["profile"] == environment("GAUNTLET_PROFILE")
            and candidate["profile_revision"] == environment("GAUNTLET_PROFILE_REVISION")
            and candidate["bundle"]["config_bundle_hash"] == environment("GAUNTLET_CONFIG_BUNDLE_HASH"),
            "retained candidate differs from required profile/configuration")
    expected = (candidate["profile"], candidate["profile_revision"], candidate["kind"],
                candidate["bundle"]["config_bundle_hash"])
    matches = [p for p in api("GET", "/api/profiles")["profiles"]
               if (p["name"], p["revision"], p["kind"], p["config_bundle_hash"]) == expected]
    require(len(matches) == 1, "configured profile/revision/config is unavailable or obsolete")
    return matches[0]


def registry(repository, reference, *, config=False):
    require(REPOSITORY.fullmatch(repository) and ".." not in repository.split("/"), "invalid registry repository")
    require(DIGEST.fullmatch(reference) or re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}", reference),
            "invalid registry reference")
    separator = "@" if DIGEST.fullmatch(reference) else ":"
    args = ["skopeo", "inspect", "--tls-verify=true", "--raw"]
    if config:
        args.append("--config")
    authfile = os.environ.get("REGISTRY_AUTH_FILE")
    if authfile:
        args += ["--authfile", authfile]
    return command(args + ["docker://" + repository + separator + reference])


def resolve(repository, reference):
    raw = registry(repository, reference)
    index_digest = digest(raw)
    require(not DIGEST.fullmatch(reference) or reference == index_digest, "registry index digest differs")
    index = decode(raw)
    require(index.get("schemaVersion") == 2 and index.get("mediaType") in
            ("application/vnd.oci.image.index.v1+json", "application/vnd.docker.distribution.manifest.list.v2+json")
            and isinstance(index.get("manifests"), list), "multi-platform OCI index required")
    children = {}
    for child in index["manifests"]:
        platform = child.get("platform", {})
        name = platform.get("os", "") + "/" + platform.get("architecture", "")
        if name in PLATFORMS:
            require(name not in children and DIGEST.fullmatch(child.get("digest", "")),
                    "duplicate or invalid platform child")
            children[name] = child["digest"]
    require(set(children) == PLATFORMS, "both linux/amd64 and linux/arm64 children required")
    return {"repository": repository, "index_digest": index_digest, "children": children}


def image_configs(image):
    # Read the child bytes too, rather than trusting index descriptors alone.
    for platform, child in image["children"].items():
        raw = registry(image["repository"], child)
        require(digest(raw) == child, "registry child digest differs")
        manifest = decode(raw)
        config_raw = registry(image["repository"], child, config=True)
        require(digest(config_raw) == manifest.get("config", {}).get("digest"), "registry config digest differs")
        config = decode(config_raw)
        require(config.get("os", "") + "/" + config.get("architecture", "") == platform,
                "registry child platform differs")
        yield config.get("config", {})


def agent_pin(path):
    text = Path(path).read_text()
    pins = re.findall(r"^ARG EBPF_AGENT_IMAGE=(\S+)\s*$", text, re.MULTILINE)
    require(len(pins) == 1 and re.search(r"^FROM \$\{EBPF_AGENT_IMAGE\} AS ebpf-agent-source\s*$", text, re.MULTILINE),
            "Dockerfile must use exactly one default EBPF_AGENT_IMAGE pin")
    match = re.fullmatch(r"(.+):([0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?)@(sha256:[0-9a-f]{64})", pins[0])
    require(match is not None and REPOSITORY.fullmatch(match[1]), "agent default must be version@sha256 pinned")
    return match[1], match[2], match[3]


def make_bundle(args):
    require(SHA.fullmatch(args.source_sha), "full source SHA required")
    require(re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", args.repository), "invalid source repository")
    images = {}
    for item in args.image:
        role, separator, reference = item.partition("=")
        repository, at, index = reference.partition("@")
        require(separator and at and role not in images and DIGEST.fullmatch(index),
                "image must be unique ROLE=REPOSITORY@build-output-digest")
        images[role] = resolve(repository, index)
    require(set(images) == ({"agent"} if args.kind == "agent" else {"collector", "collector-ebpf"}),
            "candidate must contain exactly its owned image roles")
    components = {}
    if args.kind == "collector":
        require(args.dockerfile, "collector requires the actual eBPF Dockerfile")
        repository, _, index = agent_pin(args.dockerfile)
        components["agent"] = resolve(repository, index)
    candidate = {"kind": args.kind, "origin": "ci", "repository": args.repository, "source_sha": args.source_sha,
                 "profile": environment("GAUNTLET_PROFILE"), "profile_revision": environment("GAUNTLET_PROFILE_REVISION"),
                 "bundle": {"images": images, "components": components,
                            "config_bundle_hash": environment("GAUNTLET_CONFIG_BUNDLE_HASH")}}
    profile(candidate)
    save(args.output, candidate)


def prerequisite(args):
    candidate = load(args.candidate)
    require(candidate["kind"] == "collector", "collector prerequisite only")
    repository, version, index = agent_pin(args.dockerfile)
    included = resolve(repository, index)
    require(included == candidate["bundle"]["components"]["agent"], "agent Dockerfile pin differs from bundle")
    require(resolve(repository, version) == included, "agent version tag differs from pinned index")
    for config in image_configs(included):
        require(config.get("Labels", {}).get("org.opencontainers.image.version") == version,
                "agent platform version differs from Dockerfile")
    text = Path(args.collector_dockerfile).read_text()
    versions = re.findall(r"^ENV COLLECTOR_VERSION=(\S+)\s*$", text, re.MULTILINE)
    require(len(versions) == 1, "one collector build version required")
    expected_version = versions[0]
    if args.ref == "refs/heads/main":
        expected_version += "-canary-" + candidate["source_sha"][:7]
    else:
        require(args.ref == "refs/tags/v" + expected_version, "release tag differs from checked-in collector version")
    for role, image in candidate["bundle"]["images"].items():
        require(resolve(image["repository"], image["index_digest"]) == image, "build index identity changed")
        for config in image_configs(image):
            labels = config.get("Labels", {})
            require(labels.get("org.opencontainers.image.revision") == candidate["source_sha"],
                    "built platform source revision differs")
            require(labels.get("org.opencontainers.image.version") == expected_version, "built platform version differs")
            if role == "collector":
                require("COLLECTOR_VERSION=" + expected_version in config.get("Env", []), "collector runtime version differs")
    save(args.output, {"suite": "collector-image-prerequisites", "source_sha": candidate["source_sha"],
                       "required_check_ids": COLLECTOR_CHECKS, "executed_check_ids": COLLECTOR_CHECKS,
                       "executed": len(COLLECTOR_CHECKS), "skipped": 0, "failed": 0})


def identity(provider, value):
    if provider == "github":
        require(value.isdecimal() and int(value) > 0, "positive GitHub identifier required")
        return int(value)
    require(re.fullmatch(r"[A-Za-z0-9_-]{1,200}", value), "opaque Depot identifier required")
    return value


def checks_valid(checks, sha):
    require(checks and len({c["suite"] for c in checks}) == len(checks), "missing or duplicate prerequisite suites")
    for check in checks:
        require(set(check) == {"suite", "source_sha", "required_check_ids", "executed_check_ids", "executed", "skipped", "failed"},
                "unknown or missing prerequisite summary fields")
        required, executed = check["required_check_ids"], check["executed_check_ids"]
        require(isinstance(required, list) and required and isinstance(executed, list)
                and all(isinstance(x, str) and x for x in required + executed)
                and len(set(required)) == len(required) and len(set(executed)) == len(executed)
                and set(required) == set(executed), "required checks missing, duplicated or unknown")
        require(check["source_sha"] == sha and all(type(check[k]) is int for k in ("executed", "skipped", "failed"))
                and check["executed"] == len(required) and check["failed"] == check["skipped"] == 0,
                "prerequisite SHA/counts differ, failed or skipped")


def make_receipt(args):
    candidate = load(args.candidate)
    checks = []
    for path in args.summary:
        value = load(path)
        checks.extend(value if isinstance(value, list) else [value])
    checks_valid(checks, candidate["source_sha"])
    require(args.ref == "refs/heads/main" or
            (args.ref.startswith("refs/tags/v") and VERSION.fullmatch(args.ref.removeprefix("refs/tags/"))),
            "only main or version-tag receipts allowed")
    receipt = {"schema_version": 1, "provider": args.provider,
               "run_id": identity(args.provider, args.run_id), "run_attempt": identity(args.provider, args.run_attempt),
               "repository": candidate["repository"], "source_sha": candidate["source_sha"], "ref": args.ref,
               "bundle": candidate["bundle"], "checks": checks}
    if args.provider == "depot":
        require(args.prerequisite_attempts, "Depot requires actual upstream attempt IDs")
        attempts = load(args.prerequisite_attempts)
        require(isinstance(attempts, dict) and attempts and all(isinstance(k, str) and k for k in attempts),
                "Depot prerequisite attempt map required")
        for value in attempts.values():
            identity("depot", value)
        receipt["prerequisite_attempts"] = attempts
    else:
        require(not args.prerequisite_attempts, "GitHub must not claim Depot attempts")
    save(args.output, receipt)


def bound_run(submission, *, eligible=False, published_release=False):
    candidate = submission["candidate"]
    selected = profile(candidate)
    require(not published_release or eligible, "published release selection still requires eligibility")
    for variable, key in (("GITHUB_REPOSITORY", "repository"), ("GITHUB_SHA", "source_sha")):
        if os.environ.get(variable) and (variable != "GITHUB_SHA" or not published_release):
            require(candidate[key] == os.environ[variable], "retained submission differs from CI source identity")
    if not published_release and submission["ci"]["provider"] == "github" and os.environ.get("GITHUB_RUN_ID"):
        require(str(submission["ci"]["run_id"]) == os.environ["GITHUB_RUN_ID"],
                "retained submission belongs to another workflow run")
    run = api("GET", "/api/runs/" + quote(submission["run_id"], safe=""))
    require(run.get("run_id") == submission["run_id"] and run.get("origin") == "ci"
            and run.get("artifact_bundle_hash") == hashed(candidate["bundle"]), "run origin/bundle binding differs")
    actual = run["candidate"]
    for key in ("kind", "repository", "source_sha", "profile", "profile_revision"):
        require(actual.get(key) == candidate[key], "run candidate identity differs: " + key)
    require(actual["bundle"]["images"] == candidate["bundle"]["images"]
            and actual["bundle"]["config_bundle_hash"] == candidate["bundle"]["config_bundle_hash"],
            "run image/config identity differs")
    plan = run["plan"]
    for key, value in (("profile", candidate["profile"]), ("revision", candidate["profile_revision"]),
                       ("config_bundle_hash", candidate["bundle"]["config_bundle_hash"]),
                       ("contract_revision", selected["contract_revision"]), ("workload_revision", selected["workload_revision"])):
        require(plan.get(key) == value, "run frozen profile differs: " + key)
    if eligible:
        require(run.get("verdict") == "eligible" and run.get("provenance_verified") is True
                and run.get("evidence_archived") is True, "exact candidate is not archived and eligible")
    return run


def submit(args):
    candidate = load(args.candidate)
    profile(candidate)
    ci = {"provider": args.provider, **{k: identity(args.provider, getattr(args, k))
                                     for k in ("run_id", "run_attempt", "artifact_id")}}
    key = hashed({"repository": candidate["repository"], "source_sha": candidate["source_sha"],
                  "artifact_bundle_hash": hashed(candidate["bundle"]), "profile_revision": candidate["profile_revision"]})
    body, headers = {"candidate": candidate, "ci": ci}, {"Idempotency-Key": key}
    for attempt in range(3):
        try:
            run = api("POST", "/api/runs", body, headers)
            break
        except (TimeoutError, ConnectionError, http.client.HTTPException):
            if attempt == 2:
                raise
            time.sleep(5 * (attempt + 1))
    require(re.fullmatch(r"[A-Za-z0-9_-]{1,200}", run.get("run_id", "")), "invalid submitted run ID")
    submission = {"candidate": candidate, "ci": ci, "run_id": run["run_id"]}
    bound_run(submission)
    save(args.output, submission)
    print(environment("GAUNTLET_URL").rstrip("/") + "/runs/" + run["run_id"])


def wait(args):
    require(0 < args.timeout_seconds <= 19800, "wait must be bounded at 330 minutes")
    submission = load(args.submission)
    deadline = time.monotonic() + args.timeout_seconds
    while True:
        require(time.monotonic() < deadline, "gauntlet wait timed out; durable run continues, publication blocked")
        try:
            run = bound_run(submission)
            if run["verdict"] == "eligible":
                bound_run(submission, eligible=True)
                require(time.monotonic() < deadline, "gauntlet wait timed out; durable run continues, publication blocked")
                return
        except (TimeoutError, ConnectionError, socket.gaierror, http.client.HTTPException):
            # Only transport failures retry; the absolute deadline never moves.
            run = None
        if run is not None:
            lifecycle, progress = run.get("lifecycle"), run.get("progress", {})
            require(run["verdict"] != "failed" and not run.get("assertion_failure_sticky")
                    and lifecycle in ("queued", "running", "completed")
                    and not progress.get("failed") and not progress.get("errors")
                    and not any(cell.get("status") in ("fail", "error", "interrupted", "cancelled")
                                for cell in run.get("cells", [])), "gauntlet terminated without eligibility")
            if lifecycle == "completed":
                expected = progress.get("expected", 0)
                require(run["verdict"] == "incomplete" and run.get("evidence_archived") is False
                        and run.get("provenance_verified") is True and expected > 0
                        and progress.get("passed") == progress.get("completed") == expected
                        and progress.get("queued") == progress.get("running") == 0,
                        "completed gauntlet is not awaiting archival of all-passed evidence")
        remaining = deadline - time.monotonic()
        require(remaining > 0, "gauntlet wait timed out; durable run continues, publication blocked")
        time.sleep(min(30, remaining))


def git(*args):
    return command(["git", *args]).decode().strip()


def ancestor(older, newer):
    result = subprocess.run(["git", "merge-base", "--is-ancestor", older, newer], capture_output=True, timeout=30)
    require(result.returncode in (0, 1), "cannot determine source ancestry")
    return result.returncode == 0


def remote_main():
    rows = git("ls-remote", "--exit-code", "origin", "refs/heads/main").splitlines()
    require(len(rows) == 1 and SHA.fullmatch(rows[0].split()[0]), "cannot resolve main tip")
    return rows[0].split()[0]


def registry_tags(repository):
    args = ["skopeo", "list-tags", "--tls-verify=true"]
    if os.environ.get("REGISTRY_AUTH_FILE"):
        args += ["--authfile", os.environ["REGISTRY_AUTH_FILE"]]
    tags = decode(command(args + ["docker://" + repository]))["Tags"]
    require(isinstance(tags, list), "cannot observe registry tags")
    return set(tags)


def retag(image, tag):
    args = ["skopeo", "copy", "--all", "--preserve-digests", "--src-tls-verify=true", "--dest-tls-verify=true"]
    if os.environ.get("REGISTRY_AUTH_FILE"):
        args += ["--authfile", os.environ["REGISTRY_AUTH_FILE"]]
    command(args + ["docker://" + image["repository"] + "@" + image["index_digest"],
                    "docker://" + image["repository"] + ":" + tag], timeout=300)
    require(resolve(image["repository"], tag) == image, "retagged index/children do not match tested bytes")


def latest_allowed(image, version, sha):
    if "latest" not in registry_tags(image["repository"]):
        return True
    latest = resolve(image["repository"], "latest")
    identities = set()
    for config in image_configs(latest):
        labels = config.get("Labels", {})
        identities.add((labels.get("org.opencontainers.image.version"), labels.get("org.opencontainers.image.revision")))
    require(len(identities) == 1, "existing latest platform identities disagree")
    old_version, old_sha = identities.pop()
    old = VERSION.fullmatch(old_version or "")
    require(old and not old[4] and SHA.fullmatch(old_sha or ""), "existing latest lacks stable version/source identity")
    current = tuple(int(version[i]) for i in (1, 2, 3))
    previous = tuple(int(old[i]) for i in (1, 2, 3))
    if current < previous:
        return False
    if old_sha != sha and ancestor(sha, old_sha):
        return False
    require(ancestor(old_sha, sha), "latest and candidate source histories diverge")
    require(current != previous or latest == image, "same release version has different bytes")
    return True


def promote(args):
    submission = load(args.submission)
    candidate = submission["candidate"]
    sha = candidate["source_sha"]
    require(git("rev-parse", "HEAD") == sha, "promotion checkout differs from candidate source")
    git("fetch", "--no-tags", "origin", "+refs/heads/main:refs/remotes/origin/main")
    canary = args.tag == "canary"
    version = VERSION.fullmatch(args.tag)
    require(canary or (args.tag.startswith("v") and version), "promotion tag must be canary or vSEMVER")
    skip_latest, latest_only = getattr(args, "skip_latest", False), getattr(args, "latest_only", False)
    require(not (skip_latest and latest_only) and not (canary and (skip_latest or latest_only)),
            "promotion phase flags are mutually exclusive and require a release tag")
    published_release = getattr(args, "published_release", False)
    require(not published_release or latest_only, "published release selection requires latest-only")
    if canary:
        bound_run(submission)
    else:
        bound_run(submission, eligible=True, published_release=published_release)
        require(git("rev-parse", args.tag + "^{commit}") == sha, "release Git tag differs from tested source")
        tag_rows = git("ls-remote", "--exit-code", "origin", "refs/tags/" + args.tag, "refs/tags/" + args.tag + "^{}").splitlines()
        remote_tags = dict(row.split()[::-1] for row in tag_rows)
        require(remote_tags.get("refs/tags/" + args.tag + "^{}", remote_tags.get("refs/tags/" + args.tag)) == sha,
                "remote release tag no longer identifies tested source")
        require(ancestor(sha, "refs/remotes/origin/main"), "release source is not on main")
    images = candidate["bundle"]["images"]
    # Preflight the entire pair before any write. Partial network failures still fail CI.
    for image in images.values():
        require(resolve(image["repository"], image["index_digest"]) == image, "candidate registry identity changed")
        if not canary:
            tags = registry_tags(image["repository"])
            require(not latest_only or args.tag[1:] in tags, "publish exact version aliases before latest-only")
            if args.tag[1:] in tags:
                require(resolve(image["repository"], args.tag[1:]) == image, "immutable version tag already names other bytes")
    update_latest = (not canary and not skip_latest and not version[4]
                     and all(latest_allowed(image, version, sha) for image in images.values()))
    if canary and remote_main() != sha:
        print("Main advanced; skipping canary aliases only")
        return
    # Publication-start linearization under the CI alias lock: finish the pair
    # even if main advances now; never deliberately split it between source SHAs.
    for image in images.values():
        if canary:
            # The pair has one tip check, not one check per image write.
            retag(image, "canary")
        elif not latest_only:
            bound_run(submission, eligible=True, published_release=published_release)
            retag(image, args.tag[1:])
    if update_latest:
        for image in images.values():
            bound_run(submission, eligible=True, published_release=published_release)
            retag(image, "latest")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    bundle = commands.add_parser("bundle")
    bundle.add_argument("--kind", choices=("agent", "collector"), required=True)
    bundle.add_argument("--repository", required=True)
    bundle.add_argument("--source-sha", required=True)
    bundle.add_argument("--image", action="append", required=True)
    bundle.add_argument("--dockerfile")
    bundle.add_argument("--output", required=True)
    bundle.set_defaults(run=make_bundle)
    check = commands.add_parser("prerequisite")
    check.add_argument("--candidate", required=True)
    check.add_argument("--dockerfile", default="ebpf/Dockerfile")
    check.add_argument("--collector-dockerfile", default="collector/Dockerfile")
    check.add_argument("--ref", required=True)
    check.add_argument("--output", required=True)
    check.set_defaults(run=prerequisite)
    receipt = commands.add_parser("receipt")
    submitter = commands.add_parser("submit")
    for item in (receipt, submitter):
        item.add_argument("--candidate", required=True)
        item.add_argument("--provider", choices=("github", "depot"), required=True)
        item.add_argument("--run-id", required=True)
        item.add_argument("--run-attempt", required=True)
        item.add_argument("--output", required=True)
    receipt.add_argument("--ref", required=True)
    receipt.add_argument("--summary", action="append", required=True)
    receipt.add_argument("--prerequisite-attempts")
    receipt.set_defaults(run=make_receipt)
    submitter.add_argument("--artifact-id", required=True)
    submitter.set_defaults(run=submit)
    waiter = commands.add_parser("wait")
    waiter.add_argument("--submission", required=True)
    waiter.add_argument("--timeout-seconds", type=int, default=19800)
    waiter.set_defaults(run=wait)
    publisher = commands.add_parser("promote")
    publisher.add_argument("--submission", required=True)
    publisher.add_argument("--tag", required=True)
    phase = publisher.add_mutually_exclusive_group()
    phase.add_argument("--skip-latest", action="store_true")
    phase.add_argument("--latest-only", action="store_true")
    publisher.add_argument("--published-release", action="store_true")
    publisher.set_defaults(run=promote)
    args = parser.parse_args()
    try:
        args.run(args)
    except (ValueError, KeyError, TypeError, OSError, http.client.HTTPException, subprocess.SubprocessError) as error:
        # Do not print provider payloads, command stderr, URLs or credentials in public CI.
        detail = str(error) if isinstance(error, ValueError) else type(error).__name__
        parser.exit(1, "gauntlet failed: " + detail + "\n")


if __name__ == "__main__":
    main()
