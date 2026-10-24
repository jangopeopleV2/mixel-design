#!/usr/bin/env python3
"""Pure synthetic Mach-O regressions. No compiler, signer, Apple request or app launch.

Run by ROOT after review: python3 -B test_mas_private_api.py --helper /path/to/mas_package.py
All binaries, bundles, receipts and native responses below are disposable fakes.
"""
from __future__ import annotations

import argparse
from pathlib import Path
import shutil
import struct
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
HELPER = Path(__file__).with_name("mas_package.py")


def load_helper(path):
    module = types.ModuleType("mas_private_api_under_test")
    module.__file__ = str(path)
    exec(compile(path.read_bytes(), str(path), "exec"), module.__dict__)
    return module


def thin(symbols=(), payload=b"", *, bits=64, order="<", cpu=None, subtype=0):
    """A real header/LC_SYMTAB/nlist/string-table layout, without machine code."""
    cpu = (0x0100000C if bits == 64 else 7) if cpu is None else cpu
    strings, indexes = b"\0", []
    for symbol in symbols:
        indexes.append(len(strings))
        strings += symbol + b"\0"
    entries = b"".join(struct.pack(order + ("IBBHQ" if bits == 64 else "IBBHI"),
                                   index, 1, 0, 0, 0) for index in indexes)
    header_size = 32 if bits == 64 else 28
    symbol_offset = header_size + 24
    string_offset = symbol_offset + len(entries)
    header = struct.pack(order + "IiiIIII", 0xFEEDFACF if bits == 64 else 0xFEEDFACE,
                         cpu, subtype, 2, 1, 24, 0)
    if bits == 64:
        header += struct.pack(order + "I", 0)
    command = struct.pack(order + "IIIIII", 2, 24, symbol_offset, len(indexes),
                          string_offset, len(strings))
    return header + command + entries + strings + payload


