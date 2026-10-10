#!/bin/bash
# Rebrand the ArtCraft Crafting Apps forks as the MIXEL creative suite.
# Idempotent: safe to re-run after merging upstream changes.
#
# Changes: user-visible product names, bundle/app IDs (content + file names), vendor name,
# in-app GitHub/app-page links. Keeps: Rust crate/module/type names, file extensions,
# LICENSE/NOTICE/ATTRIBUTION/contributors (Apache-2.0 + MIT require the notices).
set -u  # no -e/pipefail: "no matches" is a normal outcome for every step
ROOT="$(cd "$(dirname "$0")" && pwd)"
# Inside one fork (rebrand.sh at the repo root): only that repo. In the suite folder: all seven.
ONLY=""
if [ -f "$ROOT/Cargo.toml" ]; then ONLY="$(basename "$ROOT")"; ROOT="$(dirname "$ROOT")"; fi

# repo-suffix : upstream-slug
APPS="photo:photocraft vector:vectorcraft film:filmcraft light:lightcraft print:pdfcraft effects:effectcraft design:designcraft"
# The Adobe app each one replaces (README header).
adobe_of() { case "$1" in photo) echo Photoshop ;; vector) echo Illustrator ;; film) echo "Premiere Pro" ;;
  light) echo Lightroom ;; print) echo "Acrobat Pro" ;; effects) echo "After Effects" ;; design) echo InDesign ;; esac; }

export REBRAND_PERL='
  # Product names, as whole tokens only, so identifiers like PhotocraftApp or PhotoCraftVersion stay.
  s/(?<![A-Za-z0-9_])PhotoCraft(?![A-Za-z0-9_])/MIXEL Photo/g;
  s/(?<![A-Za-z0-9_])VectorCraft(?![A-Za-z0-9_])/MIXEL Vector/g;
  s/(?<![A-Za-z0-9_])FilmCraft(?![A-Za-z0-9_])/MIXEL Film/g;
  s/(?<![A-Za-z0-9_])LightCraft(?![A-Za-z0-9_])/MIXEL Light/g;
  s/(?<![A-Za-z0-9_])(?:PdfCraft|PDFCraft)(?![A-Za-z0-9_])/MIXEL Print/g;
  s/(?<![A-Za-z0-9_])EffectCraft(?![A-Za-z0-9_])/MIXEL Effects/g;
  s/(?<![A-Za-z0-9_])DesignCraft(?![A-Za-z0-9_])/MIXEL Design/g;
  # Bundle / app IDs.
  s/ai\.storyteller\.photocraft/ch.mixel.photo/g;
  s/ai\.storyteller\.vectorcraft/ch.mixel.vector/g;
  s/ai\.storyteller\.filmcraft/ch.mixel.film/g;
  s/ai\.storyteller\.lightcraft/ch.mixel.light/g;
  s/ai\.storyteller\.pdfcraft/ch.mixel.print/g;
  s/ai\.storyteller\.effectcraft/ch.mixel.effects/g;
  s/ai\.storyteller\.designcraft/ch.mixel.design/g;
  # Vendor / manufacturer fields.
  s/Learning Machines LLC/MIXEL/g;
'

