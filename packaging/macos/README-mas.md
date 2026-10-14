# Mac App Store variant

`packaging/macos/package.sh --mas` selects a separate sandboxed Mac App Store
variant. The existing command without `--mas` keeps its Developer ID DMG and CLI
ZIP path. MAS output is a signed `.pkg`; this command performs no App Store API
request, upload, notarization, stapling, DMG construction, or public release.

Use Python 3.9 or later and the normal native Rust/macOS build toolchain. The
helper is identical across all seven product repositories and selects the product
from the checkout directory name. App Store acceptance and a working sandbox
runtime are separate verification steps after packaging.

## Build provenance

Build the desktop package with its `mac-app-store` feature and release profile:

```sh
export MACOS_MAS_BUILD_NUMBER=1
packaging/macos/package.sh --mas --build-only --arch aarch64
```

The default architecture is `aarch64`. `x86_64` and `universal` are available.
Photo and Light also enable their own `heif` feature; Light's normal default
features remain enabled and its optional `rawnind-model` feature stays off.
No CLI executable is built for MAS.

The dedicated default Cargo directory is `target/macos-mas`, independent of the
baseline `target/release` binaries. `MACOS_MAS_TARGET_DIR` can select another
absolute, dedicated directory; an in-checkout override must remain below
`target/macos-mas`. Each run receives a new work directory. The build command emits
`MAS_BUILD_RECEIPT` and `MAS_BUILD_RECEIPT_SHA256` values. Record both independently.
The receipt binds all tracked and nonignored source files, the Cargo executable,
actual Cargo JSON artifact features, exact commands and transcript hashes,
controlled build environment, external font inputs, architecture, version, build
number, and executable bytes. A source, binary, helper, transcript, or controlled
environment change invalidates reuse.

For packaging a separately built MAS binary, set `MACOS_MAS_BUILD_RECEIPT` and
`MACOS_MAS_BUILD_RECEIPT_SHA256` to those recorded values and add `--skip-build`.
The helper never accepts an arbitrary existing release binary. Without
`--skip-build`, packaging performs the actual MAS build itself. A build number is
an explicitly allocated positive integer; allocation against the existing store
build history belongs to the suite release process. This script does not guess or
increment counters. Marketing version comes from `[workspace.package]` exactly.

## Distribution inputs

Provide these inputs through the approved local environment. Do not put signing
keys, provisioning profiles, or account credentials in source control.

- `MACOS_MAS_TEAM_ID=5277F8NDH4`
- `MACOS_MAS_SIGN_IDENTITY`: exact 40-hex SHA1 of an installed Apple Distribution
  or 3rd Party Mac Developer Application certificate for that team; ad-hoc and
  Developer ID Application identities are rejected.
- `MACOS_MAS_INSTALLER_IDENTITY`: full installed
  `3rd Party Mac Developer Installer: … (5277F8NDH4)` identity.
- `MACOS_MAS_PROVISIONING_PROFILE`: regular input profile file outside the source
  checkout. It is copied only into the generated app as `embedded.provisionprofile`.
- `MACOS_MAS_PROFILE_METADATA`: API profile record JSON whose `data.attributes`
  (or direct `attributes`) contain `profileType=MAC_APP_STORE`, `profileState=ACTIVE`,
  and the exact UUID of that profile. If `profileContent` is present its decoded
  bytes must also match. The profile's signed CMS contents are checked for macOS,
  team, exact product app ID, validity dates, distribution/debugging policy,
  and the selected certificate. macOS does not require sandbox configuration
  entitlements in the profile; they are enforced independently in the final code
  signature. TestFlight requires an embedded Mac App Store profile, but an absent
  `beta-reports-active` field is not an error and is never invented in the app.
  If that restricted flag is actually present and true in the signed profile,
  it is retained. Optional profile boolean values must be correctly typed.
- `MACOS_MAS_USES_NONEXEMPT_ENCRYPTION=true` or `false`: required, per-app reviewed
  export-compliance classification. The script makes no classification inference
  from TLS or embedded PDF encryption/signing algorithms. A true declaration may
  require further store documentation before a build can test; that is outside
  local packaging.
- `MACOS_MAS_PRIVACY_APPROVAL_SHA256`: SHA256 of the current reviewed
  `mas-privacy.xcprivacy`. The initial source manifest says no tracking or collected
  data and has an empty required-reason API inventory. Audit the app and dependency
  API use, add accurate Apple reason entries where required, then approve that
  exact file. Packaging must not be used to imply that an unaudited empty inventory
  has passed privacy review.

Local packaging example after setting the inputs above:

```sh
packaging/macos/package.sh --mas --skip-build --arch aarch64
```

Output defaults to `dist/mas`. `MACOS_MAS_DIST` may select a separate directory;
in-checkout output must stay under `dist/mas`. Existing artifact names are never
overwritten. The default Developer ID output directory and identities are unused.
Signing is applied only to a newly staged copy, inside out, with the exact MAS
entitlements. It never re-signs a baseline executable or previous release.

## Resources and entitlements

The app retains its product ID, full icon, document declarations, category, and
minimum OS from `Info.plist.in`. Generated MAS metadata uses the workspace version
and explicit build number, with the explicit encryption declaration. Legal notices
and embedded-font licenses are staged before signing, including the default
vendored CJK font licenses, any external `CRAFT_FONTS_DIR` licenses, and pinned
`mixel/third-party` dependency license copies (including apple-scoped-bookmarks).
Every staged legal/font license is checked against its source hash. Print uses
the existing attributed, hash-verified `stage_models` helper for OCR resources;
that helper runs Cargo for xtask even with app `--skip-build`.

The common policy enables App Sandbox, user-selected read/write, app-scoped
bookmarks, and outgoing network connections. Photo, Vector, and Print also enable
printing. Film alone enables both the [App Sandbox microphone entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.microphone)
and the [Hardened Runtime audio-input entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.audio-input),
because the signed app uses both protections and records microphone audio. It retains
its microphone purpose string. No product enables network-server, JIT, broad file access, or unrestricted Apple
Events targets. The MAS runtime must keep control/MCP listeners disabled. Light
retains its Photos export and existing purpose string using Apple Events plus
`com.apple.security.scripting-targets` restricted to `com.apple.Photos` and these
Photos-declared access groups: `com.apple.Photos.import`,
`com.apple.Photos.library.read`, and `com.apple.Photos.library.read-write`. Those
groups cover the existing script's import, album lookup/create, and returned IDs.
No temporary exception is enabled. The first-use TCC permission remains under the
user's control; this build/package command never accesses a Photos library.

## Verification boundaries

The helper checks the actual Cargo feature-bearing artifact receipt, profile,
exact architecture slices, plist syntax, application signature and certificate,
exact signed entitlements, installer signature, expanded-package app bytes/modes,
and strict code signatures after expansion. It writes a provenance JSON beside
the package and preserves native command logs in its private run directory.
Decoded provisioning profiles are not written to logs.

A package result does not prove sandbox behavior or TestFlight acceptance. Run the
actual signed app, use native open/save panels, reopen recent files after relaunch,
verify container/temp/cache/plugin/font paths and product-specific device flows.
After separately authorized store validation/upload, wait for the actual Ready to
Test state and verify installation through TestFlight where possible. Existing
live or review submissions must be preserved.

Profile policy follows [Apple TN3125: Inside Code Signing: Provisioning Profiles](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles), including its macOS entitlement and TestFlight distinctions. Displayed code entitlements are requested as XML explicitly before plist parsing.
