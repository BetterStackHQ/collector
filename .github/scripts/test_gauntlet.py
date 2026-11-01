"""Offline only: no network, git, container commands or registry writes."""

import argparse
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch


spec = importlib.util.spec_from_file_location("gauntlet", Path(__file__).with_name("gauntlet.py"))
g = importlib.util.module_from_spec(spec)
spec.loader.exec_module(g)
SHA = "a" * 40
OTHER = "b" * 40
PIN = "ARG EBPF_AGENT_IMAGE=registry.example/agent:1.2.3@sha256:" + "4" * 64 + "\nFROM ${EBPF_AGENT_IMAGE} AS ebpf-agent-source\n"
BUILDERS = PIN + "FROM debian:13.5 AS node-agent-builder\nRUN go build -o /usr/local/bin/node-agent .\n" \
    "FROM obi-generator:0.2.16 AS obi-builder\nFROM debian:13.5-slim\n# COPY --from=node-agent-builder /n /usr/local/bin/node-agent\n"
AGENT = "COPY --from=ebpf-agent-source --chmod=755 /ebpf-agent /usr/local/bin/ebpf-agent\n"
OBI = "COPY --from=obi-builder --chmod=755 /tmp/obi/bin/obi /usr/local/bin/ebpf-instrument\n"


def candidate():
    image = {"repository": "registry.example/collector", "index_digest": "sha256:" + "1" * 64,
             "children": {"linux/amd64": "sha256:" + "2" * 64, "linux/arm64": "sha256:" + "3" * 64}}
    return {"kind": "collector", "origin": "ci", "repository": "example/collector", "source_sha": SHA,
            "profile": "collector", "profile_revision": "profile-1",
            "bundle": {"images": {"collector": image, "collector-ebpf": {**image, "repository": "registry.example/collector-ebpf"}},
                       "components": {"agent": {**image, "repository": "registry.example/agent"}},
                       "shipped_components": ["ebpf-agent", "obi"], "config_bundle_hash": "config-1"}}


