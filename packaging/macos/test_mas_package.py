#!/usr/bin/env python3
"""Pure MAS deployment-policy regressions; never build, sign or contact a store.

Per checkout: python3 -B packaging/macos/test_mas_package.py
Before integration: pass --repository /absolute/mixel-APP --helper /absolute/mas_package.py.
Run once for each of the seven real checkouts to cover their actual app templates.
"""

from __future__ import annotations

import argparse
import copy
import datetime as dt
from pathlib import Path
import plistlib
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
REPOSITORY = Path(__file__).resolve().parents[2]
HELPER = REPOSITORY / "packaging" / "macos" / "mas_package.py"
MINIMUMS = {"aarch64": "12.0", "x86_64": "11.0", "universal": "11.0"}
SOURCE_SHA = "a" * 40
VERSION = "1.2.3"
BUILD_NUMBER = "17"


def load_helper(source):
    # Execute exactly the file being reviewed, without any .pyc substitution.
    module = types.ModuleType("mas_package_under_test")
    module.__file__ = str(source)
    exec(compile(source.read_bytes(), str(source), "exec"), module.__dict__)
    return module


class MasDeploymentMinimumTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.mas = load_helper(HELPER)
        if REPOSITORY.name not in cls.mas.CONFIG:
            raise AssertionError("--repository must name one of the seven real MIXEL checkouts")
        cls.config = cls.mas.CONFIG[REPOSITORY.name]
        cls.original_path = REPOSITORY / "packaging" / "macos" / "Info.plist.in"
        cls.original_bytes = cls.original_path.read_bytes()
        cls.original_info = plistlib.loads(cls.original_bytes)

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="mixel-mas-minimum-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / REPOSITORY.name
        self.here = self.root / "packaging" / "macos"
        self.here.mkdir(parents=True)
        self.template = self.here / "Info.plist.in"
        self.template.write_bytes(self.original_bytes)
        self.prefix = self.config[3]
        # Any unexpected native boundary fails rather than starting a process.
        for name in ("run", "Popen"):
            guard = patch.object(self.mas.subprocess, name, side_effect=AssertionError("No external process is permitted in deployment-policy tests"))
            guard.start()
            self.addCleanup(guard.stop)

    def tearDown(self):
        self.assertEqual(self.original_path.read_bytes(), self.original_bytes, "The real Developer ID template must never be changed")

    def info(self, arch, encryption=True):
        return self.mas.generated_info(self.here, self.config, VERSION, BUILD_NUMBER, SOURCE_SHA, encryption, arch)

    def environment(self, arch, supplied=None):
        env = dict(supplied or {})
        expected_command = ["git", "-C", str(self.root), "rev-parse", "HEAD"]

        def fake_git(argv, **kwargs):
            self.assertEqual(argv, expected_command)
            self.assertEqual(kwargs, {})
            return SOURCE_SHA + "\n"

        with patch.object(self.mas, "command_text", side_effect=fake_git) as git:
            result, target = self.mas.build_environment(self.root, self.prefix, env, arch)
        git.assert_called_once_with(expected_command)
        return result, target

    def mutate_template(self, key, value=None, *, remove=False):
        info = copy.deepcopy(self.original_info)
        if remove:
            info.pop(key, None)
        else:
            info[key] = value
        self.template.write_bytes(plistlib.dumps(info))

    def test_explicit_architecture_minimums(self):
        for arch, expected in MINIMUMS.items():
            with self.subTest(arch=arch):
                self.assertEqual(self.mas.deployment_minimum(arch), expected)

    def test_build_environment_and_generated_info_agree_for_every_architecture(self):
        for arch, expected in MINIMUMS.items():
            with self.subTest(arch=arch):
                environment, target = self.environment(arch)
                info = self.info(arch)
                self.assertEqual(environment["MACOSX_DEPLOYMENT_TARGET"], expected)
                self.assertEqual(info["LSMinimumSystemVersion"], expected)
                self.assertEqual(environment["MACOSX_DEPLOYMENT_TARGET"], info["LSMinimumSystemVersion"])
                self.assertEqual(target, (self.root / "target" / "macos-mas").resolve())
                self.assertEqual(environment["CARGO_TARGET_DIR"], str(target))
                self.assertFalse(target.exists(), "Policy evaluation must not create the build target")

    def test_caller_deployment_override_cannot_change_the_selected_minimum(self):
        for arch, expected in MINIMUMS.items():
            for requested in ("10.15", "11.0", "12.0", "99.0", ""):
                with self.subTest(arch=arch, requested=requested):
                    supplied = {"MACOSX_DEPLOYMENT_TARGET": requested, "UNRELATED_FIXTURE_SETTING": "preserved"}
                    before = dict(supplied)
                    environment, _ = self.environment(arch, supplied)
                    self.assertEqual(environment["MACOSX_DEPLOYMENT_TARGET"], expected)
                    self.assertEqual(environment["UNRELATED_FIXTURE_SETTING"], "preserved")
                    self.assertEqual(supplied, before)

    def test_build_identity_and_receipt_environment_keep_the_selected_minimum(self):
        for arch, expected in MINIMUMS.items():
            with self.subTest(arch=arch):
                environment, target = self.environment(arch)
                self.assertEqual(environment[self.prefix + "_BUILD_SHA"], SOURCE_SHA)
                date = dt.date.fromisoformat(environment[self.prefix + "_BUILD_DATE"])
                self.assertIsInstance(date, dt.date)
                captured = self.mas.captured_build_env(environment, self.prefix)
                self.assertEqual(captured["MACOSX_DEPLOYMENT_TARGET"], expected)
                self.assertEqual(captured["CARGO_TARGET_DIR"], str(target))
                self.assertEqual(captured[self.prefix + "_BUILD_SHA"], SOURCE_SHA)

    def test_generated_info_retains_actual_product_build_and_encryption_bindings(self):
        slug, title, _, _, brand, _ = self.config
        for arch in MINIMUMS:
            for encryption in (False, True):
                with self.subTest(arch=arch, encryption=encryption):
                    info = self.info(arch, encryption)
                    self.assertEqual(info["CFBundleIdentifier"], "ch.mixel." + slug)
                    self.assertEqual(info["CFBundleExecutable"], "MIXEL " + title)
                    self.assertEqual(info["CFBundleDisplayName"], "MIXEL " + title)
                    self.assertEqual(info["CFBundleShortVersionString"], VERSION)
                    self.assertEqual(info["CFBundleVersion"], BUILD_NUMBER)
                    self.assertEqual(info[brand + "BuildCommit"], SOURCE_SHA)
                    self.assertIs(info["ITSAppUsesNonExemptEncryption"], encryption)
                    self.assertEqual(info["LSApplicationCategoryType"], self.original_info["LSApplicationCategoryType"])

    def test_generated_info_does_not_mutate_the_generic_template(self):
        self.assertEqual(self.original_info["LSMinimumSystemVersion"], "11.0")
        for arch in MINIMUMS:
            with self.subTest(arch=arch):
                self.info(arch)
                self.assertEqual(self.template.read_bytes(), self.original_bytes)

    def test_app_purpose_strings_and_document_types_are_preserved(self):
        for arch in MINIMUMS:
            with self.subTest(arch=arch):
                info = self.info(arch)
                for key in ("NSMicrophoneUsageDescription", "NSAppleEventsUsageDescription", "CFBundleDocumentTypes", "UTExportedTypeDeclarations", "UTImportedTypeDeclarations"):
                    self.assertEqual(info.get(key), self.original_info.get(key), key)
                if self.config[0] == "film":
                    self.assertTrue(info["NSMicrophoneUsageDescription"])
                if self.config[0] == "light":
                    self.assertTrue(info["NSAppleEventsUsageDescription"])

    def test_unknown_architecture_is_rejected_at_all_three_policy_boundaries(self):
        for arch in ("arm64", "aarch64-apple-darwin", "x86", "", "universal2"):
            with self.subTest(arch=arch, boundary="minimum"):
                with self.assertRaises(self.mas.Failure):
                    self.mas.deployment_minimum(arch)
            with self.subTest(arch=arch, boundary="plist"):
                with self.assertRaises(self.mas.Failure):
                    self.info(arch)
            with self.subTest(arch=arch, boundary="environment"):
                with patch.object(self.mas, "command_text", side_effect=AssertionError("Unknown architecture must fail before Git")) as git:
                    with self.assertRaises(self.mas.Failure):
                        self.mas.build_environment(self.root, self.prefix, {}, arch)
                git.assert_not_called()

    def test_stale_or_invalid_generic_template_minimum_is_rejected(self):
        for value in ("10.15", "12.0", "13.0", "", 11, False):
            self.mutate_template("LSMinimumSystemVersion", value)
            for arch in MINIMUMS:
                with self.subTest(value=value, arch=arch), self.assertRaises(self.mas.Failure):
                    self.info(arch)
        self.mutate_template("LSMinimumSystemVersion", remove=True)
        for arch in MINIMUMS:
            with self.subTest(missing=True, arch=arch), self.assertRaises(self.mas.Failure):
                self.info(arch)

    def test_non_dictionary_template_is_rejected(self):
        self.template.write_bytes(plistlib.dumps(["not an Info dictionary"]))
        for arch in MINIMUMS:
            with self.subTest(arch=arch), self.assertRaises(self.mas.Failure):
                self.info(arch)

    def test_other_product_template_and_missing_category_are_rejected(self):
        for key, value in (("CFBundleIdentifier", "ch.mixel.not-this-app"), ("CFBundleExecutable", "MIXEL Other"), ("LSApplicationCategoryType", "")):
            self.mutate_template(key, value)
            for arch in MINIMUMS:
                with self.subTest(key=key, arch=arch), self.assertRaises(self.mas.Failure):
                    self.info(arch)

    def test_missing_required_product_purpose_is_rejected(self):
        key = {"film": "NSMicrophoneUsageDescription", "light": "NSAppleEventsUsageDescription"}.get(self.config[0])
        if key is None:
            # Other apps still exercise the same real missing-category boundary.
            key = "LSApplicationCategoryType"
        self.mutate_template(key, remove=True)
        for arch in MINIMUMS:
            with self.subTest(key=key, arch=arch), self.assertRaises(self.mas.Failure):
                self.info(arch)

    def test_local_build_label_is_rejected_instead_of_mislabeling_a_store_build(self):
        for arch in MINIMUMS:
            with self.subTest(arch=arch), self.assertRaises(self.mas.Failure):
                self.environment(arch, {self.prefix + "_BUILD_LABEL": "fixture-local"})


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__, add_help=False)
    parser.add_argument("--repository", type=Path)
    parser.add_argument("--helper", type=Path)
    options, unittest_arguments = parser.parse_known_args()
    if options.repository is not None:
        REPOSITORY = options.repository.resolve()
    HELPER = (options.helper.resolve() if options.helper is not None else REPOSITORY / "packaging" / "macos" / "mas_package.py")
    unittest.main(argv=[sys.argv[0], *unittest_arguments])
