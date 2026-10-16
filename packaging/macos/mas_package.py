#!/usr/bin/env python3
"""Build and package one MIXEL Mac App Store variant without contacting a store.

This file is intentionally identical in all seven repositories. Native tools are
executed only by the person/agent running this command, never during import.
"""

from __future__ import annotations

import argparse
import base64
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import uuid


TEAM = "5277F8NDH4"
CONFIG = {
    "mixel-photo": ("photo", "Photo", "photocraft", "PHOTOCRAFT", "PhotoCraft", True),
    "mixel-vector": ("vector", "Vector", "vectorcraft", "VECTORCRAFT", "VectorCraft", False),
    "mixel-film": ("film", "Film", "filmcraft", "FILMCRAFT", "FilmCraft", False),
    "mixel-print": ("print", "Print", "pdfcraft", "PDFCRAFT", "PdfCraft", False),
    "mixel-light": ("light", "Light", "lightcraft", "LIGHTCRAFT", "LightCraft", True),
    "mixel-effects": ("effects", "Effects", "effectcraft", "EFFECTCRAFT", "EffectCraft", False),
    "mixel-design": ("design", "Design", "designcraft", "DESIGNCRAFT", "DesignCraft", False),
}
TARGETS = {
    "aarch64": ("aarch64-apple-darwin",),
    "x86_64": ("x86_64-apple-darwin",),
    "universal": ("aarch64-apple-darwin", "x86_64-apple-darwin"),
}
TOOLS = {
    "security": "/usr/bin/security",
    "codesign": "/usr/bin/codesign",
    "productbuild": "/usr/bin/productbuild",
    "pkgutil": "/usr/sbin/pkgutil",
    "lipo": "/usr/bin/lipo",
    "plutil": "/usr/bin/plutil",
}


class Failure(Exception):
    """An actionable, non-secret packaging failure."""


def require(condition, message):
    if not condition:
        raise Failure(message)


def utc_now():
    return dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def write_json(path, value):
    with path.open("x", encoding="utf-8") as stream:
        json.dump(value, stream, indent=2, sort_keys=True)
        stream.write("\n")


def digest(data):
    return hashlib.sha256(data).hexdigest()


def file_proof(path):
    path = Path(path)
    require(not path.is_symlink() and path.is_file(), f"Expected a regular, non-symlink file: {path}")
    before = path.stat()
    hasher = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            hasher.update(chunk)
    after = path.stat()
    fields = ("st_dev", "st_ino", "st_size", "st_mtime_ns", "st_ctime_ns", "st_mode")
    require(all(getattr(before, field) == getattr(after, field) for field in fields), f"File changed while hashing: {path}")
    return {"path": str(path.resolve()), "sha256": hasher.hexdigest(), "bytes": before.st_size}