class ClientChecks(unittest.TestCase):
    def setUp(self):
        environment = patch.dict(os.environ, {}, clear=True)
        environment.start()
        self.addCleanup(environment.stop)

    def test_canonical_identity_and_duplicate_json(self):
        self.assertEqual(g.hashed({"b": 2, "a": 1}), g.hashed({"a": 1, "b": 2}))
        with self.assertRaises(ValueError):
            g.decode(b'{"a":1,"a":2}')
        with self.assertRaises(ValueError):
            g.canonical({"bad": float("nan")})

    def test_redirects_never_forward_access_credentials(self):
        connection = Mock()
        connection.getresponse.return_value.status = 302
        with patch.dict(os.environ, {"GAUNTLET_URL": "https://service.example", "CF_ACCESS_CLIENT_ID": "id",
                                    "CF_ACCESS_CLIENT_SECRET": "secret"}), \
                patch.object(g.http.client, "HTTPSConnection", return_value=connection) as connect:
            with self.assertRaisesRegex(ValueError, "HTTP 302"):
                g.api("GET", "/api/profiles")
            connect.assert_called_once_with("service.example", timeout=30)
            connection.request.assert_called_once()
            connection.close.assert_called_once()

    def test_resolve_records_real_index_and_both_children(self):
        raw = g.canonical({"schemaVersion": 2, "mediaType": "application/vnd.oci.image.index.v1+json", "manifests": [
            {"platform": {"os": "linux", "architecture": arch}, "digest": "sha256:" + digit * 64}
            for arch, digit in (("amd64", "2"), ("arm64", "3"))]})
        with patch.object(g, "registry", return_value=raw):
            actual = g.resolve("registry.example/collector", g.digest(raw))
            self.assertEqual(actual["index_digest"], g.digest(raw))
            self.assertEqual(set(actual["children"]), g.PLATFORMS)
            with self.assertRaisesRegex(ValueError, "index digest differs"):
                g.resolve("registry.example/collector", "sha256:" + "f" * 64)
        missing = g.decode(raw)
        missing["manifests"].pop()
        with patch.object(g, "registry", return_value=g.canonical(missing)):
            with self.assertRaisesRegex(ValueError, "both linux"):
                g.resolve("registry.example/collector", "canary")

    def test_child_config_bytes_must_match_manifest(self):
        image = candidate()["bundle"]["images"]["collector"]
        with patch.object(g, "registry", return_value=b'{}'):
            with self.assertRaisesRegex(ValueError, "child digest differs"):
                list(g.image_configs(image))

    def test_bundle_uses_dockerfile_pin_not_environment_override(self):
        image = candidate()["bundle"]["images"]["collector"]
        with tempfile.TemporaryDirectory() as folder:
            dockerfile = Path(folder, "Dockerfile")
            pin = "sha256:" + "4" * 64
            dockerfile.write_text("ARG EBPF_AGENT_IMAGE=registry.example/agent:1.2.3@" + pin +
                                  "\nFROM ${EBPF_AGENT_IMAGE} AS ebpf-agent-source\nFROM debian:13.5-slim\n" + AGENT)
            output = Path(folder, "candidate.json")
            args = argparse.Namespace(kind="collector", repository="example/collector", source_sha=SHA,
                                      image=[role + "=" + value["repository"] + "@" + value["index_digest"]
                                             for role, value in candidate()["bundle"]["images"].items()],
                                      dockerfile=str(dockerfile), output=output)
            with patch.dict(os.environ, {"GAUNTLET_PROFILE": "collector", "EBPF_AGENT_IMAGE": "wrong"}), \
                    patch.object(g, "api") as api, \
                    patch.object(g, "resolve", side_effect=lambda repo, ref: {**image, "repository": repo, "index_digest": ref}):
                g.make_bundle(args)
            api.assert_not_called()
            bundled = g.load(output)
            self.assertEqual(bundled["bundle"]["components"]["agent"]["index_digest"], pin)
            self.assertEqual(bundled["bundle"]["shipped_components"], ["ebpf-agent"])
            self.assertEqual((bundled["profile"], bundled["profile_revision"], bundled["bundle"]["config_bundle_hash"]),
                             ("collector", None, None))

    def test_shipped_components_are_what_the_final_stage_copies_in(self):
        coroot = ["ebpf-agent", "coroot", "obi"]
        cases = {
            "leftover builder stages copy nothing": (BUILDERS + AGENT + OBI, ["ebpf-agent", "obi"]),
            "file destination": (BUILDERS + AGENT + "COPY --from=node-agent-builder /usr/bin/coroot-node-agent "
                                 "/usr/local/bin/node-agent\n" + OBI, coroot),
            "renamed stage": (BUILDERS + AGENT + "COPY --from=coroot /node-agent /usr/local/bin/node-agent\n" + OBI, coroot),
            "indented": (BUILDERS + "  " + AGENT + "\tCOPY --from=x /node-agent /usr/local/bin/node-agent\n" + OBI, coroot),
            "continued": (BUILDERS + AGENT + "COPY --from=node-agent-builder \\\n    --chmod=755 \\\n"
                          "    # node-agent\n    /usr/bin/node-agent /usr/local/bin/node-agent\n" + OBI, coroot),
            "into the directory": (BUILDERS + "COPY --from=ebpf-agent-source /ebpf-agent /usr/local/bin/\n"
                                   "COPY --from=x /build/node-agent /tmp/obi/bin/ebpf-instrument /usr/local/bin/\n", coroot),
            "json form": (BUILDERS + 'COPY --from=ebpf-agent-source ["/ebpf-agent", "/usr/local/bin/ebpf-agent"]\n', ["ebpf-agent"]),
            "only from build stages": (BUILDERS + AGENT + "COPY ebpf/node-agent /usr/local/bin/node-agent\n", ["ebpf-agent"]),
            "only the final stage": (PIN + "FROM debian:13.5 AS early\n" + OBI + "FROM debian:13.5-slim\n" + AGENT,
                                     ["ebpf-agent"]),
        }
        with tempfile.TemporaryDirectory() as folder:
            dockerfile = Path(folder, "Dockerfile")
            for name, (text, expected) in cases.items():
                dockerfile.write_text(text)
                with self.subTest(name):
                    self.assertEqual(g.shipped_components(dockerfile), expected)
            for text, message in ((BUILDERS.replace(PIN, "FROM agent:1 AS ebpf-agent-source\n") + AGENT, "ebpf-agent-source"),
                                  (BUILDERS, "no known agent")):
                dockerfile.write_text(text)
                with self.subTest(message), self.assertRaisesRegex(ValueError, message):
                    g.shipped_components(dockerfile)
        actual = Path(__file__).resolve().parents[2] / "ebpf" / "Dockerfile"
        self.assertEqual(g.shipped_components(actual), ["ebpf-agent", "obi"])

    def test_post_has_longer_bounded_timeout_and_http_auth_is_not_transient(self):
        connection = Mock()
        with patch.dict(os.environ, {"GAUNTLET_URL": "https://service.example", "CF_ACCESS_CLIENT_ID": "id",
                                    "CF_ACCESS_CLIENT_SECRET": "secret"}), \
                patch.object(g.http.client, "HTTPSConnection", return_value=connection) as connect:
            for status in (503, 524):
                connection.getresponse.return_value.status = status
                with self.assertRaises(g.TransientAPIError):
                    g.api("POST", "/api/runs", {})
                connect.assert_called_with("service.example", timeout=300)
            connection.getresponse.return_value.status = 401
            with self.assertRaises(ValueError):
                g.api("POST", "/api/runs", {})

    def test_submit_recovers_transport_only_with_identical_idempotency(self):
        args = argparse.Namespace(candidate="candidate.json", output="submission.json")
        with patch.object(g, "load", return_value=candidate()), patch.object(g, "profile"), \
                patch.object(g, "api", side_effect=[TimeoutError(), g.TransientAPIError(), {"run_id": "run-1"}]) as api, \
                patch.object(g, "save") as save, patch.object(g.time, "sleep") as sleep, \
                patch.object(g, "environment", return_value="https://service.example"):
            g.submit(args)
            self.assertEqual(api.call_count, 3)
            self.assertEqual(api.call_args_list[0], api.call_args_list[1])
            self.assertEqual(api.call_args_list[1], api.call_args_list[2])
            self.assertEqual([call.args[0] for call in sleep.call_args_list], [5, 10])
            body = {"candidate": candidate()}
            key = g.hashed({"repository": candidate()["repository"], "source_sha": SHA,
                            "artifact_bundle_hash": g.hashed(candidate()["bundle"]), "profile_revision": "profile-1"})
            api.assert_called_with("POST", "/api/runs", body, {"Idempotency-Key": key})
            save.assert_called_once_with(args.output, {"candidate": candidate(), "run_id": "run-1"})
        for error, attempts in ((ValueError("HTTP 400"), 1), (ValueError("HTTP 401"), 1),
                                (TimeoutError(), 3)):
            with patch.object(g, "load", return_value=candidate()), patch.object(g, "profile"), \
                    patch.object(g, "api", side_effect=error) as api, patch.object(g.time, "sleep"):
                with self.assertRaises(type(error)):
                    g.submit(args)
                self.assertEqual(api.call_count, attempts)

    def test_profile_resolves_by_name_and_kind_and_fails_closed(self):
        server = {"name": "collector", "kind": "collector", "revision": "profile-1", "config_bundle_hash": "config-1"}
        resolved = candidate()
        resolved["profile_revision"] = resolved["bundle"]["config_bundle_hash"] = None
        others = [{**server, "name": "other"}, {**server, "kind": "agent", "revision": "agent-1"}]
        with patch.dict(os.environ, {"GAUNTLET_PROFILE": "collector"}):
            with patch.object(g, "api", return_value={"profiles": [server, *others]}):
                self.assertEqual(g.profile(resolved), server)
                self.assertEqual(resolved, candidate())
                g.profile(resolved)  # retained values equal to the server's are accepted
            for profiles in ([], [{**server, "kind": "agent"}], [server, {**server, "revision": "profile-2"}]):
                with self.subTest(profiles=profiles), patch.object(g, "api", return_value={"profiles": profiles}), \
                        self.assertRaisesRegex(ValueError, "unavailable or ambiguous"):
                    g.profile(candidate())
            for retained in ({"profile_revision": "profile-0"},
                             {"bundle": {**candidate()["bundle"], "config_bundle_hash": "other-config"}}):
                with self.subTest(retained=retained), patch.object(g, "api", return_value={"profiles": [server]}), \
                        self.assertRaisesRegex(ValueError, "current profile/configuration"):
                    g.profile(candidate() | retained)
            with patch.object(g, "api") as api, self.assertRaisesRegex(ValueError, "required profile"):
                g.profile(candidate() | {"profile": "other"})
            api.assert_not_called()

    def test_registry_rejects_untrusted_identity_before_running_commands(self):
        with patch.object(g, "command") as command:
            for repository, reference in (("--insecure", "latest"), ("registry.example/../agent", "latest"),
                                          ("registry.example/agent", "latest; echo bad"),
                                          ("registry.example/agent", "sha256:bad")):
                with self.subTest(repository=repository, reference=reference), self.assertRaises(ValueError):
                    g.registry(repository, reference)
            command.assert_not_called()

    def test_submission_requires_a_valid_run_id(self):
        args = argparse.Namespace(candidate="candidate.json", output="submission.json")
        for run_id in ("", "../other", "a" * 201):
            with self.subTest(run_id=run_id), patch.object(g, "load", return_value=candidate()), \
                    patch.object(g, "profile"), patch.object(g, "api", return_value={"run_id": run_id}), \
                    patch.object(g, "save") as save:
                with self.assertRaisesRegex(ValueError, "run ID"):
                    g.submit(args)
                save.assert_not_called()

    def test_built_image_verification_rejects_wrong_source_version_and_runtime(self):
        c = candidate()
        image = c["bundle"]["components"]["agent"]
        agent_config = {"Labels": {"org.opencontainers.image.version": "1.2.3"}}
        good = {"Labels": {"org.opencontainers.image.revision": SHA,
                           "org.opencontainers.image.version": "2.0.0-canary-" + SHA[:7]},
                "Env": ["COLLECTOR_VERSION=2.0.0-canary-" + SHA[:7]]}
        with tempfile.TemporaryDirectory() as folder:
            dockerfile = Path(folder, "Dockerfile")
            dockerfile.write_text("ENV COLLECTOR_VERSION=2.0.0\n")
            args = argparse.Namespace(candidate="candidate.json", dockerfile="ebpf/Dockerfile",
                                      collector_dockerfile=dockerfile, ref="refs/heads/main")
            for config in (good, {**good, "Labels": {**good["Labels"], "org.opencontainers.image.revision": OTHER}},
                           {**good, "Labels": {**good["Labels"], "org.opencontainers.image.version": "wrong"}},
                           {**good, "Env": []}):
                with self.subTest(config=config), patch.object(g, "load", return_value=c), patch.object(g, "profile") as profile, \
                        patch.object(g, "agent_pin", return_value=(image["repository"], "1.2.3", image["index_digest"])), \
                        patch.object(g, "resolve", side_effect=lambda repo, ref: next(
                            item for item in [image, *c["bundle"]["images"].values()] if item["repository"] == repo)), \
                        patch.object(g, "image_configs", side_effect=lambda value: iter(
                            [agent_config if value["repository"] == image["repository"] else config])):
                    if config == good:
                        g.prerequisite(args)
                        profile.assert_called_once_with(c)
                    else:
                        with self.assertRaises(ValueError):
                            g.prerequisite(args)



if __name__ == "__main__":
    unittest.main()
