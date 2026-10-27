import hashlib
import importlib.util
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "Scripts" / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


gate = load("validate-release")
metadata = load("release-metadata")
SHA = "a" * 40


class ReleaseTrustTests(unittest.TestCase):
    def test_tag_context_only(self):
        valid = ["v1.2.3", "refs/tags/v1.2.3", SHA, "penso/CommandDrag", "penso", "penso"]
        gate.validate_context(*valid)
        for index, value in [(0, "v1.2.3\ninjected"), (1, "refs/heads/main"), (1, "refs/tags/v1.2.2"),
                             (2, "shortsha"), (3, "someone/CommandDrag"), (4, "someone"), (5, "someone")]:
            with self.subTest(index=index, value=value), self.assertRaises(ValueError):
                changed = valid.copy()
                changed[index] = value
                gate.validate_context(*changed)

    def run_record(self, **changes):
        return {"id": 1, "head_sha": SHA, "head_branch": "main", "event": "push",
                "head_repository": {"full_name": "penso/CommandDrag"},
                "status": "completed", "conclusion": "success", **changes}

    def test_ci_must_match_source_branch_event_and_repository(self):
        self.assertEqual(gate.ci_state([self.run_record()], SHA), "success")
        for changes in [{"head_sha": "b" * 40}, {"head_branch": "feature"}, {"event": "pull_request"},
                        {"head_repository": {"full_name": "someone/CommandDrag"}}]:
            with self.subTest(changes=changes):
                self.assertEqual(gate.ci_state([self.run_record(**changes)], SHA), "pending")

    def test_failed_or_cancelled_ci_cannot_authorize_release(self):
        for conclusion in ("failure", "cancelled", "skipped", "timed_out", "neutral"):
            with self.subTest(conclusion=conclusion):
                self.assertEqual(gate.ci_state([self.run_record(conclusion=conclusion)], SHA), "failure")
        runs = [self.run_record(), self.run_record(id=2, status="in_progress", conclusion=None)]
        self.assertEqual(gate.ci_state(runs, SHA), "pending")


class ReleaseMetadataTests(unittest.TestCase):
    def test_checksums_cover_exact_bytes(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            path = directory / "artifact.zip"
            path.write_bytes(b"final signed artifact")
            metadata.write_checksums(directory, [path.name])
            for algo in ("sha256", "sha512"):
                expected = hashlib.new(algo, path.read_bytes()).hexdigest()
                self.assertEqual((directory / (algo.upper() + "SUMS")).read_text(), f"{expected}  artifact.zip\n")
            path.write_bytes(b"tampered")
            self.assertNotIn(hashlib.sha256(path.read_bytes()).hexdigest(), (directory / "SHA256SUMS").read_text())

    def test_reject_missing_empty_and_symlink_artifacts(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            (directory / "empty").touch()
            (directory / "real").write_bytes(b"data")
            (directory / "link").symlink_to(directory / "real")
            for name in ("missing", "empty", "link"):
                with self.subTest(name=name), self.assertRaises(ValueError):
                    metadata.checksum_file(directory / name, "sha256")

    def test_sbom_binds_source_and_distinguishes_system_frameworks(self):
        bom = metadata.make_sbom("v1.2.3", SHA, ROOT, [])
        self.assertEqual(bom["metadata"]["component"]["version"], "1.2.3")
        self.assertIn(SHA, bom["metadata"]["component"]["externalReferences"][0]["url"])
        focus = bom["components"][0]
        self.assertEqual(focus["hashes"][0]["content"], hashlib.sha256((ROOT / "Sources/Focus.m").read_bytes()).hexdigest())
        self.assertEqual(bom["components"][-1]["scope"], "optional")
        refs = {c["bom-ref"] for c in bom["components"]}
        self.assertEqual(set(bom["dependencies"][0]["dependsOn"]), refs)


if __name__ == "__main__":
    unittest.main()