for pair in $APPS; do
  n=${pair%%:*}; slug=${pair##*:}
  [ -n "$ONLY" ] && [ "$ONLY" != "mixel-$n" ] && continue
  repo="$ROOT/mixel-$n"
  echo "== mixel-$n"
  cd "$repo"

  # 0. MIXEL patches (fixes not yet upstream), from mixel/patches/*.patch, applied once.
  for patch in mixel/patches/*.patch; do
    [ -f "$patch" ] || continue
    if git apply --reverse --check "$patch" 2>/dev/null; then :; else git apply "$patch" || echo "warning: $patch does not apply"; fi
  done

  # 1. Text content in code + packaging (not docs history, not legal notices).
  git ls-files -z apps crates packaging xtask assets README.md \
    | /usr/bin/grep --null-data -vE '(^|/)(LICENSE[^/]*|NOTICE[^/]*|ATTRIBUTION[^/]*|[^/]*\.attribution)$|^contributors/|^vendor/' \
    | xargs -0 /usr/bin/grep -lI --null -E 'PhotoCraft|VectorCraft|FilmCraft|LightCraft|PdfCraft|PDFCraft|EffectCraft|DesignCraft|ai\.storyteller\.|Learning Machines LLC' 2>/dev/null \
    | xargs -0 -r perl -pi -e "$REBRAND_PERL" || true

  # 2. File names carrying the old app ID (e.g. ai.storyteller.photocraft.desktop).
  git ls-files | /usr/bin/grep 'ai\.storyteller\.' | while read -r f; do
    nf=$(printf '%s' "$f" | perl -pe "$REBRAND_PERL")
    if [ "$f" != "$nf" ]; then git mv "$f" "$nf"; fi
  done

  # 3. In-app links point at the MIXEL fork.
  git ls-files -z crates apps | xargs -0 /usr/bin/grep -lI --null -E "getartcraft\.com/apps/$slug|github\.com/storytold/$slug" 2>/dev/null \
    | xargs -0 -r perl -pi -e "s#https://getartcraft\.com/apps/$slug#https://github.com/jangopeopleV2/mixel-$n#g; s#https://github\.com/storytold/$slug(?![A-Za-z0-9_-])#https://github.com/jangopeopleV2/mixel-$n#g" || true

  # 4. Links built from a template, their labels, and the tests pinning the upstream URL scheme.
  #    The ArtCraft website / Discord links stay as upstream credit.
  FORK="https://github.com/jangopeopleV2/mixel-$n"
  git ls-files -z crates apps | xargs -0 /usr/bin/grep -lI --null -E 'getartcraft|storytold/\{|on getartcraft\.com' 2>/dev/null \
    | FORK="$FORK" xargs -0 -r perl -pi -e '
        my $f = $ENV{FORK};
        s#format!\("\{WEBSITE(?:_URL)?\}/apps/\{APP(?:_ID)?\}"\)#"$f".to_string()#g;
        s#format!\("https://getartcraft\.com/apps/\{slug\}"\)#"$f".to_string()#g;
        s#format!\("https://github\.com/storytold/\{(?:APP_ID|APP|slug)\}"\)#"$f".to_string()#g;
        s#(MIXEL [A-Z][a-z]+) on getartcraft\.com#$1 project page#g;
        s#assert!\((?:super::)?APP_PAGE\.ends_with\(&format!\("/apps/\{APP\}"\)\)\);#assert!(APP_PAGE.starts_with("$f"));#g;
        s#assert!\((?:super::)?GITHUB\.ends_with\(&format!\("/storytold/\{APP\}"\)\)\);#assert!(GITHUB.starts_with("$f"));#g;
        s#assert_eq!\(APP_PAGE, format!\("\{WEBSITE\}/apps/\{APP\}"\)\);#assert!(APP_PAGE.starts_with("$f"));#g;
        s#assert_eq!\(GITHUB, format!\("https://github\.com/storytold/\{APP\}"\)\);#assert!(GITHUB.starts_with("$f"));#g;
        s#assert_eq!\(super::APP_PAGE, format!\("\{\}/apps/\{\}", super::WEBSITE, super::APP\)\);#assert!(super::APP_PAGE.starts_with("$f"));#g;
        s#assert_eq!\(super::GITHUB, format!\("https://github\.com/storytold/\{\}", super::APP\)\);#assert!(super::GITHUB.starts_with("$f"));#g;
      ' || true
  # Update checks look at the fork's releases, never upstream's unbranded builds.
  git ls-files -z apps crates | xargs -0 /usr/bin/grep -lI --null "api.github.com/repos/storytold/$slug/" 2>/dev/null \
    | xargs -0 -r perl -pi -e "s#api\.github\.com/repos/storytold/$slug/#api.github.com/repos/jangopeopleV2/mixel-$n/#g" || true
  # The app page now is the GitHub fork: translations of "<app> project page" say so.
  git ls-files -z '*.tsv' | xargs -0 /usr/bin/grep -lI --null 'project page' 2>/dev/null \
    | xargs -0 -r perl -pi -e 's/^(\tMIXEL [A-Z][a-z]+ project page\t.*?)getartcraft\.com/$1GitHub/' || true

  # 6. Asset manifests that pin file hashes (ATTRIBUTION.toml): re-pin only the files this
  #    rebrand changed, i.e. where upstream's copy matched the pinned hash. Anything else stays
  #    a real provenance failure for `cargo xtask assets`.
  # Renamed files (step 2) keep their attribution entries: only the app-ID part of paths changes
  # in the manifests; titles, authors and credits stay upstream's.
  git ls-files -z | /usr/bin/grep --null-data -E '(^|/)(ATTRIBUTION[^/]*|ASSETS)\.(toml|md)$|\.attribution$' \
    | xargs -0 /usr/bin/grep -lI --null 'ai\.storyteller\.' 2>/dev/null \
    | xargs -0 -r perl -pi -e 's/ai\.storyteller\.photocraft/ch.mixel.photo/g; s/ai\.storyteller\.vectorcraft/ch.mixel.vector/g; s/ai\.storyteller\.filmcraft/ch.mixel.film/g; s/ai\.storyteller\.lightcraft/ch.mixel.light/g; s/ai\.storyteller\.pdfcraft/ch.mixel.print/g; s/ai\.storyteller\.effectcraft/ch.mixel.effects/g; s/ai\.storyteller\.designcraft/ch.mixel.design/g' || true
  if [ -f ATTRIBUTION.toml ]; then
    python3 - <<'PY'
import hashlib, re, subprocess, pathlib
toml = pathlib.Path("ATTRIBUTION.toml"); text = toml.read_text()
IDS = {"photo": "photocraft", "vector": "vectorcraft", "film": "filmcraft", "light": "lightcraft",
       "print": "pdfcraft", "effects": "effectcraft", "design": "designcraft"}
def upstream_sha(path):
    path = re.sub(r"ch\.mixel\.([a-z]+)", lambda m: "ai.storyteller." + IDS.get(m.group(1), m.group(1)), path)
    r = subprocess.run(["git", "show", f"upstream/main:{path}"], capture_output=True)
    return hashlib.sha256(r.stdout).hexdigest() if r.returncode == 0 else None
def fix(block):
    m_path = re.search(r'^path = "([^"]+)"', block, re.M); m_sha = re.search(r'^sha256 = "([0-9a-f]{64})"', block, re.M)
    if not (m_path and m_sha): return block
    p = pathlib.Path(m_path.group(1))
    if not p.is_file(): return block
    now = hashlib.sha256(p.read_bytes()).hexdigest()
    if now != m_sha.group(1) and upstream_sha(m_path.group(1)) == m_sha.group(1):
        block = block.replace(m_sha.group(0), f'sha256 = "{now}"')
    return block
parts = re.split(r'(?m)^(?=\[\[)', text)
new = "".join(fix(b) for b in parts)
if new != text: toml.write_text(new)
PY
  fi

  # 7. macOS release artifacts carry the MIXEL name (mixel-photo-<version>-macos-<arch>.dmg).
  #    Other platforms keep upstream's artifact names, which their CI and update feeds expect.
  git ls-files -z packaging/macos | xargs -0 /usr/bin/grep -lI --null -E "$slug(-cli)?-\\\$\\{?VERSION" 2>/dev/null \
    | xargs -0 -r perl -pi -e "s/(?<![A-Za-z0-9_])$slug(-cli)?-(\\\$\\{?VERSION)/mixel-$n\$1-\$2/g" || true

  # 5. README header: what this is and where it comes from.
  if ! /usr/bin/grep -q 'MIXEL-HEADER' README.md; then
    N="$(printf '%s' "${n:0:1}" | tr a-z A-Z)${n:1}"
    { printf '<!-- MIXEL-HEADER -->\n# MIXEL %s\n\n**MIXEL %s** is part of the MIXEL creative suite: an open-source, pure-Rust alternative to Adobe %s for macOS, Windows, Linux and the web.\n\n' "$N" "$N" "$(adobe_of "$n")"
      printf 'Maintained by [MIXEL](https://mixel.ch). Based on [storytold/%s](https://github.com/storytold/%s) from the ArtCraft Crafting Apps by Brandon Thomas; licensed under Apache-2.0 / MIT (see `LICENSE-APACHE`, `LICENSE-MIT`, `NOTICE`). Upstream changes are merged from the `upstream` remote and re-branded with `rebrand.sh`.\n\n---\n\n' "$slug" "$slug"
      cat README.md; } > README.md.new && mv README.md.new README.md
  fi
done
echo "rebrand done"
