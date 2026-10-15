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


def candidate():
    image = {"repository": "registry.example/collector", "index_digest": "sha256:" + "1" * 64,
             "children": {"linux/amd64": "sha256:" + "2" * 64, "linux/arm64": "sha256:" + "3" * 64}}
    return {"kind": "collector", "origin": "ci", "repository": "example/collector", "source_sha": SHA,
            "profile": "collector", "profile_revision": "profile-1",
            "bundle": {"images": {"collector": image, "collector-ebpf": {**image, "repository": "registry.example/collector-ebpf"}},
                       "components": {"agent": {**image, "repository": "registry.example/agent"}}, "config_bundle_hash": "config-1"}}


def profile():
    return {"name": "collector", "revision": "profile-1", "kind": "collector", "config_bundle_hash": "config-1",
            "contract_revision": "contract-1", "workload_revision": "workload-1"}


def run():
    c = candidate()
    return {"run_id": "run-1", "origin": "ci", "artifact_bundle_hash": g.hashed(c["bundle"]), "candidate": c,
            "verdict": "eligible", "lifecycle": "completed", "provenance_verified": True, "evidence_archived": True,
            "progress": {"expected": 2, "completed": 2, "passed": 2, "queued": 0, "running": 0, "failed": 0, "errors": 0},
            "cells": [{"status": "pass"}, {"status": "pass"}],
            "plan": {"profile": c["profile"], "revision": c["profile_revision"], "config_bundle_hash": "config-1",
                     "contract_revision": "contract-1", "workload_revision": "workload-1"}}


