#!/bin/bash
# Rebrand the ArtCraft Crafting Apps forks as the MIXEL creative suite.
# Idempotent: safe to re-run after merging upstream changes.
#
# Changes: user-visible product names, bundle/app IDs (content + file names), vendor name,
# in-app GitHub/app-page links. Keeps: Rust crate/module/type names, file extensions,
# LICENSE/NOTICE/ATTRIBUTION/contributors (Apache-2.0 + MIT require the notices).
set -u  # no -e/pipefail: "no matches" is a normal outcome for every step
for tool in perl python3 git; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'error: required tool is unavailable: %s\n' "$tool" >&2
    exit 1
  fi
done
ROOT="$(cd "$(dirname "$0")" && pwd)"
# Inside one fork (rebrand.sh at the repo root): only that repo. In the suite folder: all seven.
ONLY=""
if [ -f "$ROOT/Cargo.toml" ]; then ONLY="$(basename "$ROOT")"; ROOT="$(dirname "$ROOT")"; fi

# repo-suffix : upstream-slug
APPS="photo:photocraft vector:vectorcraft film:filmcraft light:lightcraft print:pdfcraft effects:effectcraft design:designcraft"
# The Adobe app each one replaces (README header).
adobe_of() { case "$1" in photo) echo Photoshop ;; vector) echo Illustrator ;; film) echo "Premiere Pro" ;;
  light) echo Lightroom ;; print) echo "Acrobat Pro" ;; effects) echo "After Effects" ;; design) echo InDesign ;; esac; }

