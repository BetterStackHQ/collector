"""Submit exact-digest advisory CI candidates. Python stdlib + skopeo only."""

import argparse
import hashlib
import http.client
import json
import os
from pathlib import Path
import re
import subprocess
import time
from urllib.parse import urlsplit


SHA = re.compile(r"[0-9a-f]{40}")
DIGEST = re.compile(r"sha256:[0-9a-f]{64}")
REPOSITORY = re.compile(r"[a-z0-9.-]+(?::[0-9]+)?/[a-z0-9._/-]+")
PLATFORMS = {"linux/amd64", "linux/arm64"}
MAX_BYTES = 16 * 1024 * 1024


class TransientAPIError(ConnectionError):
    """An idempotent submission may retry this transport failure."""


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
        require(response.status == 200, f"gauntlet HTTP {response.status}")
        raw = response.read(MAX_BYTES + 1)
        return decode(raw)
    finally:
        conn.close()


def profile(candidate):
    # Resolve the deployed profile by name; a retained candidate may only repeat the server's identity.
    require(candidate["profile"] == environment("GAUNTLET_PROFILE"), "retained candidate differs from required profile")
    matches = [p for p in api("GET", "/api/profiles")["profiles"]
               if p["name"] == candidate["profile"] and p["kind"] == candidate["kind"]]
    require(len(matches) == 1, "named profile is unavailable or ambiguous for this kind")
    found, bundle = matches[0], candidate["bundle"]
    require(found["revision"] and found["config_bundle_hash"]
            and candidate["profile_revision"] in (None, found["revision"])
            and bundle["config_bundle_hash"] in (None, found["config_bundle_hash"]),
            "retained candidate differs from current profile/configuration")
    candidate["profile_revision"], bundle["config_bundle_hash"] = found["revision"], found["config_bundle_hash"]
    return found


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
                 "profile": environment("GAUNTLET_PROFILE"), "profile_revision": None,
                 "bundle": {"images": images, "components": components, "config_bundle_hash": None}}
    save(args.output, candidate)


def prerequisite(args):
    candidate = load(args.candidate)
    require(candidate["kind"] == "collector", "collector prerequisite only")
    profile(candidate)
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


def submit(args):
    candidate = load(args.candidate)
    profile(candidate)
    key = hashed({"repository": candidate["repository"], "source_sha": candidate["source_sha"],
                  "artifact_bundle_hash": hashed(candidate["bundle"]), "profile_revision": candidate["profile_revision"]})
    body, headers = {"candidate": candidate}, {"Idempotency-Key": key}
    for attempt in range(3):
        try:
            run = api("POST", "/api/runs", body, headers)
            break
        except (TimeoutError, ConnectionError, http.client.HTTPException):
            if attempt == 2:
                raise
            time.sleep(5 * (attempt + 1))
    require(re.fullmatch(r"[A-Za-z0-9_-]{1,200}", run.get("run_id", "")), "invalid submitted run ID")
    submission = {"candidate": candidate, "run_id": run["run_id"]}
    save(args.output, submission)
    print(environment("GAUNTLET_URL").rstrip("/") + "/runs/" + run["run_id"])


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
    check.set_defaults(run=prerequisite)
    submitter = commands.add_parser("submit")
    submitter.add_argument("--candidate", required=True)
    submitter.add_argument("--output", required=True)
    submitter.set_defaults(run=submit)
    args = parser.parse_args()
    try:
        args.run(args)
    except (ValueError, KeyError, TypeError, OSError, http.client.HTTPException, subprocess.SubprocessError) as error:
        # Do not print service payloads, command stderr, URLs or credentials in public CI.
        detail = str(error) if isinstance(error, ValueError) else type(error).__name__
        parser.exit(1, "gauntlet failed: " + detail + "\n")


if __name__ == "__main__":
    main()
