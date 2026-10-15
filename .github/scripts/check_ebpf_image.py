"""Verify the eBPF agent's declared version and immutable registry identity."""

import argparse
import json
from pathlib import Path
import re
import subprocess


REPOSITORY = "ghcr.io/betterstackhq/ebpf-agent"
REFERENCE = re.compile(
    re.escape(REPOSITORY)
    + r":(?P<version>[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?)"
    + r"@(?P<digest>sha256:[0-9a-f]{64})"
)


def image_reference(dockerfile):
    if re.search(r"^ARG\s+EBPF_AGENT_VERSION\b", dockerfile, re.MULTILINE):
        raise ValueError("Use only EBPF_AGENT_IMAGE, not the old version argument")
    pins = re.findall(r"^ARG EBPF_AGENT_IMAGE(?:=(\S+))?\s*$", dockerfile, re.MULTILINE)
    if len(pins) != 1:
        raise ValueError("Expected exactly one ARG EBPF_AGENT_IMAGE with a default")
    image = pins[0]
    match = REFERENCE.fullmatch(image)
    if match is None:
        raise ValueError("EBPF_AGENT_IMAGE must be a version-tagged sha256 reference to " + REPOSITORY)
    if not re.search(r"^FROM \$\{EBPF_AGENT_IMAGE\} AS ebpf-agent-source\s*$", dockerfile, re.MULTILINE):
        raise ValueError("The eBPF agent source stage must use EBPF_AGENT_IMAGE directly")
    return image, match["version"], match["digest"]


def inspect(image, field):
    result = subprocess.run(
        ["docker", "buildx", "imagetools", "inspect", image, "--format", "{{json ." + field + "}}"],
        check=True, capture_output=True, text=True, timeout=120,
    )
    return json.loads(result.stdout)


def verify(image, version, digest):
    # Resolve the tag separately: tag@digest alone selects the digest, even for a wrong tag.
    manifest = inspect(image.split("@", 1)[0], "Manifest")
    if manifest.get("digest") != digest:
        raise ValueError("The version tag does not resolve to the pinned digest")
    platforms = {
        item.get("platform", {}).get("os", "") + "/" + item.get("platform", {}).get("architecture", "")
        for item in manifest.get("manifests", [])
    }
    required = {"linux/amd64", "linux/arm64"}
    if not required.issubset(platforms):
        raise ValueError("The eBPF agent index must include linux/amd64 and linux/arm64")
    images = inspect(image, "Image")
    if not isinstance(images, dict) or not required.issubset(images):
        raise ValueError("Missing eBPF agent platform configuration metadata")
    for platform, config in images.items():
        actual = config.get("config", {}).get("Labels", {}).get("org.opencontainers.image.version")
        if actual != version:
            raise ValueError(f"{platform} artifact version {actual!r} does not match declared version {version!r}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dockerfile", type=Path, default=Path("ebpf/Dockerfile"))
    parser.add_argument("--github-output", type=Path)
    args = parser.parse_args()
    try:
        image, version, digest = image_reference(args.dockerfile.read_text())
        verify(image, version, digest)
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        detail = error.stderr if isinstance(error, subprocess.CalledProcessError) else ""
        parser.exit(1, f"eBPF agent image verification failed: {error}\n{detail or ''}")
    print(f"Verified eBPF Agent {version}: {image}")
    if args.github_output:
        with args.github_output.open("a") as output:
            output.write(f"version={version}\nimage={image}\ndigest={digest}\n")


if __name__ == "__main__":
    main()
