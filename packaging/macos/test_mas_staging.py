#!/usr/bin/env python3
"""Focused fake MAS staging regressions; no native commands or product artifacts.

Run only by Root with Python 3.14 -I -B. All fake inputs/outputs live below a
fresh TemporaryDirectory in the resolved, explicitly provided TMPDIR. Fake model
bytes replace only the four expected content hashes during fixture tests; the
original production name/hash constants are asserted separately.
"""
from pathlib import Path
import hashlib
import importlib.util
import json
import os
import stat
import tempfile
import unittest
from unittest.mock import patch


MODULE_SHA256 = "f908afa23799f64f260f0ff6797419a9adfaa6fe48851b9c6669a3206bae4d04"
EXPECTED_NAMES = {
    "text-detection.rten", "text-recognition.rten",
    "text-detection.rten.LICENCE.txt", "text-recognition.rten.LICENCE.txt",
    "ATTRIBUTION.txt",
}
EXPECTED_HASHES = {
    "text-detection.rten": "f15cfb56bd02c4bf478a20343986504a1f01e1665c2b3a0ad66340f054b1b5ca",
    "text-recognition.rten": "e484866d4cce403175bd8d00b128feb08ab42e208de30e42cd9889d8f1735a6e",
    "text-detection.rten.LICENCE.txt": "28a9529c7d0bb4dc51f4bf5c116a3d16ef247a052f7591466768ddf563fd1cf5",
    "text-recognition.rten.LICENCE.txt": "28a9529c7d0bb4dc51f4bf5c116a3d16ef247a052f7591466768ddf563fd1cf5",
}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def load_staging():
    path = Path(__file__).absolute().with_name("mas_staging.py")
    if path.is_symlink() or not path.is_file():
        raise RuntimeError("Expected adjacent ordinary staging module")
    source = path.read_bytes()
    if digest(source) != MODULE_SHA256:
        raise RuntimeError("Staging module differs from the frozen source under test")
    spec = importlib.util.spec_from_file_location("mixel_mas_staging_test_subject", path)
    if spec is None or spec.loader is None:
        raise RuntimeError("Cannot create source module spec")
    module = importlib.util.module_from_spec(spec)
    exec(compile(source, str(path), "exec"), module.__dict__)
    return module


class StagingRegressionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        tmp = os.environ.get("TMPDIR", "")
        if not tmp:
            raise RuntimeError("Root must explicitly provide TMPDIR")
        cls.tmp_parent = Path(tmp).resolve(strict=True)
        if not cls.tmp_parent.is_dir():
            raise RuntimeError("TMPDIR must be an existing directory")
        cls.subject = load_staging()

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="mixel-mas-staging-fake-", dir=self.tmp_parent)
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def fixture(self, name="fixture"):
        case = self.root / name
        source = case / "accepted" / "MIXEL Print.app" / "Contents" / "Resources" / "models"
        source.mkdir(parents=True)
        payload = {name: ("FAKE ONLY " + name + "\n").encode() for name in sorted(EXPECTED_NAMES)}
        rows = []
        for name, data in payload.items():
            path = source / name
            path.write_bytes(data)
            path.chmod(0o644)
            rows.append({"path": "Contents/Resources/models/" + name,
                         "bytes": len(data), "sha256": digest(data), "mode": 0o644})
        value = {"schema": "mixel.mas-package.v1", "app": "print", "version": "0.7.1",
                 "buildNumber": "2", "arch": "aarch64", "signedAppFiles": rows}
        provenance = case / "accepted-print2.provenance.json"
        provenance.write_text(json.dumps(value, sort_keys=True), encoding="utf-8")
        provenance.chmod(0o644)
        parent = case / "new" / "MIXEL Print.app" / "Contents" / "Resources"
        parent.mkdir(parents=True)
        destination = parent / "models"
        env = {"MACOS_MAS_PRINT_MODELS_DIR": str(source),
               "MACOS_MAS_PRINT_MODELS_PROVENANCE": str(provenance),
               "MACOS_MAS_PRINT_MODELS_PROVENANCE_SHA256": digest(provenance.read_bytes())}
        fake_pins = {name: digest(payload[name]) for name in EXPECTED_HASHES}
        return source, destination, provenance, env, payload, fake_pins

    def invoke_fake(self, fixture):
        _, destination, _, env, _, fake_pins = fixture
        with patch.object(self.subject, "PRINT_MODEL_SHA256", fake_pins):
            return self.subject.stage_retained_print_models(destination, env)

    def test_exact_rten_five_success_is_byte_preserving(self):
        fixture = self.fixture()
        source, destination, provenance, _, payload, _ = fixture
        before = {path.name: path.read_bytes() for path in source.iterdir()}
        provenance_before = provenance.read_bytes()
        result = self.invoke_fake(fixture)
        self.assertEqual({path.name for path in destination.iterdir()}, EXPECTED_NAMES)
        self.assertEqual({path.name: path.read_bytes() for path in destination.iterdir()}, payload)
        self.assertTrue(all(stat.S_IMODE(path.stat().st_mode) == 0o644 for path in destination.iterdir()))
        self.assertEqual({path.name: path.read_bytes() for path in source.iterdir()}, before)
        self.assertEqual(provenance.read_bytes(), provenance_before)
        self.assertEqual({row["path"] for row in result["reusedFiles"]}, EXPECTED_NAMES)
        self.assertEqual(len(result["stagedFiles"]), 5)
        self.assertIs(result["modelHelperInvoked"], False)
        self.assertIs(result["downloadsPerformed"], False)

    def test_wrong_retained_content_hash_is_refused(self):
        fixture = self.fixture()
        fixture[0].joinpath("text-recognition.rten").write_bytes(b"FAKE ALTERED MODEL\n")
        with self.assertRaisesRegex(self.subject.StagingFailure, "Source differs"):
            self.invoke_fake(fixture)

    def test_wrong_provenance_hash_is_refused_before_destination(self):
        fixture = self.fixture()
        fixture[3]["MACOS_MAS_PRINT_MODELS_PROVENANCE_SHA256"] = "0" * 64
        with self.assertRaisesRegex(self.subject.StagingFailure, "provenance SHA256 differs"):
            self.invoke_fake(fixture)
        self.assertFalse(fixture[1].exists())

    def test_wrong_provenance_identity_is_refused_before_destination(self):
        fixture = self.fixture()
        value = json.loads(fixture[2].read_text(encoding="utf-8"))
        value["buildNumber"] = "1"
        fixture[2].write_text(json.dumps(value), encoding="utf-8")
        fixture[3]["MACOS_MAS_PRINT_MODELS_PROVENANCE_SHA256"] = digest(fixture[2].read_bytes())
        with self.assertRaisesRegex(self.subject.StagingFailure, "Exact accepted Oct22 Print2"):
            self.invoke_fake(fixture)
        self.assertFalse(fixture[1].exists())

    def test_missing_or_extra_retained_membership_is_refused(self):
        for mutation in ("missing", "extra"):
            with self.subTest(mutation=mutation):
                fixture = self.fixture(mutation)
                if mutation == "missing":
                    fixture[0].joinpath("ATTRIBUTION.txt").unlink()
                else:
                    fixture[0].joinpath("unexpected.txt").write_bytes(b"FAKE EXTRA\n")
                    fixture[0].joinpath("unexpected.txt").chmod(0o644)
                with self.assertRaisesRegex(self.subject.StagingFailure, "membership differs"):
                    self.invoke_fake(fixture)
                self.assertFalse(fixture[1].exists())

    def test_existing_destination_is_never_overwritten(self):
        fixture = self.fixture()
        fixture[1].mkdir()
        sentinel = fixture[1] / "preserve.txt"
        sentinel.write_bytes(b"PRESERVE FAKE SENTINEL\n")
        with self.assertRaises(FileExistsError):
            self.invoke_fake(fixture)
        self.assertEqual({path.name for path in fixture[1].iterdir()}, {"preserve.txt"})
        self.assertEqual(sentinel.read_bytes(), b"PRESERVE FAKE SENTINEL\n")

    def test_winit_paths_match_all_seven_source_layouts(self):
        licence = b"FAKE WINIT LICENCE ONLY\n"
        for app in ("photo", "vector", "film", "light", "print", "effects", "design"):
            with self.subTest(app=app):
                root = self.root / ("mixel-" + app)
                relative = "vendor/winit" if app == "print" else "mixel/vendor/winit"
                vendor = root / relative
                vendor.mkdir(parents=True)
                (root / "Cargo.lock").write_text("package = []\n", encoding="utf-8")
                (vendor / "LICENSE").write_bytes(licence)
                (vendor / "MIXEL-PATCH.md").write_bytes(b"FAKE MODIFICATION NOTICE\n")
                resources = self.root / ("staged-" + app) / ("MIXEL " + app.title() + ".app") / "Contents" / "Resources"
                resources.mkdir(parents=True)
                with patch.object(self.subject, "PHOTO_NOTICES", ()), patch.object(self.subject, "WINIT_LICENSE", (len(licence), digest(licence))):
                    names = self.subject.copy_additional_legal(root, resources, ["LICENSE"])
                self.assertEqual(names, [relative + "/LICENSE", relative + "/MIXEL-PATCH.md"])
                staged = resources / "Licenses" / "repository" / relative
                self.assertEqual((staged / "LICENSE").read_bytes(), licence)
                self.assertEqual((staged / "MIXEL-PATCH.md").read_bytes(), (vendor / "MIXEL-PATCH.md").read_bytes())
                self.assertTrue(all(stat.S_IMODE(path.stat().st_mode) == 0o644 for path in staged.iterdir()))

    def test_production_model_allowlist_and_hash_pins_are_exact(self):
        self.assertEqual(self.subject.PRINT_MODEL_NAMES, frozenset(EXPECTED_NAMES))
        self.assertEqual(self.subject.PRINT_MODEL_SHA256, EXPECTED_HASHES)
        self.assertEqual(self.subject.WINIT_LICENSE, (11323, "6dc0e068dcf3a5bc8e054205b85b7720e1d49265bbc64bf515d2cf79197df69a"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