def fat(members, *, bits=32, order=">"):
    table_size = 8 + len(members) * (32 if bits == 64 else 20)
    cursor = (table_size + 15) & ~15
    entries, chunks = [], []
    for member in members:
        byteorder = "little" if member[:4] in (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe") else "big"
        cpu = int.from_bytes(member[4:8], byteorder)
        subtype = int.from_bytes(member[8:12], byteorder)
        if bits == 64:
            entries.append(struct.pack(order + "IIQQII", cpu, subtype, cursor, len(member), 4, 0))
        else:
            entries.append(struct.pack(order + "IIIII", cpu, subtype, cursor, len(member), 4))
        chunks.append((cursor, member))
        cursor = (cursor + len(member) + 15) & ~15
    result = bytearray(struct.pack(order + "II", 0xCAFEBABF if bits == 64 else 0xCAFEBABE,
                                   len(members)) + b"".join(entries))
    for offset, member in chunks:
        result.extend(b"\0" * (offset - len(result)))
        result.extend(member)
    return bytes(result)


class PrivateApiTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.mas = load_helper(HELPER)

    def setUp(self):
        # Unexpected native or Git boundaries are test failures, never real work.
        for name in ("run", "Popen"):
            trap = patch.object(self.mas.subprocess, name, side_effect=AssertionError("No external process"))
            trap.start()
            self.addCleanup(trap.stop)
        temporary = tempfile.TemporaryDirectory(prefix="mixel-private-api-fake-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)

    def scan(self, value, required=True):
        return self.mas.scan_macho_private_api(lambda offset, count: value[offset:offset + count],
                                              len(value), "synthetic Mach-O", required=required)

    def test_public_symbols_pass_in_all_four_thin_encodings(self):
        for bits in (32, 64):
            for order in ("<", ">"):
                with self.subTest(bits=bits, order=order):
                    result = self.scan(thin((b"_NSApplicationMain",), bits=bits, order=order))
                    self.assertEqual(len(result), 1)
                    self.assertEqual(result[0]["bits"], bits)

    def test_both_forbidden_imports_fail_in_every_thin_encoding(self):
        for symbol in self.mas.PRIVATE_API_SYMBOLS:
            for bits in (32, 64):
                for order in ("<", ">"):
                    with self.subTest(symbol=symbol, bits=bits, order=order):
                        with self.assertRaisesRegex(self.mas.Failure, symbol.decode()):
                            self.scan(thin((b"_" + symbol,), bits=bits, order=order))

    def test_bare_runtime_lookup_strings_are_also_rejected(self):
        for symbol in self.mas.PRIVATE_API_SYMBOLS:
            with self.subTest(symbol=symbol), self.assertRaisesRegex(self.mas.Failure, symbol.decode()):
                self.scan(thin(payload=b"\0" + symbol + b"\0"))

    def test_nearby_longer_identifiers_are_not_false_positive_symbols(self):
        for symbol in self.mas.PRIVATE_API_SYMBOLS:
            for value in (b"_Other" + symbol, b"_" + symbol + b"Alternative", b"prefix" + symbol):
                with self.subTest(value=value):
                    self.assertEqual(len(self.scan(thin((value,)))), 1)

    def test_all_fat_encodings_accept_two_public_architectures(self):
        members = (thin((b"_NSApplicationMain",)), thin((b"_NSApplicationMain",), cpu=0x01000007))
        for bits in (32, 64):
            for order in ("<", ">"):
                with self.subTest(bits=bits, order=order):
                    self.assertEqual(len(self.scan(fat(members, bits=bits, order=order))), 2)

    def test_private_symbol_in_either_fat_slice_fails(self):
        for index in (0, 1):
            for bits in (32, 64):
                members = [thin(cpu=0x0100000C), thin(cpu=0x01000007)]
                members[index] = thin((b"_CGSMainConnectionID",), cpu=(0x0100000C, 0x01000007)[index])
                with self.subTest(index=index, bits=bits), self.assertRaisesRegex(self.mas.Failure, "CGSMainConnectionID"):
                    self.scan(fat(members, bits=bits))

    def test_symbol_across_one_megabyte_scan_boundary_fails(self):
        header_length = len(thin())
        for symbol in self.mas.PRIVATE_API_SYMBOLS:
            padding = b"\0" * (1024 * 1024 - header_length - len(symbol) // 2)
            with self.subTest(symbol=symbol), self.assertRaisesRegex(self.mas.Failure, symbol.decode()):
                self.scan(thin(payload=padding + b"_" + symbol + b"\0"))

    def test_identifier_continuing_at_chunk_boundary_is_allowed(self):
        symbol = b"_CGSMainConnectionID"
        padding = b"\0" * (1024 * 1024 - len(thin()) - len(symbol))
        self.assertEqual(len(self.scan(thin(payload=padding + symbol + b"Alternative\0"))), 1)

    def test_non_macho_resource_is_ignored_but_not_accepted_as_binary(self):
        value = b"Documentation says CGSMainConnectionID is forbidden."
        self.assertEqual(self.scan(value, required=False), [])
        with self.assertRaises(self.mas.Failure):
            self.scan(value)

    def test_truncated_thin_and_fat_headers_fail_closed(self):
        for value in (b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xce\0", b"\xca\xfe\xba\xbe"):
            with self.subTest(value=value), self.assertRaises(self.mas.Failure):
                self.scan(value, required=False)

    def test_invalid_fat_count_and_out_of_file_slice_fail(self):
        cases = [struct.pack(">II", 0xCAFEBABE, 0), struct.pack(">II", 0xCAFEBABE, 65)]
        value = bytearray(fat((thin(),)))
        value[16:20] = struct.pack(">I", len(value) + 16)
        cases.append(bytes(value))
        for value in cases:
            with self.subTest(length=len(value)), self.assertRaises(self.mas.Failure):
                self.scan(value)

    def test_overlapping_or_duplicate_fat_slices_fail(self):
        value = bytearray(fat((thin(), thin(cpu=0x01000007))))
        value[36:44] = value[16:24]
        with self.assertRaises(self.mas.Failure):
            self.scan(bytes(value))
        with self.assertRaises(self.mas.Failure):
            self.scan(fat((thin(), thin())))

    def test_fat_cpu_mismatch_and_nested_fat_fail(self):
        value = bytearray(fat((thin(),)))
        value[8:12] = struct.pack(">I", 0x01000007)
        with self.assertRaises(self.mas.Failure):
            self.scan(bytes(value))
        value = bytearray(fat((thin(),)))
        offset = struct.unpack(">I", value[16:20])[0]
        value[offset:offset + 4] = b"\xca\xfe\xba\xbe"
        with self.assertRaises(self.mas.Failure):
            self.scan(bytes(value))

    def test_fat_alignment_and_reserved_fields_fail(self):
        value = bytearray(fat((thin(),), bits=64))
        value[32:36] = struct.pack(">I", 64)
        with self.assertRaises(self.mas.Failure):
            self.scan(bytes(value))
        value = bytearray(fat((thin(),), bits=64))
        value[36:40] = struct.pack(">I", 1)
        with self.assertRaises(self.mas.Failure):
            self.scan(bytes(value))

    def test_truncated_or_invalid_load_commands_fail(self):
        for command_size in (0, 7, 25, 1024):
            value = bytearray(thin())
            value[36:40] = struct.pack("<I", command_size)
            with self.subTest(command_size=command_size), self.assertRaises(self.mas.Failure):
                self.scan(bytes(value))
        value = bytearray(thin())
        value[20:24] = struct.pack("<I", len(value) + 100)
        with self.assertRaises(self.mas.Failure):
            self.scan(bytes(value))

    def test_required_file_reader_accepts_compiler_hardlinks(self):
        binary = self.root / "binary"
        binary.write_bytes(thin((b"_NSApplicationMain",)))
        alias = self.root / "compiler-linked-binary"
        import os
        os.link(binary, alias)
        self.assertEqual(len(self.mas.verify_macho_private_api(binary)), 1)

    def test_file_reader_rejects_symlink_and_changed_binary(self):
        binary = self.root / "binary"
        binary.write_bytes(thin())
        alias = self.root / "alias"
        alias.symlink_to(binary)
        with self.assertRaises(self.mas.Failure):
            self.mas.verify_macho_private_api(alias)
        original = self.mas.os.pread
        changed = False
        def mutate(descriptor, count, offset):
            nonlocal changed
            result = original(descriptor, count, offset)
            if not changed:
                changed = True
                binary.write_bytes(binary.read_bytes() + b"\0")
            return result
        with patch.object(self.mas.os, "pread", side_effect=mutate), self.assertRaises(self.mas.Failure):
            self.mas.verify_macho_private_api(binary)

    def test_nested_extension_with_private_import_fails_app_gate(self):
        app = self.root / "Fixture.app"
        (app / "Contents/MacOS").mkdir(parents=True)
        (app / "Contents/MacOS/Fixture").write_bytes(thin())
        nested = app / "Contents/PlugIns/Nested.appex/Contents/MacOS/extension"
        nested.parent.mkdir(parents=True)
        nested.write_bytes(thin((b"_CGSSetWindowBackgroundBlurRadius",)))
        with self.assertRaisesRegex(self.mas.Failure, "CGSSetWindowBackgroundBlurRadius"):
            self.mas.verify_app_private_api(app)

    def test_app_scans_non_executable_named_macho_and_ignores_text(self):
        app = self.root / "Fixture.app"
        app.mkdir()
        (app / "payload.dat").write_bytes(thin())
        (app / "NOTICE").write_bytes(b"CGSMainConnectionID is rejected by policy.\n")
        result = self.mas.verify_app_private_api(app)
        self.assertEqual([item["path"] for item in result], ["payload.dat"])

    def test_app_rejects_symlink_and_missing_macho(self):
        app = self.root / "Fixture.app"
        app.mkdir()
        (app / "NOTICE").write_text("Only a notice")
        with self.assertRaises(self.mas.Failure):
            self.mas.verify_app_private_api(app)
        (app / "NOTICE").unlink()
        (app / "link").symlink_to(self.root)
        with self.assertRaises(self.mas.Failure):
            self.mas.verify_app_private_api(app)

    def package_fixture(self, poison_stage=False, poison_expansion=False):
        """Exercise production package() with fake boundaries, never a subprocess."""
        import datetime as dt
        config = self.mas.CONFIG["mixel-photo"]
        root = self.root / "mixel-photo"
        (root / "assets/app-icon").mkdir(parents=True)
        (root / "assets/app-icon/photocraft.icns").write_bytes(b"fake icon")
        here = root / "packaging/macos"
        here.mkdir(parents=True)
        target = self.root / "target-isolated"
        binary = self.root / "built-binary"
        binary.write_bytes(thin())
        receipt_path = self.root / "build-receipt.json"
        receipt_path.write_text("{}")
        profile, privacy = self.root / "profile", self.root / "privacy"
        profile.write_bytes(b"fake profile")
        privacy.write_bytes(b"fake privacy")
        receipt = {"binaries": [{"file": {"path": str(binary)}}], "sourceCommit": "a" * 40,
                   "source": {"sha256": "fixture-source"}, "externalFonts": None}
        signing = {"policy": {"expiresAtUtc": (dt.datetime.now(dt.timezone.utc) + dt.timedelta(days=1)).isoformat()},
                   "identity": "A" * 40, "installer": "3rd Party Mac Developer Installer: Fixture",
                   "profilePath": profile, "profileProof": self.mas.file_proof(profile),
                   "metadataProof": {"path": "not-read"}}
        commands = []
        self.package_commands = commands
        staged_app = None
        def fake_run(argv, **kwargs):
            nonlocal staged_app
            commands.append(list(argv))
            if argv[0] == self.mas.TOOLS["lipo"]:
                executable = Path(argv[argv.index("-output") + 1])
                executable.write_bytes(thin((b"_CGSMainConnectionID",) if poison_stage else ()))
                staged_app = executable.parents[2]
            elif argv[0] == self.mas.TOOLS["productbuild"]:
                Path(argv[-1]).write_bytes(b"fake package")
            elif argv[0] == self.mas.TOOLS["pkgutil"] and "--expand-full" in argv:
                destination = Path(argv[-1])
                destination.mkdir()
                shutil.copytree(staged_app, destination / staged_app.name)
                if poison_expansion:
                    extra = destination / staged_app.name / "Contents/Resources/hidden-binary"
                    extra.write_bytes(thin((b"_CGSSetWindowBackgroundBlurRadius",)))
            return b""
        def fake_subprocess(argv, **kwargs):
            self.assertEqual(argv[:2], [self.mas.TOOLS["pkgutil"], "--check-signature"])
            return types.SimpleNamespace(returncode=0, stdout=signing["installer"].encode(), stderr=b"")
        originals = {"build_environment": ({"PHOTOCRAFT_BUILD_SHA": "a" * 40}, target),
                     "load_version": "1.2.3", "distribution_inputs": signing,
                     "load_privacy": (privacy, self.mas.file_proof(privacy)),
                     "checked_build_receipt": receipt, "copy_legal": ["LICENSE"],
                     "generated_info": {}, "desired_entitlements": {},
                     "source_catalogue": receipt["source"], "external_fonts": None,
                     "command_text": "arm64", "verify_app": None}
        guards = []
        for name, value in originals.items():
            guard = patch.object(self.mas, name, return_value=value)
            guard.start()
            guards.append(guard)
        self.addCleanup(lambda: [guard.stop() for guard in reversed(guards)])
        real_tree = self.mas.tree_proof
        # A changed expanded tree is also rejected by the original byte-equality
        # guard. Keep that guard real in both clean and poisoned-stage controls.
        if poison_expansion:
            tree_guard = patch.object(self.mas, "tree_proof", side_effect=lambda app: [
                row for row in real_tree(app) if row["path"] != "Contents/Resources/hidden-binary"])
            tree_guard.start()
            self.addCleanup(tree_guard.stop)
        with patch.object(self.mas, "run", side_effect=fake_run), \
             patch.object(self.mas.subprocess, "run", side_effect=fake_subprocess):
            args = types.SimpleNamespace(arch="aarch64", skip_build=True, build_only=False)
            env = {"MACOS_MAS_BUILD_NUMBER": "17", "MACOS_MAS_USES_NONEXEMPT_ENCRYPTION": "false",
                   "MACOS_MAS_BUILD_RECEIPT": str(receipt_path),
                   "MACOS_MAS_BUILD_RECEIPT_SHA256": "a" * 64,
                   "MACOS_MAS_DIST": str(self.root / "dist")}
            self.mas.package(root, config, args, env)
        return commands

    def test_staged_private_api_prevents_any_codesign_or_productbuild(self):
        with self.assertRaisesRegex(self.mas.Failure, "CGSMainConnectionID"):
            self.package_fixture(poison_stage=True)
        self.assertFalse(any(argv[0] in (self.mas.TOOLS["codesign"], self.mas.TOOLS["productbuild"])
                             for argv in self.package_commands))
        self.assertFalse((self.root / "dist").exists())

    def test_clean_package_preserves_original_native_sequence(self):
        commands = self.package_fixture()
        self.assertEqual(sum(argv[0] == self.mas.TOOLS["codesign"] for argv in commands), 2)
        self.assertEqual(sum(argv[0] == self.mas.TOOLS["productbuild"] for argv in commands), 1)
        self.assertEqual(len(list((self.root / "dist").glob("*.pkg"))), 1)

    def test_expanded_nested_private_api_prevents_final_package_copy(self):
        with self.assertRaisesRegex(self.mas.Failure, "CGSSetWindowBackgroundBlurRadius"):
            self.package_fixture(poison_expansion=True)
        self.assertFalse((self.root / "dist").exists())


if __name__ == "__main__":
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--helper", type=Path)
    options, remaining = parser.parse_known_args()
    if options.helper is not None:
        HELPER = options.helper.resolve()
    unittest.main(argv=[sys.argv[0], *remaining])
