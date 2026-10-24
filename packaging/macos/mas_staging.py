"""Finite MAS legal staging and retained Print-model copy. No subprocess/network.

This module is imported by mas_package.py only after Root composes the reviewed
source changes. Import has no side effects. It never fetches or generates models.
"""
from pathlib import Path
import hashlib
import json
import os
import re
import stat
import tomllib


class StagingFailure(RuntimeError):
    pass


def _need(value, message):
    if not value:
        raise StagingFailure(message)


FONT_DEPENDENCY = {
    "name": "epaint_default_fonts", "version": "0.36.2",
    "source": "registry+https://github.com/rust-lang/crates.io-index",
    "checksum": "773fa9c96dd0dbef887e39d0ed6177f141cce4d68e6041df77570aa3702dfa13",
}
PHOTO_NOTICES = (
    ("assets/icons/LICENSE-noun-magnetic-lasso.txt", 20102, "667185ed8a375d40aff0d19f02ce880e786e355253b7c5adba2be7471b70c36a"),
    ("assets/icons/LICENSE-symmetry-axes.txt", 11525, "d43c48d168983b4d2a48e3d0d1b3c8f3ff662e8161da2d91d229b587f5e421ec"),
    ("crates/ui-egui/src/LICENSE-solarized.txt", 1302, "04268daec181d192ff99530d1af65cb30bfc6a315e1567332a14892a5b3c4c56"),
)
FONT_NOTICES = (
    ("Hack-Regular.txt", 3734, "47c0cccbeec7e8614548cc485588b28149e7874188df5f41b36efebcee285c87"),
    ("OFL.txt", 4301, "6a73f9541c2de74158c0e7cf6b0a58ef774f5a780bf191f2d7ec9cc53efe2bf2"),
    ("UFL.txt", 4673, "2f0015108d68627bd788d313f529c21ff4da2c2c42a5e1f3883acc83480f9002"),
    ("emoji-icon-font-mit-license.txt", 1069, "b9d2c1d909aa149996fd4c91dcb92b2362a04431640c1d200959da94caf8cde1"),
)
WINIT_LICENSE = (11323, "6dc0e068dcf3a5bc8e054205b85b7720e1d49265bbc64bf515d2cf79197df69a")
PRINT_MODEL_NAMES = frozenset((
    "text-detection.rten", "text-recognition.rten",
    "text-detection.rten.LICENCE.txt", "text-recognition.rten.LICENCE.txt",
    "ATTRIBUTION.txt",
))
PRINT_MODEL_SHA256 = {
    "text-detection.rten": "f15cfb56bd02c4bf478a20343986504a1f01e1665c2b3a0ad66340f054b1b5ca",
    "text-recognition.rten": "e484866d4cce403175bd8d00b128feb08ab42e208de30e42cd9889d8f1735a6e",
    "text-detection.rten.LICENCE.txt": "28a9529c7d0bb4dc51f4bf5c116a3d16ef247a052f7591466768ddf563fd1cf5",
    "text-recognition.rten.LICENCE.txt": "28a9529c7d0bb4dc51f4bf5c116a3d16ef247a052f7591466768ddf563fd1cf5",
}


def _relative(value):
    _need(isinstance(value, str) and value and "\\" not in value
          and not Path(value).is_absolute() and all(x not in ("", ".", "..") for x in value.split("/"))
          and all(ord(x) >= 32 for x in value), "Unsafe staged relative path")
    return Path(value)


def _directory(path):
    path = Path(path)
    _need(path.is_absolute(), "Absolute owned directory required")
    for part in (path, *path.parents):
        st = part.lstat()
        _need(stat.S_ISDIR(st.st_mode) and not stat.S_ISLNK(st.st_mode), "Directory or ancestor is not ordinary")
    return path


