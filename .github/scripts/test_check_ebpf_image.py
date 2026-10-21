import subprocess
import unittest
from unittest.mock import patch

from check_ebpf_image import REPOSITORY, image_reference, verify


DIGEST = "sha256:" + "a" * 64
IMAGE = f"{REPOSITORY}:0.1.10@{DIGEST}"
DOCKERFILE = f"ARG EBPF_AGENT_IMAGE={IMAGE}\nFROM ${{EBPF_AGENT_IMAGE}} AS ebpf-agent-source\n"
MANIFEST = {
    "digest": DIGEST,
    "manifests": [
        {"platform": {"os": "linux", "architecture": arch}}
        for arch in ("amd64", "arm64")
    ],
}


def configs(version):
    return {
        platform: {"config": {"Labels": {"org.opencontainers.image.version": version}}}
        for platform in ("linux/amd64", "linux/arm64")
    }


class ImageReferenceTest(unittest.TestCase):
    def test_canonical_docker_input(self):
        self.assertEqual(image_reference(DOCKERFILE), (IMAGE, "0.1.10", DIGEST))
        for invalid in (
            DOCKERFILE.replace("@" + DIGEST, ""),
            DOCKERFILE.replace(REPOSITORY, "example.com/agent"),
            DOCKERFILE.replace("sha256:" + "a" * 64, "sha256:abc"),
            DOCKERFILE + f"ARG EBPF_AGENT_IMAGE={IMAGE}\n",
            DOCKERFILE + "ARG EBPF_AGENT_VERSION=0.1.10\n",
            DOCKERFILE.replace("${EBPF_AGENT_IMAGE}", REPOSITORY + ":0.1.10"),
            DOCKERFILE + "ARG EBPF_AGENT_IMAGE\n",
        ):
            with self.subTest(dockerfile=invalid), self.assertRaises(ValueError):
                image_reference(invalid)

    @patch("check_ebpf_image.inspect")
    def test_real_metadata_is_required(self, inspect):
        inspect.side_effect = [MANIFEST, configs("0.1.10")]
        verify(IMAGE, "0.1.10", DIGEST)
        self.assertEqual(inspect.call_args_list[0].args, (REPOSITORY + ":0.1.10", "Manifest"))
        self.assertEqual(inspect.call_args_list[1].args, (IMAGE, "Image"))
        for manifest, images in (
            ({**MANIFEST, "digest": "sha256:" + "b" * 64}, configs("0.1.10")),
            (MANIFEST, configs("0.1.9")),
            (MANIFEST, {**configs("0.1.10"), "linux/arm64": {}}),
            (MANIFEST, {"linux/amd64": configs("0.1.10")["linux/amd64"]}),
            ({**MANIFEST, "manifests": []}, configs("0.1.10")),
        ):
            with self.subTest(manifest=manifest, images=images), self.assertRaises(ValueError):
                inspect.side_effect = [manifest, images]
                verify(IMAGE, "0.1.10", DIGEST)
        inspect.side_effect = subprocess.CalledProcessError(1, ["docker"])
        with self.assertRaises(subprocess.CalledProcessError):
            verify(IMAGE, "0.1.10", DIGEST)


if __name__ == "__main__":
    unittest.main()