def run(argv, *, env=None, cwd=None, log=None):
    """Never echo command arguments: profile paths and tool output may be private."""
    try:
        result = subprocess.run(argv, cwd=cwd, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    except OSError as error:
        raise Failure(f"Cannot execute {Path(argv[0]).name}: {error.strerror}") from error
    if log is not None:
        with log.open("xb") as stream:
            stream.write(result.stdout)
            stream.write(result.stderr)
    require(result.returncode == 0, f"{Path(argv[0]).name} failed (exit {result.returncode}); inspect the private run log")
    return result.stdout


def command_text(argv, **kwargs):
    try:
        return run(argv, **kwargs).decode("utf-8")
    except UnicodeDecodeError as error:
        raise Failure(f"{Path(argv[0]).name} returned non-UTF-8 text") from error


def required(env, key):
    value = env.get(key, "")
    require(bool(value) and not any(char in value for char in "\n\r\0"), f"Set {key} explicitly")
    return value


def boolean_input(env, key):
    value = required(env, key)
    require(value in ("true", "false"), f"{key} must be exactly true or false after per-app review")
    return value == "true"


def build_number(env):
    value = required(env, "MACOS_MAS_BUILD_NUMBER")
    require(re.fullmatch(r"[1-9][0-9]{0,17}", value) is not None, "MACOS_MAS_BUILD_NUMBER must be a positive decimal integer (at most 18 digits)")
    return value


def source_catalogue(root):
    raw = run(["git", "-C", str(root), "ls-files", "--cached", "--others", "--exclude-standard", "-z"])
    names = sorted(set(raw.split(b"\0")) - {b""})
    records = []
    for raw_name in names:
        name = os.fsdecode(raw_name)
        path = root / name
        require(not Path(name).is_absolute() and ".." not in Path(name).parts, "Unsafe source path returned by git")
        # Source symlinks are bound to both their literal target and the bytes.
        if path.is_symlink():
            resolved = path.resolve()
            require(resolved.is_relative_to(root) and resolved.is_file(), f"Source symlink escapes the checkout or is not a file: {name}")
            proof = file_proof(resolved)
            records.append({"path": name, "kind": "symlink", "target": os.readlink(path), "sha256": proof["sha256"], "bytes": proof["bytes"]})
        else:
            require(path.is_file(), f"A tracked source file is missing: {name}")
            proof = file_proof(path)
            records.append({"path": name, "kind": "file", "sha256": proof["sha256"], "bytes": proof["bytes"]})
    require(bool(records), "Empty source catalogue")
    body = json.dumps(records, sort_keys=True, separators=(",", ":")).encode()
    return {"sha256": digest(body), "files": records}


def external_fonts(env):
    value = env.get("CRAFT_FONTS_DIR", "")
    if not value:
        return None
    root = Path(value).expanduser().resolve()
    require(root.is_dir(), "CRAFT_FONTS_DIR is not a directory")
    entries = []
    for path in sorted(root.rglob("*")):
        if ".git" in path.relative_to(root).parts:
            continue
        require(not path.is_symlink(), "External font build inputs must not be symlinks")
        if path.is_file():
            proof = file_proof(path)
            entries.append({"path": str(path.relative_to(root)), "sha256": proof["sha256"], "bytes": proof["bytes"]})
    require(bool(entries), "CRAFT_FONTS_DIR has no files")
    return {"root": str(root), "files": entries, "sha256": digest(json.dumps(entries, sort_keys=True, separators=(",", ":")).encode())}


def deployment_minimum(arch):
    minimums = {"aarch64": "12.0", "x86_64": "11.0", "universal": "11.0"}
    require(arch in minimums, "Unsupported MAS architecture")
    return minimums[arch]


def build_environment(root, prefix, env, arch):
    result = dict(env)
    target = root / "target" / "macos-mas"
    requested = env.get("MACOS_MAS_TARGET_DIR")
    if requested:
        target = Path(requested).expanduser().resolve()
    target = target.resolve()
    require(target.name not in ("target", "release"), "MAS target must be a separate dedicated directory")
    require(not root.is_relative_to(target), "MAS target must not contain the checkout")
    require(not target.is_relative_to(root) or target.is_relative_to(root / "target" / "macos-mas"), "An in-checkout MAS target must stay under target/macos-mas")
    require("phase0" not in "/".join(target.parts).lower(), "MAS target must not use Phase 0 evidence directories")
    result["CARGO_TARGET_DIR"] = str(target)
    result["MACOSX_DEPLOYMENT_TARGET"] = deployment_minimum(arch)
    result[f"{prefix}_BUILD_SHA"] = command_text(["git", "-C", str(root), "rev-parse", "HEAD"]).strip()
    require(re.fullmatch(r"[0-9a-f]{40}", result[f"{prefix}_BUILD_SHA"]) is not None, "Invalid source commit")
    result[f"{prefix}_BUILD_DATE"] = dt.datetime.now(dt.timezone.utc).date().isoformat()
    # Release labels would misrepresent a workspace-version App Store build.
    require(not result.get(f"{prefix}_BUILD_LABEL"), "MAS builds cannot use a local build label")
    return result, target


def build_commands(crate, heif, arch, cargo):
    features = [f"{crate}/mac-app-store"]
    if heif:
        features.append(f"{crate}/heif")
    return [[cargo, "build", "--release", "--locked", "--package", crate, "--features", ",".join(features), "--target", target, "--message-format=json-render-diagnostics"] for target in TARGETS[arch]]


def captured_build_env(env, prefix):
    keys = ("CARGO_TARGET_DIR", "MACOSX_DEPLOYMENT_TARGET", "RUSTFLAGS", "CARGO_ENCODED_RUSTFLAGS", "CRAFT_FONTS_DIR", f"{prefix}_BUILD_SHA", f"{prefix}_BUILD_DATE")
    result = {key: env.get(key, "") for key in keys}
    for key in ("SDKROOT", "DEVELOPER_DIR", "RUSTUP_TOOLCHAIN", "RUSTC", "RUSTC_WRAPPER", "RUSTC_WORKSPACE_WRAPPER", "CARGO_BUILD_RUSTFLAGS", "CARGO_BUILD_TARGET"):
        if key in env:
            result[key] = env[key]
    for key in sorted(env):
        if re.fullmatch(r"CARGO_PROFILE_RELEASE_[A-Z0-9_]+|CARGO_TARGET_[A-Z0-9_]+_(?:RUSTFLAGS|LINKER)", key):
            result[key] = env[key]
    return result


def compiler_artifact(output, crate, heif, expected_executable):
    candidates = []
    for line in output.splitlines():
        try:
            message = json.loads(line)
        except (ValueError, UnicodeDecodeError) as error:
            raise Failure("Cargo did not return its requested JSON build transcript") from error
        require(isinstance(message, dict), "Cargo build transcript contains a non-object JSON value")
        if message.get("reason") != "compiler-artifact":
            continue
        target = message.get("target", {})
        if target.get("name") == crate and target.get("kind") == ["bin"] and message.get("executable"):
            candidates.append(message)
    require(len(candidates) == 1, "Cargo transcript does not identify exactly one intended desktop executable")
    artifact = candidates[0]
    features = artifact.get("features", [])
    require(isinstance(features, list) and "mac-app-store" in features and (not heif or "heif" in features), "Actual compiler artifact does not enable the required MAS/product features")
    require(Path(artifact["executable"]).resolve() == expected_executable.resolve(), "Compiler artifact points outside the dedicated MAS target")
    require(artifact.get("profile", {}).get("test") is False, "MAS artifact must be a production binary")
    return {"executable": str(expected_executable.resolve()), "targetName": crate, "features": sorted(features), "profile": artifact["profile"], "packageId": artifact.get("package_id"), "fresh": artifact.get("fresh")}


def load_version(root):
    # Read the exact workspace field without compiling xtask or honoring a product
    # VERSION override. Cargo files are UTF-8 and these versions are numeric.
    in_package = False
    for line in (root / "Cargo.toml").read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if stripped.startswith("["):
            in_package = stripped == "[workspace.package]"
        elif in_package:
            match = re.fullmatch(r'version\s*=\s*"([0-9]+\.[0-9]+\.[0-9]+)"\s*(?:#.*)?', stripped)
            if match:
                return match.group(1)
    raise Failure("A numeric X.Y.Z [workspace.package] version is required for MAS")


def create_build_receipt(root, config, arch, number, env, target, run_dir):
    slug, _, crate, prefix, _, heif = config
    before = source_catalogue(root)
    fonts = external_fonts(env)
    cargo = shutil.which("cargo", path=env.get("PATH"))
    require(cargo is not None, "cargo is not available")
    # rustup selects its Cargo proxy from argv[0]; resolving ~/.cargo/bin/cargo
    # to the rustup executable before invocation would change that command.
    cargo = str(Path(cargo).absolute())
    cargo_proof = {"invocationPath": cargo, "resolvedExecutable": file_proof(Path(cargo).resolve())}
    commands = build_commands(crate, heif, arch, cargo)
    executions = []
    for index, argv in enumerate(commands, 1):
        log = run_dir / f"cargo-{index}.log"
        started = utc_now()
        print(f"==> Building MIXEL {config[1]} MAS ({TARGETS[arch][index - 1]}); log: {log}", flush=True)
        output = run(argv, env=env, cwd=root, log=log)
        stdout_path = run_dir / f"cargo-{index}.stdout.jsonl"
        with stdout_path.open("xb") as stream:
            stream.write(output)
        artifact = compiler_artifact(output, crate, heif, target / TARGETS[arch][index - 1] / "release" / crate)
        executions.append({"argv": argv, "startedAtUtc": started, "finishedAtUtc": utc_now(), "exitCode": 0, "compilerArtifact": artifact, "stdout": file_proof(stdout_path), "log": file_proof(log)})
    after = source_catalogue(root)
    require(before == after, "Source changed during the MAS build; rebuild after edits finish")
    require(fonts == external_fonts(env), "External font inputs changed during the MAS build")
    binaries = []
    for triple in TARGETS[arch]:
        path = target / triple / "release" / crate
        require(os.access(path, os.X_OK), f"MAS build produced no executable for {triple}")
        binaries.append({"target": triple, "file": file_proof(path)})
    require(cargo_proof == {"invocationPath": cargo, "resolvedExecutable": file_proof(Path(cargo).resolve())}, "Cargo executable changed during the MAS build")
    receipt = {"schema": "mixel.mas-build.v1", "app": slug, "crate": crate, "arch": arch, "version": load_version(root), "buildNumber": number, "sourceCommit": env[f"{prefix}_BUILD_SHA"], "source": before, "externalFonts": fonts, "environment": captured_build_env(env, prefix), "helper": file_proof(Path(__file__).resolve()), "cargo": cargo_proof, "commands": executions, "binaries": binaries, "recordedAtUtc": utc_now()}
    path = run_dir / "build-receipt.json"
    write_json(path, receipt)
    return path, receipt


def checked_build_receipt(path, expected_sha, root, config, arch, number, env, target):
    require(re.fullmatch(r"[0-9a-fA-F]{64}", expected_sha or "") is not None, "Set MACOS_MAS_BUILD_RECEIPT_SHA256 to the independently recorded receipt SHA256")
    proof = file_proof(path)
    require(proof["sha256"] == expected_sha.lower(), "MAS build receipt SHA256 mismatch")
    try:
        receipt = json.loads(Path(path).read_text(encoding="utf-8"))
    except (ValueError, UnicodeDecodeError) as error:
        raise Failure("Invalid MAS build receipt JSON") from error
    require(isinstance(receipt, dict), "MAS build receipt must be a JSON object")
    slug, _, crate, prefix, _, heif = config
    require(receipt.get("schema") == "mixel.mas-build.v1" and receipt.get("app") == slug and receipt.get("crate") == crate, "Build receipt belongs to another app or schema")
    require(receipt.get("arch") == arch and receipt.get("version") == load_version(root) and receipt.get("buildNumber") == number, "Build receipt architecture/version/build mismatch")
    require(receipt.get("sourceCommit") == env[f"{prefix}_BUILD_SHA"] and receipt.get("source") == source_catalogue(root), "Source no longer matches the MAS build receipt")
    require(receipt.get("externalFonts") == external_fonts(env), "External fonts no longer match the MAS build receipt")
    current_env = captured_build_env(env, prefix)
    # A build may be packaged on a later UTC date. The original baked-in build
    # date is retained; all other controlled compilation inputs must match.
    require(isinstance(receipt.get("environment"), dict), "Missing MAS build environment")
    current_env[f"{prefix}_BUILD_DATE"] = receipt["environment"].get(f"{prefix}_BUILD_DATE", "")
    require(re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}", current_env[f"{prefix}_BUILD_DATE"]) is not None, "Invalid original build date")
    require(receipt.get("environment") == current_env, "Build environment no longer matches the MAS receipt")
    require(receipt.get("helper") == file_proof(Path(__file__).resolve()), "Build receipt was generated by another packaging helper")
    cargo = receipt.get("cargo", {}).get("invocationPath", "")
    require(bool(cargo) and receipt.get("cargo") == {"invocationPath": cargo, "resolvedExecutable": file_proof(Path(cargo).resolve())}, "Cargo executable changed after the MAS build")
    executions = receipt.get("commands", [])
    expected = build_commands(crate, heif, arch, cargo)
    require(isinstance(executions, list) and len(executions) == len(expected), "Incomplete MAS build commands")
    for index, (execution, argv) in enumerate(zip(executions, expected)):
        require(execution.get("argv") == argv and type(execution.get("exitCode")) is int and execution["exitCode"] == 0, "Receipt does not prove the required mac-app-store Cargo build")
        require(execution.get("log") == file_proof(Path(execution.get("log", {}).get("path", ""))), "MAS build transcript changed")
        stdout_path = Path(execution.get("stdout", {}).get("path", ""))
        require(execution.get("stdout") == file_proof(stdout_path), "MAS Cargo JSON transcript changed")
        artifact = compiler_artifact(stdout_path.read_bytes(), crate, heif, target / TARGETS[arch][index] / "release" / crate)
        require(execution.get("compilerArtifact") == artifact, "MAS compiler artifact receipt differs from the actual Cargo JSON transcript")
    binaries = [{"target": triple, "file": file_proof(target / triple / "release" / crate)} for triple in TARGETS[arch]]
    require(receipt.get("binaries") == binaries, "MAS executable no longer matches the trusted build receipt")
    require(proof == file_proof(path), "MAS build receipt changed while checking it")
    return receipt


def profile_policy(profile, metadata, cert_sha1, bundle, now):
    require(isinstance(profile, dict), "Invalid provisioning profile payload")
    require(profile.get("TeamIdentifier") == [TEAM], "Provisioning profile belongs to another team")
    require(profile.get("ApplicationIdentifierPrefix") == [TEAM], "Unexpected provisioning application prefix")
    platforms = profile.get("Platform", [])
    require(isinstance(platforms, list) and platforms and set(platforms).issubset({"OSX", "macOS"}), "Provisioning profile is not exclusively for macOS")
    expiry = profile.get("ExpirationDate")
    require(isinstance(expiry, dt.datetime), "Provisioning profile has no expiration date")
    if expiry.tzinfo is None:
        expiry = expiry.replace(tzinfo=dt.timezone.utc)
    require(expiry > now, "Provisioning profile has expired")
    creation = profile.get("CreationDate")
    require(isinstance(creation, dt.datetime), "Provisioning profile has no creation date")
    if creation.tzinfo is None:
        creation = creation.replace(tzinfo=dt.timezone.utc)
    require(creation <= now, "Provisioning profile is not valid yet")
    require(isinstance(metadata, dict), "API profile metadata must be a JSON object")
    record = metadata.get("data", metadata)
    require(isinstance(record, dict) and isinstance(record.get("attributes"), dict), "API profile metadata requires an attributes object")
    attrs = record["attributes"]
    require(attrs.get("profileType") == "MAC_APP_STORE", "API profile metadata must identify MAC_APP_STORE")
    require(isinstance(profile.get("UUID"), str) and attrs.get("uuid") == profile["UUID"], "API metadata UUID does not match the signed profile")
    require(attrs.get("profileState") == "ACTIVE", "API profile metadata must identify an ACTIVE profile")
    ent = profile.get("Entitlements", {})
    require(isinstance(ent, dict), "Profile entitlements must be a dictionary")
    require(ent.get("com.apple.application-identifier") == f"{TEAM}.{bundle}", "Profile application identifier is not the exact product ID")
    require(ent.get("com.apple.developer.team-identifier") == TEAM, "Profile entitlement team mismatch")
    # TN3125: App Sandbox and Hardened Runtime entitlements are unrestricted
    # on macOS. Their absence in an authentic MAC_APP_STORE profile is normal.
    # TestFlight requires the profile, not an invented iOS-style beta flag.
    for key in ("com.apple.security.app-sandbox", "beta-reports-active", "get-task-allow", "com.apple.security.get-task-allow"):
        require(key not in ent or type(ent[key]) is bool, f"Profile entitlement {key} must be a boolean when present")
    require(not profile.get("ProvisionedDevices"), "A device-specific development/ad-hoc profile is not a MAS distribution profile")
    require(ent.get("get-task-allow") is not True and ent.get("com.apple.security.get-task-allow") is not True, "A distribution profile must not allow debugging")
    certificates = profile.get("DeveloperCertificates", [])
    require(isinstance(certificates, list) and certificates and all(isinstance(cert, bytes) for cert in certificates), "Profile has no valid signing certificates")
    require(cert_sha1.lower() in {hashlib.sha1(cert).hexdigest() for cert in certificates}, "Selected distribution certificate is absent from the profile")
    return {"uuid": profile["UUID"], "expiresAtUtc": expiry.isoformat(), "profileType": "MAC_APP_STORE", "bundleIdentifier": bundle, "teamIdentifier": TEAM, "certificateSha1": cert_sha1.lower(), "profileSandbox": ent.get("com.apple.security.app-sandbox"), "betaReportsActive": ent.get("beta-reports-active")}


def distribution_inputs(root, env, config, work):
    team = required(env, "MACOS_MAS_TEAM_ID")
    require(team == TEAM, "MACOS_MAS_TEAM_ID must be 5277F8NDH4")
    identity = required(env, "MACOS_MAS_SIGN_IDENTITY")
    require(re.fullmatch(r"[0-9A-Fa-f]{40}", identity) is not None, "MACOS_MAS_SIGN_IDENTITY must be the distribution certificate SHA1 fingerprint; no ad-hoc fallback")
    installer = required(env, "MACOS_MAS_INSTALLER_IDENTITY")
    require(installer.startswith("3rd Party Mac Developer Installer: ") and installer.endswith(f"({TEAM})"), "Use the full 3rd Party Mac Developer Installer identity for the required team")
    profile_path = Path(required(env, "MACOS_MAS_PROVISIONING_PROFILE")).expanduser().absolute()
    require(not profile_path.resolve().is_relative_to(root), "Keep input provisioning profiles outside the source checkout")
    profile_proof = file_proof(profile_path)
    metadata_path = Path(required(env, "MACOS_MAS_PROFILE_METADATA")).expanduser().absolute()
    require(not metadata_path.resolve().is_relative_to(root), "Keep input provisioning API metadata outside the source checkout")
    metadata_proof = file_proof(metadata_path)
    try:
        metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
    except (ValueError, UnicodeDecodeError) as error:
        raise Failure("Invalid profile API metadata JSON") from error
    # Never persist the decoded profile or its certificate/account metadata in
    # logs. Only its checked policy and file digest enter the provenance record.
    decoded = run([TOOLS["security"], "cms", "-D", "-i", str(profile_path)])
    try:
        profile = plistlib.loads(decoded)
    except (ValueError, plistlib.InvalidFileException) as error:
        raise Failure("security cms did not decode a valid profile plist") from error
    policy = profile_policy(profile, metadata, identity, f"ch.mixel.{config[0]}", dt.datetime.now(dt.timezone.utc))
    profile_content = metadata.get("data", metadata).get("attributes", {}).get("profileContent")
    if profile_content is not None:
        try:
            original = base64.b64decode(profile_content, validate=True)
        except (ValueError, TypeError) as error:
            raise Failure("Invalid API profileContent") from error
        require(digest(original) == profile_proof["sha256"], "API profile content differs from the signed input profile")
    available = command_text([TOOLS["security"], "find-identity", "-v", "-p", "codesigning"])
    matches = re.findall(r'\b([0-9A-Fa-f]{40})\s+"([^"\r\n]+)"', available)
    names = sorted({name for fingerprint, name in matches if fingerprint.lower() == identity.lower()})
    require(len(names) == 1 and names[0].startswith(("Apple Distribution: ", "3rd Party Mac Developer Application: ")) and names[0].endswith(f"({TEAM})"), "Selected MAS distribution identity is not a valid local signing identity for the team")
    require(profile_proof == file_proof(profile_path) and metadata_proof == file_proof(metadata_path), "Profile inputs changed during validation")
    return {"identity": identity, "installer": installer, "profilePath": profile_path, "profileProof": profile_proof, "metadataProof": metadata_proof, "policy": policy}


def load_privacy(here, env):
    path = here / "mas-privacy.xcprivacy"
    proof = file_proof(path)
    approval = required(env, "MACOS_MAS_PRIVACY_APPROVAL_SHA256")
    require(re.fullmatch(r"[0-9a-fA-F]{64}", approval) is not None and approval.lower() == proof["sha256"], "Privacy manifest has not been explicitly reviewed at its current SHA256")
    value = plistlib.loads(path.read_bytes())
    require(isinstance(value, dict), "Privacy manifest must be a plist dictionary")
    require(type(value.get("NSPrivacyTracking")) is bool, "Privacy manifest must state tracking explicitly")
    for key in ("NSPrivacyTrackingDomains", "NSPrivacyCollectedDataTypes", "NSPrivacyAccessedAPITypes"):
        require(isinstance(value.get(key), list), f"Privacy manifest requires {key}")
    require(not value["NSPrivacyTracking"] and not value["NSPrivacyTrackingDomains"] and not value["NSPrivacyCollectedDataTypes"], "This packaging policy requires a separate review before adding tracking or collected data")
    for entry in value["NSPrivacyAccessedAPITypes"]:
        require(isinstance(entry, dict) and isinstance(entry.get("NSPrivacyAccessedAPIType"), str), "Malformed required-reason API entry")
        reasons = entry.get("NSPrivacyAccessedAPITypeReasons")
        require(isinstance(reasons, list) and reasons and all(isinstance(reason, str) and reason for reason in reasons), "Every required-reason API category needs reviewed reason strings")
    return path, proof


def desired_entitlements(here, slug, profile=None):
    value = plistlib.loads((here / "mas-entitlements.plist").read_bytes())
    expected = {"com.apple.security.app-sandbox": True, "com.apple.security.files.user-selected.read-write": True, "com.apple.security.files.bookmarks.app-scope": True, "com.apple.security.network.client": True}
    if slug in ("photo", "vector", "print"):
        expected["com.apple.security.print"] = True
    if slug == "film":
        expected["com.apple.security.device.audio-input"] = True
        expected["com.apple.security.device.microphone"] = True
    if slug == "light":
        expected["com.apple.security.automation.apple-events"] = True
        expected["com.apple.security.scripting-targets"] = {"com.apple.Photos": ["com.apple.Photos.import", "com.apple.Photos.library.read", "com.apple.Photos.library.read-write"]}
    require(value == expected, "MAS entitlement template differs from the reviewed least-privilege product policy")
    result = {**value, "com.apple.application-identifier": f"{TEAM}.ch.mixel.{slug}", "com.apple.developer.team-identifier": TEAM, "com.apple.security.get-task-allow": False}
    # Restricted claims may only come from the checked signed profile. macOS
    # App Store profiles commonly omit beta-reports-active entirely.
    if profile is not None and profile.get("betaReportsActive") is True:
        result["beta-reports-active"] = True
    return result


def generated_info(here, config, version, number, source_sha, encryption, arch):
    slug, title, _, _, brand, _ = config
    value = plistlib.loads((here / "Info.plist.in").read_bytes())
    substitutions = {"@VERSION@": version, "@SHORT_VERSION@": version, "@BUILD_SHA@": source_sha}
    def replace(item):
        if isinstance(item, dict):
            return {key: replace(child) for key, child in item.items()}
        if isinstance(item, list):
            return [replace(child) for child in item]
        if isinstance(item, str):
            return substitutions.get(item, item)
        return item
    value = replace(value)
    require(isinstance(value, dict), "Info.plist template must be a dictionary")
    require(value.get("CFBundleIdentifier") == f"ch.mixel.{slug}", "Info.plist product ID mismatch")
    require(value.get("CFBundleExecutable") == f"MIXEL {title}", "Info.plist executable name mismatch")
    require(bool(value.get("LSApplicationCategoryType")), "MAS category is missing")
    require(value.get("LSMinimumSystemVersion") == "11.0", "Unexpected deployment minimum")
    value["LSMinimumSystemVersion"] = deployment_minimum(arch)
    value["CFBundleShortVersionString"] = version
    value["CFBundleVersion"] = number
    value["ITSAppUsesNonExemptEncryption"] = encryption
    value[f"{brand}BuildCommit"] = source_sha
    if slug == "film":
        require(bool(value.get("NSMicrophoneUsageDescription")), "Film microphone access requires a purpose string")
    if slug == "light":
        require(bool(value.get("NSAppleEventsUsageDescription")), "Light Photos export requires its Apple Events purpose string")
    require("@VERSION@" not in repr(value) and "@SHORT_VERSION@" not in repr(value) and "@BUILD_SHA@" not in repr(value), "Unsubstituted Info.plist token")
    return value


def copy_legal(root, resources, env):
    destination = resources / "Licenses"
    destination.mkdir()
    copied = []
    candidates = [root / name for name in ("LICENSE", "LICENSE-MIT", "LICENSE-APACHE", "COPYRIGHT", "NOTICE", "ATTRIBUTION.md", "ASSETS.md", "assets/ATTRIBUTION.md")]
    for base in (root / "assets" / "fonts", root / "mixel" / "vendor" / "craft-fonts", root / "mixel" / "third-party"):
        if base.is_dir():
            candidates.extend(path for path in base.rglob("*") if path.is_file() and (path.name.lower().startswith(("ofl", "license", "licence", "copyright", "notice")) or path.name in ("ATTRIBUTION.md", "README.md")))
    for source in sorted(set(candidates)):
        if not source.is_file():
            continue
        original = file_proof(source)
        relative = source.relative_to(root)
        target = destination / "repository" / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
        require(file_proof(target)["sha256"] == original["sha256"] and file_proof(source) == original, "Staged legal notice differs from its source")
        copied.append(str(relative))
    if env.get("CRAFT_FONTS_DIR"):
        fonts = Path(env["CRAFT_FONTS_DIR"]).expanduser().resolve()
        for source in sorted(fonts.rglob("*")):
            if ".git" in source.relative_to(fonts).parts or not source.is_file():
                continue
            if not source.name.lower().startswith(("ofl", "license", "licence", "copyright", "notice")):
                continue
            original = file_proof(source)
            target = destination / "external-craft-fonts" / source.relative_to(fonts)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, target)
            require(file_proof(target)["sha256"] == original["sha256"] and file_proof(source) == original, "Staged external font license differs from its source")
            copied.append("external-craft-fonts/" + str(source.relative_to(fonts)))
    require(any(name.startswith("LICENSE") for name in copied), "No application source license was staged")
    return copied


