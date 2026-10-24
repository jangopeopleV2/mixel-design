# Mac App Store private API fix

This contract applies to all seven creative apps. It supersedes the older Python
minimum and Print `stage_models` paragraph in `README-mas.md` for these builds.

## Local dependency patch

The local `winit` 0.30.13 patch removes the macOS private API declarations and calls
for `CGSSetWindowBackgroundBlurRadius` and `CGSMainConnectionID`. macOS optional
window blur is unsupported: `set_blur` intentionally does nothing. The apps do not
request this optional effect. Other window behavior and existing platform patches
are preserved, including Design's termination handling and Print's vendor fixes.
The source is `mixel/vendor/winit` for six apps and `vendor/winit` for Print.
Its Apache-2.0 `LICENSE`, `MIXEL-PATCH.md`, and modified-file notices are retained.

## Packaging gate and notices

`mas_package.py` checks both symbol names, with or without the Mach-O leading
underscore, in every declared architecture slice. It scans raw slice bytes so
stripped symbols or dynamic lookup strings cannot bypass this specific gate.
The gate runs when creating or reusing a build receipt, before signing the staged
app, and after package expansion. All regular app payload files are inspected for
Mach-O content. Malformed binaries, private-symbol matches, symlinks, or special
payload files fail packaging. This is a focused regression gate for two symbols.

Existing legal notices and external font licence collection remain in place.
`mas_staging.py` adds the accepted Photo notices, pinned epaint default-font
notices, and the local winit licence/modification note before signing. Every new
copy is checked against its source bytes. The adjacent module is loaded by an
explicit file loader and verified against its pinned SHA256, including under `-I`.

## Python and focused regressions

Use Python 3.14 with `-I -B`. From a product checkout, these commands run the
23 synthetic private-API regressions and eight fake staging regressions. Their
fixtures stay inside ignored `target`; they do not compile, sign, launch an app,
contact a store, or download models. These are packaging checks, not app QA.

```sh
mkdir -p target/macos-mas/private-api-fake-tmp
export TMPDIR="$PWD/target/macos-mas/private-api-fake-tmp"
python3.14 -I -B packaging/macos/test_mas_private_api.py
python3.14 -I -B packaging/macos/test_mas_staging.py
```

After providing the normal build/distribution inputs documented in `README-mas.md`,
invoke the helper with the same interpreter flags:

```sh
python3.14 -I -B packaging/macos/mas_package.py --build-only --arch aarch64
python3.14 -I -B packaging/macos/mas_package.py --skip-build --arch aarch64
```

The second command requires the first command's exact build receipt and SHA256.
It also requires all normal reviewed signing, profile, privacy, and encryption
inputs. A package result does not imply store upload or App Review approval.

## Print retained OCR resources

Print packaging additionally requires all three environment inputs:

- `MACOS_MAS_PRINT_MODELS_DIR`: retained accepted `MIXEL Print.app/Contents/Resources/models`.
- `MACOS_MAS_PRINT_MODELS_PROVENANCE`: the accepted Print 0.7.1, build 2, arm64 package provenance.
- `MACOS_MAS_PRINT_MODELS_PROVENANCE_SHA256`: its independently recorded SHA256.

The exact five files are `text-detection.rten`, `text-recognition.rten`,
`text-detection.rten.LICENCE.txt`, `text-recognition.rten.LICENCE.txt`, and
`ATTRIBUTION.txt`. Membership, content hashes, and ordinary 0644 file modes must
match the accepted provenance; the two model hashes and two licence hashes also
match the attributed source pins. The destination must be new. There is no model
helper, Cargo xtask, archive extraction, or download fallback during packaging.

## Source provenance

Build receipts retain the exact source commit, full source map, helper/module
bytes, and binary proofs used by the build. A later documentation-only commit
must not be presented as the commit used by an already-built package. Preserve
those original receipt/source pins when recording the documentation follow-up.