# Perl capture variables are literal program text, never shell interpolation.
# shellcheck disable=SC2016
export REBRAND_PERL='
  # Embedded copyright fields and notice lines keep their original authors.
  # The metadata pass recovers already-branded values from upstream and appends
  # a separate MIXEL modification credit. Plist copyright values include this word.
  next if /copyright/i;
  # Product names, as whole tokens only, so identifiers like PhotocraftApp or PhotoCraftVersion stay.
  s/(?<![A-Za-z0-9_])PhotoCraft(?![A-Za-z0-9_])/MIXEL Photo/g;
  s/(?<![A-Za-z0-9_])VectorCraft(?![A-Za-z0-9_])/MIXEL Vector/g;
  s/(?<![A-Za-z0-9_])FilmCraft(?![A-Za-z0-9_])/MIXEL Film/g;
  s/(?<![A-Za-z0-9_])LightCraft(?![A-Za-z0-9_])/MIXEL Light/g;
  s/(?<![A-Za-z0-9_])(?:PdfCraft|PDFCraft)(?![A-Za-z0-9_])/MIXEL Print/g;
  s/(?<![A-Za-z0-9_])EffectCraft(?![A-Za-z0-9_])/MIXEL Effects/g;
  s/(?<![A-Za-z0-9_])DesignCraft(?![A-Za-z0-9_])/MIXEL Design/g;
  # DPX has a 100-byte creator field. Copy the actual branded byte length;
  # preserve its zero padding and avoid a stale upstream nine-byte slice.
  s/^([ \t]*)hd\[160\.\.169\]\.copy_from_slice\(b"(?:FilmCraft|MIXEL Film)"\);([ \t]*)$/${1}let creator = b"MIXEL Film";\n${1}hd[160..160 + creator.len()].copy_from_slice(creator);${2}/;
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
  # The Help command and sibling-table description identify this fork family.
  # Exact descriptor/comment forms leave historical author/community strings alone.
  s/^(\s*)"Other ArtCraft Apps",(\s*)$/${1}"Other MIXEL Apps",${2}/;
  s#^(\s*/// )Sibling apps of the ArtCraft family: \(name, what it is, GitHub repo, app page\)\.#${1}Sibling apps of the MIXEL family: (name, legacy app slug).#;
  # The sibling-app heading is fork branding. Translate only its exact keyed
  # row/literal; unrelated ArtCraft community labels and author credits stay.
  if (/^\s*\("More ArtCraft apps"\s*,/ || /\btr\([^;\n]*"More ArtCraft apps"/) {
    s/"More ArtCraft apps"/"More MIXEL apps"/g;
    s/"更多 ArtCraft 应用"/"更多 MIXEL 应用"/g;
    s/"更多 ArtCraft 應用"/"更多 MIXEL 應用"/g;
    s/"ほかのArtCraftアプリ"/"ほかのMIXELアプリ"/g;
    s/"他の ArtCraft アプリ"/"他の MIXEL アプリ"/g;
    s/"Інші програми ArtCraft"/"Інші програми MIXEL"/g;
    s/"Mais aplicativos ArtCraft"/"Mais aplicativos MIXEL"/g;
    s/"Altre app ArtCraft"/"Altre app MIXEL"/g;
    s/"المزيد من تطبيقات ArtCraft"/"المزيد من تطبيقات MIXEL"/g;
    s/"Další aplikace ArtCraft"/"Další aplikace MIXEL"/g;
  }
'


# The mutation and provenance check run these same deterministic link programs.
# Perl variables are literal code; the shell must not interpolate them.
# shellcheck disable=SC2016
export REBRAND_DIRECT_LINK_PERL='
  next if /copyright/i;
  my $slug = $ENV{REBRAND_SLUG};
  my $fork = $ENV{REBRAND_FORK};
  my $app = $ENV{REBRAND_APP};
  my %apps = (photocraft => "photo", vectorcraft => "vector", filmcraft => "film",
              lightcraft => "light", pdfcraft => "print", effectcraft => "effects", designcraft => "design");
  s#(?:https?://)?getartcraft\.com/apps/(photocraft|vectorcraft|filmcraft|lightcraft|pdfcraft|effectcraft|designcraft)(?![A-Za-z0-9_-])#"https://github.com/jangopeopleV2/mixel-" . $apps{$1}#ge;
  s#https://github\.com/storytold/\Q$slug\E(?![A-Za-z0-9_-])#$fork#g;
  s#api\.github\.com/repos/storytold/\Q$slug\E/#api.github.com/repos/jangopeopleV2/mixel-$app/#g;
'
# shellcheck disable=SC2016
export REBRAND_TEMPLATE_LINK_PERL='
        next if /copyright/i;
        my $f = $ENV{REBRAND_FORK};
        # Only the two public sibling helpers get a routing table. Other dynamic
        # slug templates retain their inputs; APP/APP_ID templates name this app.
        our ($sibling_route, $sibling_file);
        if (!defined($sibling_file) || $sibling_file ne $ARGV) {
          $sibling_route = undef;
          $sibling_file = $ARGV;
        }
        $sibling_route = $1 if /^\s*pub fn (github_of|page_of)\(slug: &str\) -> String \{\s*$/;
        if (defined($sibling_route) && /^(\s*)(?:format!\("https:\/\/(?:github\.com\/storytold| getartcraft\.com\/apps)\/\{slug\}"\)|"\Q$f\E"\.to_string\(\))\s*$/x) {
          my $indent = $1;
          my %apps = (photocraft => "photo", vectorcraft => "vector", filmcraft => "film",
                      lightcraft => "light", pdfcraft => "print", effectcraft => "effects", designcraft => "design");
          my @slugs = qw(photocraft vectorcraft filmcraft lightcraft pdfcraft effectcraft designcraft);
          my $base = $sibling_route eq "github_of" ? "https://github.com/storytold" : "https://getartcraft.com/apps";
          $_ = $indent . "match slug {\n"
             . join("", map { $indent . "    \"$_\" => \"https://github.com/jangopeopleV2/mixel-$apps{$_}\".to_string(),\n" } @slugs)
             . $indent . "    _ => format!(\"$base/{slug}\"),\n"
             . $indent . "}\n";
        }
        $sibling_route = undef if /^\s*\}\s*$/;
        s#format!\("\{WEBSITE(?:_URL)?\}/apps/\{APP(?:_ID)?\}"\)#"$f".to_string()#g;
        s#format!\("https://github\.com/storytold/\{(?:APP_ID|APP)\}"\)#"$f".to_string()#g;
        s#(MIXEL [A-Z][a-z]+) on getartcraft\.com#$1 project page#g;
        s#assert!\((?:super::)?APP_PAGE\.ends_with\(&format!\("/apps/\{APP\}"\)\)\);#assert!(APP_PAGE.starts_with("$f"));#g;
        s#assert!\((?:super::)?GITHUB\.ends_with\(&format!\("/storytold/\{APP\}"\)\)\);#assert!(GITHUB.starts_with("$f"));#g;
        s#assert_eq!\(APP_PAGE, format!\("\{WEBSITE\}/apps/\{APP\}"\)\);#assert!(APP_PAGE.starts_with("$f"));#g;
        s#assert_eq!\(GITHUB, format!\("https://github\.com/storytold/\{APP\}"\)\);#assert!(GITHUB.starts_with("$f"));#g;
        s#assert_eq!\(super::APP_PAGE, format!\("\{\}/apps/\{\}", super::WEBSITE, super::APP\)\);#assert!(super::APP_PAGE.starts_with("$f"));#g;
        s#assert_eq!\(super::GITHUB, format!\("https://github\.com/storytold/\{\}", super::APP\)\);#assert!(super::GITHUB.starts_with("$f"));#g;
'

# One metadata program is used by mutations and exact asset-provenance replay.
# MSI UUIDs are UUIDv5(NAMESPACE_URL, "ch.mixel.<app>"). Keep this recipe stable:
# versions and architectures must upgrade the same fork, never the upstream app.
# info@mixel.ch is the public company contact in mixel-ch Terms.tsx / Privacy.tsx.
REBRAND_METADATA_PY="$(cat <<'PYMETADATA'
import os, pathlib, re, subprocess, uuid

METADATA_IDS = {"photo": "photocraft", "vector": "vectorcraft", "film": "filmcraft", "light": "lightcraft",
                "print": "pdfcraft", "effects": "effectcraft", "design": "designcraft"}
METADATA_BRANDS = {"PhotoCraft": "Photo", "VectorCraft": "Vector", "FilmCraft": "Film", "LightCraft": "Light",
                   "PdfCraft": "Print", "PDFCraft": "Print", "EffectCraft": "Effects", "DesignCraft": "Design"}
COPYRIGHT_PATTERNS = (
    re.compile(r'(?P<head><key>NSHumanReadableCopyright</key>\s*<string>)(?P<value>.*?)(?P<tail></string>)', re.S),
    re.compile(r'(?P<head>"LegalCopyright"\s*,\s*")(?P<value>(?:\\.|[^"\\])*)(?P<tail>")'),
)

def metadata_upstream(path):
    old = re.sub(r"ch\.mixel\.([a-z]+)", lambda m: "ai.storyteller." + METADATA_IDS.get(m.group(1), m.group(1)), path)
    result = subprocess.run(["git", "show", "upstream/main:" + old], capture_output=True)
    return result.stdout if result.returncode == 0 else None

def legacy_brand(value):
    # Only for recognition/recovery of this script's previous copyright edits.
    for old, new in METADATA_BRANDS.items():
        value = re.sub(r"(?<![A-Za-z0-9_])" + old + r"(?![A-Za-z0-9_])", "MIXEL " + new, value)
    for app, slug in METADATA_IDS.items():
        value = value.replace("ai.storyteller." + slug, "ch.mixel." + app)
    return value.replace("Learning Machines LLC", "MIXEL")

def restore_readme_copyright(text, source):
    # Recover only complete upstream copyright lines or their known old product
    # substitutions. An unrelated author or local addition is never rewritten.
    originals = [line for line in source.splitlines()
                 if re.match(r"^\s*Copyright\b", line, re.I)]
    credit = "MIXEL " + os.environ["REBRAND_APP"].capitalize() + " modifications by MIXEL contributors."
    lines = text.splitlines(keepends=True)
    matched = None
    for i, line in enumerate(lines):
        core = line.rstrip("\r\n")
        ending = line[len(core):]
        for original in originals:
            previous = legacy_brand(original)
            candidate = next((value for value in (original, previous)
                              if core == value or core.startswith(value + " ")), None)
            if candidate is None:
                continue
            lines[i] = original + core[len(candidate):] + ending
            if matched is None:
                matched = i
            break
    if matched is not None and credit not in [line.rstrip("\r\n") for line in lines]:
        # Keep the complete original notice on its own line. Preserve whether
        # the existing README ended in a newline when appending at EOF.
        ending = "\r\n" if lines[matched].endswith("\r\n") else "\n"
        terminated = lines[matched].endswith(("\r", "\n"))
        if not terminated:
            lines[matched] += ending
        lines.insert(matched + 1, credit + (ending if terminated else ""))
    return "".join(lines)

def metadata_scope(path, data):
    parts = pathlib.PurePosixPath(path).parts
    if path == "README.md" and b"\0" not in data:
        return b"copyright" in data.lower()
    if not parts or parts[0] not in {"apps", "crates", "packaging"} or b"\0" in data:
        return False
    if re.match(r"(?:LICENSE[^/]*|NOTICE[^/]*|ATTRIBUTION[^/]*|.*\.attribution)$", parts[-1]):
        return False
    return bool(re.search(rb"UpgradeCode|GITHUB_REPOSITORY|_MAINTAINER|NSHumanReadableCopyright|LegalCopyright|WindowsResource::new", data))

def metadata_bytes(path, data, upstream=None):
    if not metadata_scope(path, data):
        return data
    try:
        text = data.decode("utf-8")
        source = upstream.decode("utf-8") if upstream is not None else ""
    except UnicodeDecodeError:
        return data  # Non-text files never prove a text metadata transformation.
    app = os.environ["REBRAND_APP"]
    slug = os.environ["REBRAND_SLUG"]
    product = "MIXEL " + app.capitalize()
    credit = " " + product + " modifications by MIXEL contributors."
    if path == "README.md":
        return restore_readme_copyright(text, source).encode("utf-8")
    if path.startswith("packaging/windows/") and path.endswith(".wxs"):
        guid = str(uuid.uuid5(uuid.NAMESPACE_URL, "ch.mixel." + app)).upper()
        upgrade = re.compile(r'(UpgradeCode\s*=\s*["\'])(\{?)([0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12})(\}?)(["\'])')
        if any(match.group(3).upper() == guid for match in upgrade.finditer(source)):
            raise ValueError("fork UpgradeCode must differ from upstream: " + path)
        text = upgrade.sub(lambda m: m.group(1) + m.group(2) + guid + m.group(4) + m.group(5), text)
    if path.startswith("packaging/linux/"):
        text = re.sub(r'(\$\{GITHUB_REPOSITORY:-)storytold/' + re.escape(slug) + r'(\})',
                      lambda m: m.group(1) + "jangopeopleV2/mixel-" + app + m.group(2), text)
        text = re.sub(r'(\$\{[A-Z0-9_]+_MAINTAINER:-)[^}\n]*(\})',
                      lambda m: m.group(1) + product + " maintainers <info@mixel.ch>" + m.group(2), text)
    for pattern in COPYRIGHT_PATTERNS:
        originals = [match.group("value") for match in pattern.finditer(source)]
        index = 0
        def copyright(match):
            nonlocal index
            value = match.group("value")
            whitespace = re.search(r"\s*$", value).group(0)
            core = value[:len(value) - len(whitespace)] if whitespace else value
            while core.endswith(credit):
                core = core[:-len(credit)]
            if index < len(originals):
                original = originals[index].rstrip()
                previous = legacy_brand(original)
                # Restore only the known previous transformation, preserving
                # unrelated local legal additions instead of replacing them.
                if previous != original and previous in core:
                    core = core.replace(previous, original, 1)
            index += 1
            return match.group("head") + core + credit + whitespace + match.group("tail")
        text = pattern.sub(copyright, text)
    if path.endswith(".rs") and "WindowsResource::new" in text:
        variables = set(re.findall(r'let\s+(?:mut\s+)?([A-Za-z_]\w*)\s*=\s*(?:\w+::)*WindowsResource::new\(\)', text))
        for variable in sorted(variables):
            # Resource statements are small chains. Quoted semicolons do not
            # terminate them; declarations and unrelated statements stay intact.
            chain = re.compile(r'\b' + re.escape(variable) + r'\.(?:set_icon|set)\((?:"(?:\\.|[^"\\])*"|[^;"])*;')
            def company(match):
                statement = match.group(0)
                if re.search(r'\.set\(\s*"CompanyName"\s*,', statement):
                    return statement
                product_field = re.search(r'\.set\(\s*"ProductName"\s*,', statement)
                if product_field is None:
                    return statement
                prefix = statement[:product_field.start()]
                last_line = prefix.rsplit("\n", 1)[-1]
                indent = last_line if not last_line.strip() else "    "
                return prefix + '.set("CompanyName", "MIXEL")\n' + indent + statement[product_field.start():]
            text = chain.sub(company, text)
    return text.encode("utf-8")
PYMETADATA
)"
export REBRAND_METADATA_PY

# Every text transformation leaves legal notices and attribution authors intact.
code_files() {
  git ls-files -z "$@" \
    | /usr/bin/grep --null-data -vE '(^|/)(LICENSE[^/]*|NOTICE[^/]*|ATTRIBUTION[^/]*|[^/]*\.attribution)$|^contributors/|^vendor/'
}

for pair in $APPS; do
  n=${pair%%:*}; slug=${pair##*:}
  [ -n "$ONLY" ] && [ "$ONLY" != "mixel-$n" ] && continue
  export REBRAND_SLUG="$slug" REBRAND_APP="$n" REBRAND_FORK="https://github.com/jangopeopleV2/mixel-$n"
  repo="$ROOT/mixel-$n"
  echo "== mixel-$n"
  cd "$repo" || exit 1

  # 0. MIXEL patches (fixes not yet upstream), from mixel/patches/*.patch, applied once.
  for patch in mixel/patches/*.patch; do
    [ -f "$patch" ] || continue
    if git apply --reverse --check "$patch" 2>/dev/null || \
       perl -pe "$REBRAND_PERL" "$patch" | git apply --reverse --check --unidiff-zero - 2>/dev/null; then
      # A prior run may have branded a patch's context after applying it.
      # Verify the reverse of that same deterministic transformation too. In this
      # check only, allow the README header to move an otherwise matching hunk
      # away from the file's start; all supplied context must still match.
      :
    elif ! git apply "$patch"; then
      echo "error: $patch does not apply; resolve or retire it before continuing" >&2
      exit 1
    fi
  done

  # 1. Text content in code + packaging (not docs history, not legal notices).
  code_files apps crates packaging xtask assets .github/workflows README.md \
    | xargs -0 /usr/bin/grep -lI --null -E 'PhotoCraft|VectorCraft|FilmCraft|LightCraft|PdfCraft|PDFCraft|EffectCraft|DesignCraft|ai\.storyteller\.|Learning Machines LLC|More ArtCraft apps|Other ArtCraft Apps|Sibling apps of the ArtCraft family|hd\[160\.\.169\]\.copy_from_slice\(b"MIXEL Film"\)' 2>/dev/null \
    | xargs -0 -r perl -pi -e "$REBRAND_PERL" || exit 1

  # 2. File names carrying the old app ID (e.g. ai.storyteller.photocraft.desktop).
  git ls-files | /usr/bin/grep 'ai\.storyteller\.' | while read -r f; do
    nf=$(printf '%s' "$f" | perl -pe "$REBRAND_PERL")
    if [ "$f" != "$nf" ]; then git mv "$f" "$nf" || exit 1; fi
  done || exit 1

  # 3. App-page, source and update-check links point at the MIXEL fork.
  code_files crates apps packaging .github/workflows \
    | xargs -0 /usr/bin/grep -lI --null -E "getartcraft\.com/apps/(photocraft|vectorcraft|filmcraft|lightcraft|pdfcraft|effectcraft|designcraft)|github\.com/storytold/$slug|api\.github\.com/repos/storytold/$slug/" 2>/dev/null \
    | xargs -0 -r perl -pi -e "$REBRAND_DIRECT_LINK_PERL" || exit 1

  # 4. Links built from a template, their labels, and tests of the URL scheme.
  #    ArtCraft's general website and Discord links stay as upstream credit.
  code_files crates apps \
    | xargs -0 /usr/bin/grep -lI --null -E 'getartcraft|storytold/\{|on getartcraft\.com|pub fn (github_of|page_of)\(slug:' 2>/dev/null \
    | xargs -0 -r perl -pi -e "$REBRAND_TEMPLATE_LINK_PERL" || exit 1

  # Fork packaging identity and embedded author credits, including recovery of
  # copies branded by an older rebrand.sh. No application source names change.
  python3 - <<'PYMETADATA_RUN' || exit 1
import os, pathlib, subprocess
exec(os.environ["REBRAND_METADATA_PY"])
paths = subprocess.run(["git", "ls-files", "-z", "apps", "crates", "packaging", "README.md"], capture_output=True, check=True).stdout
for raw in paths.split(b"\0"):
    if not raw:
        continue
    path = pathlib.Path(os.fsdecode(raw))
    if not path.is_file():
        continue
    original = path.read_bytes()
    if not metadata_scope(path.as_posix(), original):
        continue
    updated = metadata_bytes(path.as_posix(), original, metadata_upstream(path.as_posix()))
    if updated != original:
        path.write_bytes(updated)
PYMETADATA_RUN

  # GitHub is a source backup for MIXEL. Keep inherited Actions as manual break-glass
  # workflows while preserving workflow_dispatch inputs and the existing jobs.
  python3 - <<'PY' || exit 1
from pathlib import Path
import re

for path in sorted(Path(".github/workflows").glob("*.y*ml")):
    text = path.read_text()
    lines = text.splitlines(keepends=True)
    starts = [i for i, line in enumerate(lines) if re.match(r"^(?:on|\"on\"|'on')\s*:", line)]
    if len(starts) != 1:
        raise SystemExit(f"error: {path} must have exactly one top-level on event mapping")
    start = starts[0]
    end = next((i for i in range(start + 1, len(lines))
                if lines[i].strip() and not lines[i][0].isspace() and not lines[i].startswith("#")), len(lines))
    dispatch = next((i for i in range(start + 1, end)
                     if re.match(r"^  workflow_dispatch\s*:", lines[i])), None)
    if dispatch is None:
        event_lines = ["  workflow_dispatch:\n"]
    else:
        dispatch_end = next((i for i in range(dispatch + 1, end)
                             if re.match(r"^  [^ \t#][^\n]*:", lines[i])), end)
        event_lines = lines[dispatch:dispatch_end]
        while event_lines and not event_lines[-1].strip():
            event_lines.pop()
    replacement = ["on:\n", *event_lines, "\n"]
    updated = "".join(lines[:start] + replacement + lines[end:])
    if updated != text:
        path.write_text(updated)
PY
  # The app page now is the GitHub fork: translations of "<app> project page" say so.
  # $1 is a literal Perl capture, not a shell argument.
  # shellcheck disable=SC2016
  git ls-files -z '*.tsv' | xargs -0 /usr/bin/grep -lI --null 'project page' 2>/dev/null \
    | xargs -0 -r perl -pi -e 's/^(\tMIXEL [A-Z][a-z]+ project page\t.*?)getartcraft\.com/$1GitHub/' || exit 1

  # 6. Asset manifests that pin file hashes (ATTRIBUTION.toml): re-pin only the files this
  #    rebrand changed, i.e. where upstream's copy matched the pinned hash. Anything else stays
  #    a real provenance failure for `cargo xtask assets`.
  # Renamed files (step 2) keep their attribution entries: only the app-ID part of paths changes
  # in the manifests; titles, authors and credits stay upstream's.
  git ls-files -z | /usr/bin/grep --null-data -E '(^|/)(ATTRIBUTION[^/]*|ASSETS)\.(toml|md)$|\.attribution$' \
    | xargs -0 /usr/bin/grep -lI --null 'ai\.storyteller\.' 2>/dev/null \
    | xargs -0 -r perl -pi -e 's/ai\.storyteller\.photocraft/ch.mixel.photo/g; s/ai\.storyteller\.vectorcraft/ch.mixel.vector/g; s/ai\.storyteller\.filmcraft/ch.mixel.film/g; s/ai\.storyteller\.lightcraft/ch.mixel.light/g; s/ai\.storyteller\.pdfcraft/ch.mixel.print/g; s/ai\.storyteller\.effectcraft/ch.mixel.effects/g; s/ai\.storyteller\.designcraft/ch.mixel.design/g' || exit 1
  if [ -f ATTRIBUTION.toml ]; then
    python3 - <<'PY' || exit 1
import hashlib, os, re, subprocess, pathlib
exec(os.environ["REBRAND_METADATA_PY"])
toml = pathlib.Path("ATTRIBUTION.toml"); text = toml.read_text()
IDS = {"photo": "photocraft", "vector": "vectorcraft", "film": "filmcraft", "light": "lightcraft",
       "print": "pdfcraft", "effects": "effectcraft", "design": "designcraft"}
def upstream_bytes(path):
    path = re.sub(r"ch\.mixel\.([a-z]+)", lambda m: "ai.storyteller." + IDS.get(m.group(1), m.group(1)), path)
    r = subprocess.run(["git", "show", f"upstream/main:{path}"], capture_output=True)
    return r.stdout if r.returncode == 0 else None
def branded_bytes(path, original):
    # Run the same deterministic programs as steps 1/3/4 above. A changed byte
    # outside those transformations must remain a provenance failure.
    parts = pathlib.PurePosixPath(path).parts
    if not parts or b"\0" in original:
        return original
    if re.match(r"(?:LICENSE[^/]*|NOTICE[^/]*|ATTRIBUTION[^/]*|.*\.attribution)$", parts[-1]):
        return original
    workflow = path.startswith(".github/workflows/")
    content_scope = parts[0] in {"apps", "crates", "packaging", "xtask", "assets"} or workflow or path == "README.md"
    link_scope = parts[0] in {"apps", "crates", "packaging"} or workflow
    def perl(program, data):
        return subprocess.run(["perl", "-pe", os.environ[program]], input=data,
                              capture_output=True, check=True).stdout
    result = perl("REBRAND_PERL", original) if content_scope else original
    if link_scope:
        result = perl("REBRAND_DIRECT_LINK_PERL", result)
    if parts[0] in {"apps", "crates"} and re.search(rb"getartcraft|storytold/\{|on getartcraft\.com|pub fn (github_of|page_of)\(slug:", result):
        result = perl("REBRAND_TEMPLATE_LINK_PERL", result)
    if path.endswith(".tsv"):
        result = re.sub(rb"(?m)^(\tMIXEL [A-Z][a-z]+ project page\t.*?)getartcraft\.com", rb"\1GitHub", result)
    result = metadata_bytes(path, result, original)
    return result
def fix(block):
    m_path = re.search(r'^path = "([^"]+)"', block, re.M); m_sha = re.search(r'^sha256 = "([0-9a-f]{64})"', block, re.M)
    if not (m_path and m_sha): return block
    p = pathlib.Path(m_path.group(1))
    if not p.is_file(): return block
    current = p.read_bytes()
    now = hashlib.sha256(current).hexdigest()
    if now == m_sha.group(1): return block
    original = upstream_bytes(m_path.group(1))
    if original is not None and hashlib.sha256(original).hexdigest() == m_sha.group(1) and branded_bytes(m_path.group(1), original) == current:
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
    | xargs -0 -r perl -pi -e "s/(?<![A-Za-z0-9_])$slug(-cli)?-(\\\$\\{?VERSION)/mixel-$n\$1-\$2/g" || exit 1

  # 5. README header: what this is and where it comes from.
  if ! /usr/bin/grep -q 'MIXEL-HEADER' README.md; then
    N="$(printf '%s' "${n:0:1}" | tr '[:lower:]' '[:upper:]')${n:1}"
    { printf '<!-- MIXEL-HEADER -->\n# MIXEL %s\n\n**MIXEL %s** is part of the MIXEL creative suite: an open-source, pure-Rust alternative to Adobe %s for macOS, Windows, Linux and the web.\n\n' "$N" "$N" "$(adobe_of "$n")" || exit 1
      # Markdown backticks are literal output, never shell command substitution.
      # shellcheck disable=SC2016
      printf 'Maintained by [MIXEL](https://mixel.ch). Based on [storytold/%s](https://github.com/storytold/%s) from the ArtCraft Crafting Apps by Brandon Thomas; licensed under Apache-2.0 / MIT (see `LICENSE-APACHE`, `LICENSE-MIT`, `NOTICE`). Upstream changes are merged from the `upstream` remote and re-branded with `rebrand.sh`.\n\n---\n\n' "$slug" "$slug" || exit 1
      cat README.md || exit 1; } > README.md.new && mv README.md.new README.md || exit 1
  fi
  # README renders MIXEL identity and retains upstream credits in plain text.
  python3 - <<'PYREADME' || exit 1
from pathlib import Path
import os, re

path = Path("README.md")
text = path.read_text()
slug = os.environ["REBRAND_SLUG"]
app = os.environ["REBRAND_APP"]
fork = os.environ["REBRAND_FORK"]
# App-page links identify the fork. Legal credit lines keep their complete URLs.
def readme_links(line):
    if re.search(r"copyright", line, re.I):
        return line
    line = re.sub(r"https://getartcraft\.com/apps/" + re.escape(slug) + r"(?![A-Za-z0-9_-])", fork, line)
    line = re.sub(r"getartcraft\.com/apps/" + re.escape(slug) + r"(?![A-Za-z0-9_-])",
                  "github.com/jangopeopleV2/mixel-" + app, line)
    return re.sub(r"(MIXEL [A-Z][a-z]+) on getartcraft\.com", r"\1 project page", line)
text = "".join(readme_links(line) for line in text.splitlines(keepends=True))
# In Quickstart code blocks, cloning without an explicit destination changes the
# checkout's default basename. Update only the following cd in that same block.
lines = text.splitlines(keepends=True)
in_fence = False
changed_default = False
clone = re.compile(r"(\bgit\s+clone[^\n]*?\s)https://github\.com/storytold/" + re.escape(slug) + r"(\.git)?(?=\s|`|$)")
for i, line in enumerate(lines):
    if re.search(r"copyright", line, re.I):
        continue
    if re.match(r"^\s*(?:```|~~~)", line):
        in_fence = not in_fence
        changed_default = False
        continue
    match = clone.search(line)
    if match:
        tail = line[match.end():].strip()
        changed_default = in_fence and (not tail or tail.startswith("#"))
        lines[i] = clone.sub(lambda m: m.group(1) + fork + (m.group(2) or ""), line)
    elif in_fence and changed_default:
        lines[i], count = re.subn(r"^(\s*(?:\$ )?cd\s+)" + re.escape(slug) + r"(?=\s|$)",
                                 lambda m: m.group(1) + "mixel-" + app, line)
        if count:
            changed_default = False
text = "".join(lines)
brand_image = r"(?:src|srcset)\s*=\s*[\"']docs/brand/artcraft-(?:logo|mark)[^\"']*[\"']"
def clean_paragraph(match):
    block = match.group(0)
    if not re.search(brand_image, block):
        return block
    block = re.sub(r"<picture\b[^>]*>.*?</picture>",
                   lambda picture: "" if re.search(brand_image, picture.group(0)) else picture.group(0),
                   block, flags=re.S | re.I)
    block = re.sub(r"<(?:img|source)\b[^>]*>",
                   lambda tag: "" if re.search(brand_image, tag.group(0)) else tag.group(0), block, flags=re.I)
    block = re.sub(r"<a\b[^>]*>\s*</a>", "", block, flags=re.S | re.I)
    block = re.sub(r"Made by the (?=(?:<a\b[^>]*>)?ArtCraft)", "Based on upstream work by the ", block)
    meaningful = re.sub(r"<[^>]+>", "", block).strip() or re.search(r"<(?:img|source|picture)\b", block, re.I)
    return block if meaningful else ""
text = re.sub(r"<p\b[^>]*>.*?</p>", clean_paragraph, text, flags=re.S | re.I)
# Remove only historical mark embeds outside paragraph wrappers, leaving screenshots intact.
text = re.sub(r"<(?:img|source)\b[^>]*>",
              lambda tag: "" if re.search(brand_image, tag.group(0)) else tag.group(0), text, flags=re.I)
paragraphs = text.split("\n\n")
for i, paragraph in enumerate(paragraphs):
    if "ArtCraft" in paragraph and "docs/brand/" in paragraph and "They may be used only" in paragraph:
        paragraphs[i] = (
            "The ArtCraft name, wordmark and logos in [`docs/brand/`](docs/brand/) are trademarks of the\n"
            "ArtCraft Team and retain their upstream restrictions under [`docs/brand/LICENSE-brand.txt`](docs/brand/LICENSE-brand.txt).\n"
            "The files and notices remain as upstream provenance; MIXEL does not embed or display those marks\n"
            "in its runtime identity or README. Plain-text ArtCraft credits acknowledge the upstream project."
        )
text = "\n\n".join(paragraphs)
text = text.replace(
    "apart from the ArtCraft name and logos, which are trademarks of the ArtCraft Team used under "
    "[`docs/brand/LICENSE-brand.txt`](docs/brand/LICENSE-brand.txt).",
    "with historical ArtCraft trademark notices retained separately in [`docs/brand/`](docs/brand/).")
if text != path.read_text():
    path.write_text(text)
PYREADME
done
echo "rebrand done"