def tree_proof(root):
    records = []
    for path in sorted(root.rglob("*")):
        require(not path.is_symlink(), "Unexpected symlink in staged app payload")
        if path.is_file():
            proof = file_proof(path)
            records.append({"path": str(path.relative_to(root)), "sha256": proof["sha256"], "bytes": proof["bytes"], "mode": stat.S_IMODE(path.stat().st_mode)})
    require(bool(records), "Empty app payload")
    return records


def verify_app(app, entitlement_value, cert_sha1, work, label):
    run([TOOLS["codesign"], "--verify", "--strict", "--deep", "--verbose=2", str(app)], log=work / f"{label}-codesign-verify.log")
    raw = run([TOOLS["codesign"], "--display", "--entitlements", "-", "--xml", str(app)], log=work / f"{label}-entitlements.log")
    actual = plistlib.loads(raw)
    require(actual == entitlement_value, "Actual code entitlements differ from the exact MAS policy")
    prefix = work / f"{label}-certificate-"
    run([TOOLS["codesign"], "--display", f"--extract-certificates={prefix}", str(app)], log=work / f"{label}-certificate.log")
    certificate = Path(str(prefix) + "0")
    file_proof(certificate)
    require(hashlib.sha1(certificate.read_bytes()).hexdigest() == cert_sha1.lower(), "Final app was signed by another certificate")
    detail_result = subprocess.run([TOOLS["codesign"], "--display", "--verbose=4", str(app)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    require(detail_result.returncode == 0, "Cannot inspect final app signing details")
    details = (detail_result.stdout + detail_result.stderr).decode("utf-8", errors="strict")
    (work / f"{label}-signature-details.log").write_text(details, encoding="utf-8")
    require(f"TeamIdentifier={TEAM}" in details.splitlines(), "Final code signature team mismatch")
    require(any(line.startswith(("Authority=Apple Distribution: ", "Authority=3rd Party Mac Developer Application: ")) for line in details.splitlines()), "Final app does not have a MAS distribution signature")


def package(root, config, args, env):
    slug, title, crate, prefix, _, _ = config
    here = root / "packaging" / "macos"
    number = build_number(env)
    version = load_version(root)
    build_env, target = build_environment(root, prefix, env, args.arch)
    target.mkdir(parents=True, exist_ok=True)
    runs = target / "mas-runs"
    runs.mkdir(exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix=f"build-{number}-{args.arch}-", dir=runs))
    os.chmod(work, 0o700)
    print(f"==> MAS run directory: {work}", flush=True)
    # Build-only never decodes profiles, reads signing identities or contacts Apple.
    signing = None
    privacy = None
    encryption = None
    if not args.build_only:
        encryption = boolean_input(env, "MACOS_MAS_USES_NONEXEMPT_ENCRYPTION")
        privacy = load_privacy(here, env)
        signing = distribution_inputs(root, env, config, work)
    if args.skip_build:
        path = Path(required(env, "MACOS_MAS_BUILD_RECEIPT")).expanduser().absolute()
        receipt = checked_build_receipt(path, required(env, "MACOS_MAS_BUILD_RECEIPT_SHA256"), root, config, args.arch, number, build_env, target)
    else:
        path, receipt = create_build_receipt(root, config, args.arch, number, build_env, target, work)
    receipt_proof = file_proof(path)
    print(f"MAS_BUILD_RECEIPT={path}\nMAS_BUILD_RECEIPT_SHA256={receipt_proof['sha256']}", flush=True)
    if args.build_only:
        print("==> MAS build and source/binary receipt verified; no signing or package created", flush=True)
        return
    require(signing is not None and privacy is not None and type(encryption) is bool, "Incomplete distribution inputs")
    require(dt.datetime.fromisoformat(signing["policy"]["expiresAtUtc"]) > dt.datetime.now(dt.timezone.utc), "Provisioning profile expired during the build")
    app = work / f"MIXEL {title}.app"
    contents = app / "Contents"
    macos = contents / "MacOS"
    resources = contents / "Resources"
    macos.mkdir(parents=True)
    resources.mkdir()
    executable = macos / f"MIXEL {title}"
    inputs = [item["file"]["path"] for item in receipt["binaries"]]
    run([TOOLS["lipo"], "-create", "-output", str(executable), *inputs], log=work / "lipo-create.log")
    executable.chmod(0o755)
    actual_arch = set(command_text([TOOLS["lipo"], "-archs", str(executable)]).split())
    expected_arch = {"arm64" if triple.startswith("aarch64") else "x86_64" for triple in TARGETS[args.arch]}
    require(actual_arch == expected_arch, "Staged executable has unexpected architecture slices")
    shutil.copyfile(root / "assets" / "app-icon" / f"{crate}.icns", resources / f"MIXEL {title}.icns")
    legal = copy_legal(root, resources, build_env)
    if slug == "print":
        models = resources / "models"
        models.mkdir()
        # Reuse the product's attributed, hash-verified OCR model staging. This
        # also runs Cargo for xtask, including when app --skip-build is selected.
        model_env = dict(build_env)
        model_env["DIST"] = str(work / "model-helper-dist")
        run(["/bin/bash", "-c", 'set -euo pipefail; . "$1/packaging/env.sh"; stage_models "$2"', "mixel-mas-models", str(root), str(models)], env=model_env, cwd=root, log=work / "ocr-models.log")
    info = generated_info(here, config, version, number, receipt["sourceCommit"], encryption, args.arch)
    (contents / "Info.plist").write_bytes(plistlib.dumps(info, sort_keys=False))
    (contents / "PkgInfo").write_bytes(b"APPL????")
    shutil.copyfile(privacy[0], resources / "PrivacyInfo.xcprivacy")
    shutil.copyfile(signing["profilePath"], contents / "embedded.provisionprofile")
    require(file_proof(contents / "embedded.provisionprofile")["sha256"] == signing["profileProof"]["sha256"], "Staged profile differs from the validated input")
    entitlements = desired_entitlements(here, slug, signing["policy"])
    entitlement_path = work / "signing-entitlements.plist"
    entitlement_path.write_bytes(plistlib.dumps(entitlements))
    # A restrictive caller umask protects the run logs, but must not produce an
    # installed app whose resources are unreadable to another Mac user.
    app.chmod(0o755)
    for staged in app.rglob("*"):
        require(not staged.is_symlink(), "Unexpected symlink while normalizing new app permissions")
        staged.chmod(0o755 if staged.is_dir() or staged == executable else 0o644)
    run([TOOLS["plutil"], "-lint", str(contents / "Info.plist"), str(resources / "PrivacyInfo.xcprivacy"), str(entitlement_path)], log=work / "plist-validation.log")
    for index, subject in enumerate((executable, app), 1):
        run([TOOLS["codesign"], "--force", "--sign", signing["identity"], "--timestamp", "--options", "runtime", "--entitlements", str(entitlement_path), str(subject)], log=work / f"codesign-{index}.log")
    verify_app(app, entitlements, signing["identity"], work, "staged")
    staged_tree = tree_proof(app)
    internal_pkg = work / f"mixel-{slug}-{version}-build{number}-macos-{args.arch}.pkg"
    run([TOOLS["productbuild"], "--component", str(app), "/Applications", "--sign", signing["installer"], "--timestamp", str(internal_pkg)], log=work / "productbuild.log")
    signature_result = subprocess.run([TOOLS["pkgutil"], "--check-signature", str(internal_pkg)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    signature = (signature_result.stdout + signature_result.stderr).decode("utf-8", errors="strict")
    (work / "installer-signature.log").write_text(signature, encoding="utf-8")
    require(signature_result.returncode == 0 and signing["installer"] in signature and "Developer ID Installer:" not in signature, "Installer signature is missing or is not the selected Mac App Store installer identity")
    expanded = work / "expanded-package"
    run([TOOLS["pkgutil"], "--expand-full", str(internal_pkg), str(expanded)], log=work / "pkg-expand.log")
    candidates = list(expanded.rglob(f"MIXEL {title}.app"))
    require(len(candidates) == 1 and candidates[0].is_dir(), "Installer must contain exactly the intended application")
    require(tree_proof(candidates[0]) == staged_tree, "Expanded installer app differs from the signed staged app")
    verify_app(candidates[0], entitlements, signing["identity"], work, "expanded")
    require(staged_tree == tree_proof(app), "Staged app changed while building the installer")
    require(receipt["source"] == source_catalogue(root), "Source changed during packaging")
    require(receipt["externalFonts"] == external_fonts(build_env), "External font inputs changed during packaging")
    require(signing["profileProof"] == file_proof(signing["profilePath"]), "Profile input changed during packaging")
    require(privacy[1] == file_proof(privacy[0]), "Privacy manifest changed during packaging")
    require(dt.datetime.fromisoformat(signing["policy"]["expiresAtUtc"]) > dt.datetime.now(dt.timezone.utc), "Provisioning profile expired during packaging")
    destination = Path(env.get("MACOS_MAS_DIST", str(root / "dist" / "mas"))).expanduser().resolve()
    require(not root.is_relative_to(destination) and "phase0" not in "/".join(destination.parts).lower(), "MAS output must be separate from source roots and Phase 0 evidence")
    require(not destination.is_relative_to(root) or destination.is_relative_to(root / "dist" / "mas"), "In-checkout MAS output must stay under dist/mas")
    destination.mkdir(parents=True, exist_ok=True)
    final_pkg = destination / internal_pkg.name
    with internal_pkg.open("rb") as source, final_pkg.open("xb") as output:
        shutil.copyfileobj(source, output)
    require(file_proof(final_pkg)["sha256"] == file_proof(internal_pkg)["sha256"], "Final installer copy differs from verified package")
    result = {"schema": "mixel.mas-package.v1", "recordedAtUtc": utc_now(), "app": slug, "version": version, "buildNumber": number, "arch": args.arch, "buildReceipt": receipt_proof, "sourceFingerprint": receipt["source"]["sha256"], "profile": signing["policy"], "profileInput": signing["profileProof"], "profileMetadata": signing["metadataProof"], "privacyManifest": privacy[1], "usesNonExemptEncryption": encryption, "entitlements": entitlements, "legalFiles": legal, "signedAppFiles": staged_tree, "package": file_proof(final_pkg), "checks": {"sourceAndMasBuildReceipt": "passed", "provisioningProfile": "passed", "actualArchitectures": sorted(actual_arch), "exactCodeEntitlements": "passed", "distributionCertificate": "passed", "installerSignature": "passed", "expandedAppByteAndModeEquality": "passed", "expandedAppCodesign": "passed"}, "notPerformed": ["App Store validation", "upload", "TestFlight processing", "sandbox runtime acceptance", "public release"]}
    output_record = final_pkg.with_name(final_pkg.name + ".provenance.json")
    write_json(output_record, result)
    print(f"==> MAS package verified: {final_pkg}\n==> Provenance: {output_record}\n==> No store request was sent; runtime and TestFlight acceptance remain separate", flush=True)


def parser():
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--mas", action="store_true", help=argparse.SUPPRESS)
    result.add_argument("--arch", choices=tuple(TARGETS), default="aarch64")
    group = result.add_mutually_exclusive_group()
    group.add_argument("--skip-build", action="store_true", help="require a trusted MAS build receipt and its recorded SHA256")
    group.add_argument("--build-only", action="store_true", help="build the MAS-feature binary and emit its source/binary receipt; do not sign")
    return result


def main(argv=None):
    args = parser().parse_args(argv)
    root = Path(__file__).resolve().parents[2]
    require(root.name in CONFIG, "Packaging helper must run from its intended MIXEL checkout")
    package(root, CONFIG[root.name], args, dict(os.environ))


if __name__ == "__main__":
    try:
        main()
    except (Failure, OSError, ValueError, TypeError, KeyError, plistlib.InvalidFileException) as error:
        print(f"MAS packaging failed: {error}", file=sys.stderr)
        sys.exit(1)