def summary():
    return {"suite": "collector-image-prerequisites", "source_sha": SHA,
            "required_check_ids": g.COLLECTOR_CHECKS[:], "executed_check_ids": g.COLLECTOR_CHECKS[:],
            "executed": 2, "skipped": 0, "failed": 0}


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

    def test_receipts_fail_on_skipped_failed_missing_duplicate_or_wrong_sha(self):
        g.checks_valid([summary()], SHA)
        for key, value in (("skipped", 1), ("failed", 1), ("executed", 0), ("source_sha", OTHER),
                           ("executed_check_ids", [g.COLLECTOR_CHECKS[0]]), ("executed", True),
                           ("required_check_ids", g.COLLECTOR_CHECKS * 2)):
            check = summary()
            check[key] = value
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                g.checks_valid([check], SHA)
        with self.assertRaisesRegex(ValueError, "duplicate"):
            g.checks_valid([summary(), summary()], SHA)

    def test_bundle_uses_dockerfile_pin_not_environment_override(self):
        image = candidate()["bundle"]["images"]["collector"]
        with tempfile.TemporaryDirectory() as folder:
            dockerfile = Path(folder, "Dockerfile")
            pin = "sha256:" + "4" * 64
            dockerfile.write_text("ARG EBPF_AGENT_IMAGE=registry.example/agent:1.2.3@" + pin +
                                  "\nFROM ${EBPF_AGENT_IMAGE} AS ebpf-agent-source\n")
            output = Path(folder, "candidate.json")
            args = argparse.Namespace(kind="collector", repository="example/collector", source_sha=SHA,
                                      image=[role + "=" + value["repository"] + "@" + value["index_digest"]
                                             for role, value in candidate()["bundle"]["images"].items()],
                                      dockerfile=str(dockerfile), output=output)
            with patch.dict(os.environ, {"GAUNTLET_PROFILE": "collector", "GAUNTLET_PROFILE_REVISION": "profile-1",
                                         "GAUNTLET_CONFIG_BUNDLE_HASH": "config-1", "EBPF_AGENT_IMAGE": "wrong"}), \
                    patch.object(g, "profile"), patch.object(g, "resolve", side_effect=lambda repo, ref: {**image, "repository": repo, "index_digest": ref}):
                g.make_bundle(args)
            self.assertEqual(g.load(output)["bundle"]["components"]["agent"]["index_digest"], pin)

    def test_bound_run_rejects_changed_bundle_profile_or_noneligible(self):
        submission = {"candidate": candidate(), "run_id": "run-1", "ci": {"provider": "github", "run_id": 123}}
        with patch.object(g, "profile", return_value=profile()), patch.object(g, "api", return_value=run()):
            self.assertEqual(g.bound_run(submission, eligible=True)["verdict"], "eligible")
        for mutate in (lambda r: r.update(artifact_bundle_hash="other"),
                       lambda r: r["plan"].update(config_bundle_hash="other"),
                       lambda r: r["plan"].update(revision="other"),
                       lambda r: r.update(verdict="baseline-ready"),
                       lambda r: r.update(evidence_archived=False)):
            response = run()
            mutate(response)
            with patch.object(g, "profile", return_value=profile()), patch.object(g, "api", return_value=response):
                with self.assertRaises(ValueError):
                    g.bound_run(submission, eligible=True)

    def test_wait_timeout_does_not_publish_or_cancel_run(self):
        response = {**run(), "verdict": "pending", "lifecycle": "queued"}
        args = argparse.Namespace(submission="submission.json", timeout_seconds=60)
        with patch.object(g, "load", return_value={}), patch.object(g, "bound_run", return_value=response), \
                patch.object(g.time, "monotonic", side_effect=[0, 61]), patch.object(g, "retag") as write:
            with self.assertRaisesRegex(ValueError, "timed out"):
                g.wait(args)
            write.assert_not_called()

    def test_wait_recovers_transient_transport_without_restarting_deadline(self):
        submission = {"candidate": candidate(), "run_id": "run-1", "ci": {"provider": "github", "run_id": 123}}
        for error in (TimeoutError(), ConnectionResetError(), g.socket.gaierror(), g.TransientAPIError(),
                      g.http.client.RemoteDisconnected()):
            clock = [0]
            def sleep(seconds):
                clock[0] += seconds
            with self.subTest(error=type(error).__name__), patch.object(g, "load", return_value=submission), \
                    patch.object(g, "profile", return_value=profile()), \
                    patch.object(g, "api", side_effect=[error, run(), error, run(), run()]), \
                    patch.object(g.time, "monotonic", side_effect=lambda: clock[0]), \
                    patch.object(g.time, "sleep", side_effect=sleep):
                g.wait(argparse.Namespace(submission="submission.json", timeout_seconds=61))
                self.assertEqual(clock[0], 60)
        clock = [0]
        with patch.object(g, "load", return_value=submission), patch.object(g, "profile", return_value=profile()), \
                patch.object(g, "api", side_effect=g.TransientAPIError()), \
                patch.object(g.time, "monotonic", side_effect=lambda: clock[0]), \
                patch.object(g.time, "sleep", side_effect=sleep):
            with self.assertRaisesRegex(ValueError, "timed out"):
                g.wait(argparse.Namespace(submission="submission.json", timeout_seconds=45))
            self.assertEqual(clock[0], 45)

    def test_wait_auth_and_identity_failures_are_not_retried(self):
        submission = {"candidate": candidate(), "run_id": "run-1", "ci": {"provider": "github", "run_id": 123}}
        wrong = run()
        wrong["candidate"]["source_sha"] = OTHER
        for response in (ValueError("gauntlet HTTP 401"), wrong):
            with self.subTest(response=response), patch.object(g, "load", return_value=submission), \
                    patch.object(g, "profile", return_value=profile()), \
                    patch.object(g, "api", side_effect=[response]), \
                    patch.object(g.time, "monotonic", return_value=0), patch.object(g.time, "sleep") as sleep:
                with self.assertRaises(ValueError):
                    g.wait(argparse.Namespace(submission="submission.json", timeout_seconds=60))
                sleep.assert_not_called()

    def test_wait_does_not_accept_eligibility_after_deadline(self):
        clock = [0]
        def late_eligibility(*args, **kwargs):
            clock[0] = 61
            return run()
        with patch.object(g, "load", return_value={}), patch.object(g, "bound_run", side_effect=late_eligibility), \
                patch.object(g.time, "monotonic", side_effect=lambda: clock[0]), patch.object(g.time, "sleep") as sleep:
            with self.assertRaisesRegex(ValueError, "timed out"):
                g.wait(argparse.Namespace(submission="submission.json", timeout_seconds=60))
            sleep.assert_not_called()

    def test_stale_main_skips_only_canary_writes(self):
        submission = {"candidate": candidate(), "run_id": "run-1"}
        with patch.object(g, "load", return_value=submission), patch.object(g, "git", return_value=SHA), \
                patch.object(g, "bound_run"), patch.object(g, "resolve", side_effect=lambda repo, ref: next(
                    image for image in candidate()["bundle"]["images"].values() if image["repository"] == repo)), \
                patch.object(g, "remote_main", return_value=OTHER), patch.object(g, "retag") as write:
            g.promote(argparse.Namespace(submission="submission.json", tag="canary"))
            write.assert_not_called()

    def test_canary_publication_finishes_pair_then_rejects_stale_queued_jobs(self):
        selected = {"candidate": candidate(), "run_id": "run-1"}
        tip = [SHA]
        aliases = {}
        writes = []
        def publish(image, tag):
            aliases[image["repository"]] = image.copy()
            writes.append(image["repository"])
            # A push while the first image is publishing must not split the pair.
            tip[0] = OTHER
        with patch.object(g, "load", side_effect=lambda _: selected), \
                patch.object(g, "git", side_effect=lambda *args: selected["candidate"]["source_sha"]), \
                patch.object(g, "bound_run"), patch.object(g, "remote_main", side_effect=lambda: tip[0]), \
                patch.object(g, "resolve", side_effect=lambda repo, ref: next(
                    image for image in selected["candidate"]["bundle"]["images"].values() if image["repository"] == repo)), \
                patch.object(g, "retag", side_effect=publish):
            args = argparse.Namespace(submission="submission.json", tag="canary")
            g.promote(args)
            self.assertEqual(aliases, {image["repository"]: image for image in candidate()["bundle"]["images"].values()})
            self.assertEqual(len(writes), 2)
            newer = candidate()
            newer["source_sha"] = OTHER
            for image in newer["bundle"]["images"].values():
                image["index_digest"] = "sha256:" + "9" * 64
            selected = {"candidate": newer, "run_id": "run-2"}
            g.promote(args)
            published = aliases.copy()
            self.assertEqual(published, {image["repository"]: image for image in newer["bundle"]["images"].values()})
            selected = {"candidate": candidate(), "run_id": "run-1"}
            g.promote(args)
            self.assertEqual(aliases, published)
            self.assertEqual(len(writes), 4)

    def test_retag_preserves_and_verifies_exact_index(self):
        image = candidate()["bundle"]["images"]["collector"]
        with patch.object(g, "command") as command, patch.object(g, "resolve", return_value=image):
            g.retag(image, "1.2.3")
            args = command.call_args.args[0]
            self.assertIn("--all", args)
            self.assertIn("--preserve-digests", args)
            self.assertEqual(args[-2], "docker://" + image["repository"] + "@" + image["index_digest"])
        with patch.object(g, "command"), patch.object(g, "resolve", return_value={}):
            with self.assertRaisesRegex(ValueError, "retagged index"):
                g.retag(image, "latest")

    def test_latest_never_regresses_version_or_source(self):
        image = candidate()["bundle"]["images"]["collector"]
        config = {"Labels": {"org.opencontainers.image.version": "2.0.0", "org.opencontainers.image.revision": OTHER}}
        with patch.object(g, "registry_tags", return_value={"latest"}), patch.object(g, "resolve", return_value=image), \
                patch.object(g, "image_configs", return_value=iter([config])):
            self.assertFalse(g.latest_allowed(image, g.VERSION.fullmatch("v1.9.9"), SHA))
        config["Labels"]["org.opencontainers.image.version"] = "1.0.0"
        with patch.object(g, "registry_tags", return_value={"latest"}), patch.object(g, "resolve", return_value=image), \
                patch.object(g, "image_configs", return_value=iter([config])), patch.object(g, "ancestor", return_value=True):
            self.assertFalse(g.latest_allowed(image, g.VERSION.fullmatch("v2.0.0"), SHA))


    def test_noneligible_release_cannot_retag(self):
        with patch.object(g, "load", return_value={"candidate": candidate(), "run_id": "run-1"}), \
                patch.object(g, "git", return_value=SHA), \
                patch.object(g, "bound_run", side_effect=ValueError("not eligible")), \
                patch.object(g, "retag") as write:
            with self.assertRaisesRegex(ValueError, "not eligible"):
                g.promote(argparse.Namespace(submission="submission.json", tag="v1.2.3"))
            write.assert_not_called()

    def test_receipt_binds_provider_identity_and_actual_summaries(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            g.save(root / "candidate.json", candidate())
            g.save(root / "summary.json", summary())
            args = argparse.Namespace(candidate=root / "candidate.json", summary=[root / "summary.json"],
                                      provider="github", run_id="123", run_attempt="2", ref="refs/heads/main",
                                      prerequisite_attempts=None, output=root / "gauntlet-receipt.json")
            g.make_receipt(args)
            receipt = g.load(args.output)
            self.assertEqual(receipt["run_id"], 123)
            self.assertEqual(receipt["run_attempt"], 2)
            self.assertEqual(receipt["bundle"], candidate()["bundle"])
            self.assertEqual(receipt["checks"], [summary()])
            args.provider, args.run_id, args.run_attempt = "depot", "run_opaque", "attempt_opaque"
            with self.assertRaisesRegex(ValueError, "actual upstream"):
                g.make_receipt(args)
            g.save(root / "attempts.json", {"ci.yml:build-image": "attempt_upstream"})
            args.prerequisite_attempts = root / "attempts.json"
            g.make_receipt(args)
            self.assertEqual(g.load(args.output)["prerequisite_attempts"], {"ci.yml:build-image": "attempt_upstream"})


    def test_completed_all_passed_waits_for_archive_before_returning(self):
        pending = {**run(), "verdict": "incomplete", "evidence_archived": False}
        args = argparse.Namespace(submission="submission.json", timeout_seconds=60)
        with patch.object(g, "load", return_value={}), \
                patch.object(g, "bound_run", side_effect=[pending, run(), run()]) as bound, \
                patch.object(g.time, "monotonic", return_value=0), patch.object(g.time, "sleep") as sleep:
            g.wait(args)
            sleep.assert_called_once_with(30)
            self.assertEqual(bound.call_count, 3)
            self.assertTrue(bound.call_args.kwargs["eligible"])

    def test_wait_rejects_failure_cancellation_and_nonarchive_incomplete(self):
        for mutate in (lambda r: r.update(verdict="failed"),
                       lambda r: r.update(lifecycle="cancelled"),
                       lambda r: r.update(lifecycle="interrupted"),
                       lambda r: r["progress"].update(errors=1),
                       lambda r: r["progress"].update(failed=1),
                       lambda r: r.update(cells=[{"status": "error"}]),
                       lambda r: r.update(evidence_archived=True)):
            response = {**run(), "verdict": "incomplete", "evidence_archived": False}
            mutate(response)
            with patch.object(g, "load", return_value={}), patch.object(g, "bound_run", return_value=response), \
                    patch.object(g.time, "monotonic", return_value=0), patch.object(g.time, "sleep") as sleep:
                with self.assertRaises(ValueError):
                    g.wait(argparse.Namespace(submission="submission.json", timeout_seconds=60))
                sleep.assert_not_called()

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
        args = argparse.Namespace(candidate="candidate.json", provider="github", run_id="123",
                                  run_attempt="1", artifact_id="456", output="submission.json")
        with patch.object(g, "load", return_value=candidate()), patch.object(g, "profile"), \
                patch.object(g, "api", side_effect=[TimeoutError(), g.TransientAPIError(), run()]) as api, \
                patch.object(g, "bound_run"), patch.object(g, "save"), patch.object(g.time, "sleep") as sleep, \
                patch.object(g, "environment", return_value="https://service.example"):
            g.submit(args)
            self.assertEqual(api.call_count, 3)
            self.assertEqual(api.call_args_list[0], api.call_args_list[1])
            self.assertEqual(api.call_args_list[1], api.call_args_list[2])
            self.assertEqual([call.args[0] for call in sleep.call_args_list], [5, 10])
        for error, attempts in ((ValueError("HTTP 400"), 1), (ValueError("HTTP 401"), 1),
                                (TimeoutError(), 3)):
            with patch.object(g, "load", return_value=candidate()), patch.object(g, "profile"), \
                    patch.object(g, "api", side_effect=error) as api, patch.object(g.time, "sleep"):
                with self.assertRaises(type(error)):
                    g.submit(args)
                self.assertEqual(api.call_count, attempts)

    def test_retained_submission_must_match_current_ci_source_and_run(self):
        submission = {"candidate": candidate(), "run_id": "run-1", "ci": {"provider": "github", "run_id": 123}}
        for variable, value in (("GITHUB_SHA", OTHER), ("GITHUB_REPOSITORY", "other/repository"), ("GITHUB_RUN_ID", "999")):
            with patch.dict(os.environ, {variable: value}), patch.object(g, "profile"), patch.object(g, "api") as api:
                with self.assertRaises(ValueError):
                    g.bound_run(submission)
                api.assert_not_called()

    def test_release_phases_write_only_their_own_aliases(self):
        images = candidate()["bundle"]["images"]
        def git(*args):
            return SHA + "\trefs/tags/v1.2.3" if args[0] == "ls-remote" else SHA
        for latest_only in (False, True):
            args = argparse.Namespace(submission="submission.json", tag="v1.2.3",
                                      skip_latest=not latest_only, latest_only=latest_only, published_release=latest_only)
            with patch.object(g, "load", return_value={"candidate": candidate(), "run_id": "run-1"}), \
                    patch.object(g, "git", side_effect=git), patch.object(g, "ancestor", return_value=True), \
                    patch.object(g, "bound_run"), patch.object(g, "registry_tags", return_value={"1.2.3"}), \
                    patch.object(g, "resolve", side_effect=lambda repo, ref: next(
                        image for image in images.values() if image["repository"] == repo)), \
                    patch.object(g, "latest_allowed", return_value=True) as allowed, patch.object(g, "retag") as write:
                g.promote(args)
                self.assertEqual([call.args[1] for call in write.call_args_list],
                                 ["latest", "latest"] if latest_only else ["1.2.3", "1.2.3"])
                self.assertEqual(allowed.call_count, 2 if latest_only else 0)
        with patch.object(g, "load", return_value={"candidate": candidate(), "run_id": "run-1"}), \
                patch.object(g, "git", side_effect=git), patch.object(g, "ancestor", return_value=True), \
                patch.object(g, "bound_run"), patch.object(g, "registry_tags", return_value=set()), \
                patch.object(g, "resolve", side_effect=lambda repo, ref: next(
                    image for image in images.values() if image["repository"] == repo)), patch.object(g, "retag") as write:
            with self.assertRaisesRegex(ValueError, "before latest-only"):
                g.promote(argparse.Namespace(submission="submission.json", tag="v1.2.3", latest_only=True))
            write.assert_not_called()

    def test_release_prerelease_publishes_version_only_and_build_metadata_is_rejected(self):
        images = candidate()["bundle"]["images"]
        tag = "v1.2.3-rc.1"
        def git(*args):
            return SHA + "\trefs/tags/" + tag if args[0] == "ls-remote" else SHA
        with patch.object(g, "load", return_value={"candidate": candidate(), "run_id": "run-1"}), \
                patch.object(g, "git", side_effect=git), patch.object(g, "ancestor", return_value=True), \
                patch.object(g, "bound_run"), patch.object(g, "registry_tags", return_value=set()), \
                patch.object(g, "resolve", side_effect=lambda repo, ref: next(
                    image for image in images.values() if image["repository"] == repo)), \
                patch.object(g, "retag") as write:
            g.promote(argparse.Namespace(submission="submission.json", tag=tag))
            self.assertEqual([call.args[1] for call in write.call_args_list], ["1.2.3-rc.1", "1.2.3-rc.1"])
            write.reset_mock()
            for invalid in ("v1.2.3+build", "v1.2.3-rc.1+build"):
                with self.subTest(tag=invalid), self.assertRaisesRegex(ValueError, "promotion tag"):
                    g.promote(argparse.Namespace(submission="submission.json", tag=invalid))
            write.assert_not_called()

    def test_published_release_selection_keeps_repo_profile_and_exact_eligibility_guards(self):
        submission = {"candidate": candidate(), "run_id": "run-1", "ci": {"provider": "github", "run_id": 123}}
        with patch.dict(os.environ, {"GITHUB_SHA": OTHER, "GITHUB_RUN_ID": "999",
                                    "GITHUB_REPOSITORY": candidate()["repository"]}), \
                patch.object(g, "profile", return_value=profile()), patch.object(g, "api", return_value=run()):
            g.bound_run(submission, eligible=True, published_release=True)
        for mutate in (lambda r: r.update(artifact_bundle_hash="wrong"),
                       lambda r: r.update(verdict="incomplete"), lambda r: r.update(evidence_archived=False)):
            response = run()
            mutate(response)
            with patch.object(g, "profile"), patch.object(g, "api", return_value=response):
                with self.assertRaises(ValueError):
                    g.bound_run(submission, eligible=True, published_release=True)
        with patch.dict(os.environ, {"GITHUB_REPOSITORY": "wrong/repository"}), patch.object(g, "profile"), \
                patch.object(g, "api") as api:
            with self.assertRaises(ValueError):
                g.bound_run(submission, eligible=True, published_release=True)
            api.assert_not_called()
        with patch.object(g, "load", return_value=submission), patch.object(g, "git", return_value=SHA), \
                patch.object(g, "retag") as write:
            with self.assertRaisesRegex(ValueError, "requires latest-only"):
                g.promote(argparse.Namespace(submission="submission.json", tag="v1.2.3", published_release=True))
            write.assert_not_called()

    def test_retained_profile_must_match_current_required_configuration(self):
        with patch.dict(os.environ, {"GAUNTLET_PROFILE": "collector", "GAUNTLET_PROFILE_REVISION": "profile-1",
                                    "GAUNTLET_CONFIG_BUNDLE_HASH": "other-config"}), patch.object(g, "api") as api:
            with self.assertRaisesRegex(ValueError, "required profile/configuration"):
                g.profile(candidate())
            api.assert_not_called()



if __name__ == "__main__":
    unittest.main()