def _proof(path, maximum=512 * 1024 * 1024):
    path = Path(path); before = path.lstat()
    _need(stat.S_ISREG(before.st_mode) and not stat.S_ISLNK(before.st_mode)
          and 0 < before.st_size <= maximum, "Nonempty bounded ordinary input file required")
    digest = hashlib.sha256()
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        opened = os.fstat(fd)
        _need((opened.st_dev, opened.st_ino, opened.st_size, opened.st_mtime_ns) ==
              (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns), "Input changed before open")
        with os.fdopen(fd, "rb", closefd=False) as f:
            for block in iter(lambda: f.read(1024 * 1024), b""):
                digest.update(block)
        after = os.fstat(fd)
    finally:
        os.close(fd)
    ended = path.lstat()
    _need((before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_mode) ==
          (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_mode) ==
          (ended.st_dev, ended.st_ino, ended.st_size, ended.st_mtime_ns, ended.st_mode), "Input changed while hashing")
    return {"path": str(path), "bytes": before.st_size, "sha256": digest.hexdigest()}


def _copy_new(source, destination, expected):
    source = Path(source); destination = Path(destination)
    _directory(source.parent)
    before = _proof(source)
    _need(before["bytes"] == expected["bytes"] and before["sha256"] == expected["sha256"], "Source differs from approved byte proof")
    destination.parent.mkdir(parents=True, exist_ok=True)
    _directory(destination.parent)
    source_fd = os.open(source, os.O_RDONLY | os.O_NOFOLLOW)
    target_fd = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o644)
    try:
        with os.fdopen(source_fd, "rb", closefd=False) as src, os.fdopen(target_fd, "wb", closefd=False) as dst:
            for block in iter(lambda: src.read(1024 * 1024), b""):
                dst.write(block)
            dst.flush()
        os.fchmod(target_fd, 0o644)
    finally:
        os.close(source_fd); os.close(target_fd)
    copied = _proof(destination)
    _need(copied["bytes"] == before["bytes"] and copied["sha256"] == before["sha256"]
          and _proof(source) == before and stat.S_IMODE(destination.stat().st_mode) == 0o644,
          "Staged copy or retained source changed")
    return copied


def copy_additional_legal(root, resources, original_legal_files):
    root = _directory(Path(root).absolute()); resources = _directory(Path(resources).absolute())
    _need(resources.name == "Resources" and resources.parent.name == "Contents", "Exact new application resource seam required")
    _need(type(original_legal_files) is list and len(set(original_legal_files)) == len(original_legal_files), "Original legal list must be unique")
    app = root.name.removeprefix("mixel-")
    _need(app in {"photo", "vector", "film", "light", "print", "effects", "design"}, "Known app root required")
    planned = []
    if app == "photo":
        planned.extend((root / relative, relative, "repository/" + relative, {"bytes": size, "sha256": sha})
                       for relative, size, sha in PHOTO_NOTICES)
    lock_path = root / "Cargo.lock"
    lock_before = _proof(lock_path, 2_000_000)
    lock = tomllib.loads(lock_path.read_text(encoding="utf-8"))
    members = [row for row in lock["package"] if row.get("name") == "epaint_default_fonts"]
    _need(len(members) <= 1, "Unique epaint_default_fonts dependency required")
    if members:
        _need({key: members[0].get(key) for key in FONT_DEPENDENCY} == FONT_DEPENDENCY,
              "Unreviewed embedded font dependency refused")
        for name, size, sha in FONT_NOTICES:
            logical = "external-epaint-default-fonts-0.36.2/fonts/" + name
            planned.append((root / "packaging/licenses/epaint_default_fonts-0.36.2" / name,
                            logical, logical, {"bytes": size, "sha256": sha}))
    winit_relative = "vendor/winit" if app == "print" else "mixel/vendor/winit"
    winit_root = root / winit_relative
    license_path = winit_root / "LICENSE"; patch_path = winit_root / "MIXEL-PATCH.md"
    _need(_proof(license_path, 256_000)["sha256"] == WINIT_LICENSE[1], "Exact preserved winit Apache licence required")
    patch_proof = _proof(patch_path, 256_000)
    for name, expected in (("LICENSE", {"bytes": WINIT_LICENSE[0], "sha256": WINIT_LICENSE[1]}),
                           ("MIXEL-PATCH.md", patch_proof)):
        relative = winit_relative + "/" + name
        planned.append((winit_root / name, relative, "repository/" + relative, expected))
    names = [logical for _, logical, _, _ in planned]
    _need(len(names) == len(set(names)) and not set(names).intersection(original_legal_files), "Additional notices must not overwrite existing legal files")
    for source, _, relative, expected in planned:
        _copy_new(source, resources / "Licenses" / _relative(relative), expected)
    _need(_proof(lock_path, 2_000_000) == lock_before, "Cargo.lock changed during legal staging")
    return names


def stage_retained_print_models(destination, env):
    """Copy the exact accepted Print2 model payload; no model helper fallback."""
    source_value = env.get("MACOS_MAS_PRINT_MODELS_DIR", "")
    provenance_value = env.get("MACOS_MAS_PRINT_MODELS_PROVENANCE", "")
    expected_sha = env.get("MACOS_MAS_PRINT_MODELS_PROVENANCE_SHA256", "")
    _need(source_value and provenance_value and re.fullmatch(r"[0-9a-f]{64}", expected_sha),
          "Explicit retained Print model root and independently recorded provenance SHA256 required")
    source = _directory(Path(source_value).expanduser().absolute())
    _need(source.name == "models" and source.parent.name == "Resources" and source.parent.parent.name == "Contents"
          and source.parent.parent.parent.name == "MIXEL Print.app", "Retained accepted Print app models directory required")
    provenance_path = Path(provenance_value).expanduser().absolute()
    proof = _proof(provenance_path, 4_000_000)
    _need(proof["sha256"] == expected_sha, "Accepted model package provenance SHA256 differs")
    provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
    _need(provenance.get("schema") == "mixel.mas-package.v1" and provenance.get("app") == "print"
          and provenance.get("version") == "0.7.1" and provenance.get("buildNumber") == "2"
          and provenance.get("arch") == "aarch64", "Exact accepted Oct22 Print2 model source required")
    rows = []
    prefix = "Contents/Resources/models/"
    for row in provenance.get("signedAppFiles", []):
        name = row.get("path")
        if isinstance(name, str) and name.startswith(prefix):
            relative = name[len(prefix):]; _relative(relative)
            _need(type(row.get("bytes")) is int and row["bytes"] > 0 and row.get("mode") == 0o644
                  and isinstance(row.get("sha256"), str) and re.fullmatch(r"[0-9a-f]{64}", row["sha256"]),
                  "Exact accepted ordinary model-file proof required")
            rows.append({"path": relative, "bytes": row["bytes"], "sha256": row["sha256"], "mode": 0o644})
    names = [row["path"] for row in rows]
    _need(len(names) == 5 and len(names) == len(set(names)) and set(names) == PRINT_MODEL_NAMES,
          "Exact five-file accepted RTEN model payload required")
    for row in rows:
        if row["path"] in PRINT_MODEL_SHA256:
            _need(row["sha256"] == PRINT_MODEL_SHA256[row["path"]],
                  "Accepted model or licence pin differs from the attributed Print source")
    actual = []
    for base, directories, files in os.walk(source, followlinks=False):
        _directory(Path(base))
        for name in directories: _directory(Path(base) / name)
        for name in files:
            path = Path(base) / name
            mode = path.lstat().st_mode
            _need(stat.S_ISREG(mode) and stat.S_IMODE(mode) == 0o644, "Special or non-0644 retained model entry refused")
            actual.append(path.relative_to(source).as_posix())
    _need(set(actual) == set(names), "Retained model file membership differs from accepted provenance")
    destination = Path(destination).absolute()
    _directory(destination.parent)
    destination.mkdir(mode=0o755, exist_ok=False)
    copied = []
    for row in sorted(rows, key=lambda row: row["path"]):
        relative = _relative(row["path"])
        copied.append(_copy_new(source / relative, destination / relative, row))
    _need(_proof(provenance_path, 4_000_000) == proof, "Accepted provenance changed during retained model copy")
    return {"sourceProvenance": proof, "sourceModels": str(source), "reusedFiles": rows,
            "stagedFiles": copied, "modelHelperInvoked": False, "downloadsPerformed": False}
