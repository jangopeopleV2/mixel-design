#!/bin/bash
# Rebrand upstream creative-app forks as MIXEL Creative Apps.
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
  # Keep this exact upstream attribution sentence, including when another
  # product label on the same line still needs current MIXEL branding.
  s/(Based on the open-source FilmCraft project\.)|(?<![A-Za-z0-9_])FilmCraft(?![A-Za-z0-9_])/defined($1) ? $1 : "MIXEL Film"/ge;
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
  # row/literal; required legal notices and historical comments stay exact.
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
          my $fallback = $sibling_route eq "github_of" ? qq{format!("https://github.com/storytold/{slug}")} : qq{"https://www.mixel.ch".to_string()};
          $_ = $indent . "match slug {\n"
             . join("", map { $indent . "    \"$_\" => \"https://github.com/jangopeopleV2/mixel-$apps{$_}\".to_string(),\n" } @slugs)
             . $indent . "    _ => $fallback,\n"
             . $indent . "}\n";
        }
        if (defined($sibling_route) && $sibling_route eq "page_of") {
          s#_ => format!\("https://getartcraft\.com/apps/\{slug\}"\),#_ => "https://www.mixel.ch".to_string(),#;
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

# Shared README/branding and pre-IO path rules; used again by provenance replay
# and the independent read-only metadata auditor. No product code is imported.
REBRAND_BRANDING_PY="$(cat <<'PYBRANDING'
import pathlib
import re


def private_source_path(path):
    """Lexical pre-IO exclusion only; never inspect a private/opaque body."""
    parts = pathlib.PurePosixPath(path).parts
    if not parts or pathlib.PurePosixPath(path).is_absolute() or '..' in parts:
        return True
    lower = tuple(part.lower() for part in parts)
    if any(part in {'private', '.private', 'secrets', '.secrets', 'credentials', '.credentials',
                    'certs', 'certificates', 'keys', '.keys', '.mixel-secrets', '.git',
                    '.ssh', '.aws', '.azure', '.config', '.claude', '.codex'} for part in lower):
        return True
    name = lower[-1]
    if name.startswith(('claude', '.env')) or name.endswith('.env') or '.env.' in name:
        return True
    if name in {'id_rsa', 'id_dsa', 'id_ecdsa', 'id_ed25519', 'credentials', 'password', 'token',
                'google-services.json', 'googleservice-info.plist', 'service-account.json'}:
        return True
    if name.endswith(('.p12', '.pfx', '.crt', '.cer', '.pem', '.key', '.der', '.jks', '.keystore',
                      '.p8', '.p7b', '.p7c', '.p7m', '.p7s', '.mobileprovision', '.provisionprofile',
                      '.keychain', '.keychain-db')):
        return True
    return name in {'secrets.json', 'secrets.toml', 'secrets.yaml', 'secrets.yml',
                    'credentials.json', 'credentials.toml', 'credentials.yaml', 'credentials.yml',
                    'passwords.json', 'tokens.json', 'private-config.json', 'private-config.toml'}


def immutable_branding_path(path):
    # These exact public files carry immutable packaging/asset provenance,
    # not current UI marketing. Do not mutate or repin them in this generator.
    return path in {'packaging/macos/mas_package.py', 'assets/app-icon/README.md'}


def safe_content_file(path, trusted_root='.'):
    if private_source_path(path):
        return False
    current = pathlib.Path(trusted_root)
    if current.is_symlink():
        return False
    for part in pathlib.PurePosixPath(path).parts:
        current = current / part
        if current.is_symlink():
            return False
    return current.is_file()


def safe_patch_target(path):
    # A public new-file target may not exist yet. Inspect only safe path
    # metadata; reject private names before touching even their metadata.
    if private_source_path(path) or immutable_branding_path(path):
        return False
    current = pathlib.Path('.')
    for part in pathlib.PurePosixPath(path).parts:
        current = current / part
        if current.is_symlink():
            return False
    return True


def safe_patch_targets(text):
    """Gate ordinary Git patch target names before Git can open their bodies."""
    headers = 0
    for line in text.splitlines():
        if line.startswith('diff --git '):
            match = re.fullmatch(r'diff --git a/([^\s"\\]+) b/([^\s"\\]+)', line)
            if not match or any(not safe_patch_target(path) for path in match.groups()):
                return False
            headers += 1
        elif line.startswith(('--- ', '+++ ')):
            value = line[4:]
            if value == '/dev/null':
                continue
            match = re.fullmatch(r'[ab]/([^\s"\\]+)', value)
            if not match or not safe_patch_target(match.group(1)):
                return False
        elif line.startswith(('diff ', 'rename ', 'copy ', 'Binary ', 'GIT binary ')):
            # Only ordinary unquoted textual Git patches are supported here.
            return False
    return headers > 0


def root_readme(path):
    return '/' not in path and path.startswith('README') and path.endswith('.md')


def legal_readme_block(block):
    # Preserve complete required notice/licensing paragraphs, not arbitrary
    # optional marketing constants whose names happen to contain "credit".
    return bool(re.search(r'copyright|\btrademarks?\b|\blicen[cs](?:e|ed|ing)\b|SPDX-License-Identifier|版权|著作权|商标|许可', block, re.I))


def readme_header(app, slug):
    title = 'MIXEL ' + app.capitalize()
    return ('<!-- MIXEL-HEADER -->\n# ' + title + '\n\n**' + title
            + '** is part of [MIXEL Creative Apps](https://www.mixel.ch).\n\n'
            + 'Maintained by [MIXEL](https://www.mixel.ch). Based on [storytold/'
            + slug + '](https://github.com/storytold/' + slug
            + ') by Brandon Thomas and contributors; licensed under Apache-2.0 / MIT '
            + '(see `LICENSE-APACHE`, `LICENSE-MIT`, `NOTICE`).\n\n---\n\n')


def transform_readme(text, app, slug, fork):
    title = 'MIXEL ' + app.capitalize()
    # Recover only this generator's own optional prefix; never remove unknown
    # copyright, licensing or trademark paragraphs from the upstream body.
    title = 'MIXEL ' + app.capitalize()
    adobe = {'photo': 'Photoshop', 'vector': 'Illustrator', 'film': 'Premiere Pro', 'light': 'Lightroom',
             'print': 'Acrobat Pro', 'effects': 'After Effects', 'design': 'InDesign'}[app]
    old_intro = ('**' + title + '** is part of the MIXEL creative suite: an open-source, pure-Rust alternative '
                 'to Adobe ' + adobe + ' for macOS, Windows, Linux and the web.\n\n')
    intro = '**' + title + '** is part of [MIXEL Creative Apps](https://www.mixel.ch).\n\n'
    old_credit = ('Maintained by [MIXEL](https://mixel.ch). Based on [storytold/' + slug
                  + '](https://github.com/storytold/' + slug
                  + ') from the ArtCraft Crafting Apps by Brandon Thomas; licensed under Apache-2.0 / MIT '
                  '(see `LICENSE-APACHE`, `LICENSE-MIT`, `NOTICE`). Upstream changes are merged from the '
                  '`upstream` remote and re-branded with `rebrand.sh`.\n\n---\n\n')
    marker = '<!-- MIXEL-HEADER -->\n# ' + title + '\n\n'
    canonical = readme_header(app, slug)
    intermediate = canonical.replace('`NOTICE`).\n\n---\n\n', '`NOTICE`). Upstream changes are merged from the `upstream` remote and re-branded with `rebrand.sh`.\n\n---\n\n')
    recognized = next((prefix for prefix in (marker + old_intro + old_credit, intermediate, canonical)
                       if text.startswith(prefix)), None)
    if recognized is not None:
        rest = text[len(recognized):]
        heading = re.match(r'\A# [^\n]+\n(?:\n)*', rest)
        if heading and not legal_readme_block(heading.group(0)):
            rest = rest[heading.end():]
        text = canonical + rest
    elif not text.startswith('<!-- MIXEL-HEADER -->'):
        heading = re.search(r'(?m)^# [^\n]+\n', text)
        if heading and not legal_readme_block(heading.group(0)):
            text = text[:heading.start()] + text[heading.end():]
        text = canonical + text.lstrip('\n')
    else:
        heading = re.search(r'(?m)^# [^\n]+', text)
        if heading and not legal_readme_block(heading.group(0)):
            text = text[:heading.start()] + '# ' + title + text[heading.end():]
        # Only the exact optional feature paragraph is replaced if a local legal
        # addition makes the rest of a generated prefix unrecognizable.
        text = text.replace(old_intro, intro, 1)

    # Optional suite/community promotion is replaced as a complete section;
    # the following License and credits (or any other peer heading) stays exact.
    section = re.compile(r'(?ms)^## (?:The Crafting Apps|Crafting Apps|Community)\s*\n(.*?)(?=^## |\Z)')
    text = section.sub(lambda m: ('## MIXEL Creative Apps\n\n[MIXEL Creative Apps](https://www.mixel.ch).\n\n'
                                  if re.search(r'artcraft|discord\.(?:gg|com)', m.group(1), re.I)
                                  and not legal_readme_block(m.group(1)) else m.group(0)), text)

    brands = {'PhotoCraft': 'Photo', 'VectorCraft': 'Vector', 'FilmCraft': 'Film', 'LightCraft': 'Light',
              'PdfCraft': 'Print', 'PDFCraft': 'Print', 'EffectCraft': 'Effects', 'DesignCraft': 'Design'}
    image = r'(?:src|srcset)\s*=\s*[\"\x27]docs/brand/artcraft-(?:logo|mark)[^\"\x27]*[\"\x27]'
    pieces = re.split(r'(\n[ \t]*\n)', text)
    for i in range(0, len(pieces), 2):
        block = pieces[i]
        if legal_readme_block(block):
            if re.search(image, block, re.I):
                raise ValueError('required legal paragraph contains a brand embed; explicit review required')
            continue
        if re.match(r'^\s*>\s*\[!NOTE\]', block) and re.search(r'ArtCraft (?:is a community|是一个)|ArtCraft是一个', block) and 'discord.' in block:
            pieces[i] = ''
            continue
        for old, new in brands.items():
            block = re.sub(r'(?<![A-Za-z0-9_])' + old + r'(?![A-Za-z0-9_])', 'MIXEL ' + new, block)
        block = re.sub(r'<picture\b[^>]*>.*?</picture>',
                       lambda m: '' if re.search(image, m.group(0), re.I) else m.group(0), block, flags=re.S | re.I)
        block = re.sub(r'<(?:img|source)\b[^>]*>',
                       lambda m: '' if re.search(image, m.group(0), re.I) else m.group(0), block, flags=re.I)
        block = re.sub(r'<a\b[^>]*>\s*</a>', '', block, flags=re.S | re.I)
        # Remove upstream chat invitations; never invent a MIXEL Discord.
        block = re.sub(r'<a\b[^>]*href=[\"\x27]https?://(?:www\.)?discord\.(?:gg|com)/[^\"\x27]*[\"\x27][^>]*>.*?</a>', '', block, flags=re.S | re.I)
        block = re.sub(r'\[[^\]]*\]\(https?://(?:www\.)?discord\.(?:gg|com)/[^)]*\)', '', block, flags=re.I)
        block = '\n'.join(line for line in block.split('\n') if not re.search(r'https?://(?:www\.)?discord\.(?:gg|com)/', line, re.I))
        block = re.sub(r'https?://getartcraft\.com/apps/' + re.escape(slug) + r'(?![A-Za-z0-9_-])', fork, block)
        block = re.sub(r'getartcraft\.com/apps/' + re.escape(slug) + r'(?![A-Za-z0-9_-])', 'github.com/jangopeopleV2/mixel-' + app, block)
        block = re.sub(r'(MIXEL [A-Z][a-z]+) on getartcraft\.com', r'\1 project page', block)
        block = re.sub(r'https?://getartcraft\.com(?:/[^\s<>\"\x27)]*)?', 'https://www.mixel.ch', block)
        block = block.replace('ArtCraft Website', 'MIXEL Website')
        block = block.replace(' page on getartcraft.com', ' project page')
        block = block.replace('getartcraft.com 上的 ' + title, title + ' 项目页面')
        block = block.replace('getartcraft.com 的 ' + title + ' 页面', title + ' 项目页面')
        block = re.sub(r'<sub>由\s*<a\b[^>]*>ArtCraft</a>\s*团队和社区制作。</sub>',
                       '<sub>基于 Brandon Thomas 与上游贡献者的工作。由 MIXEL 维护。</sub>', block)

        block = block.replace('More ArtCraft apps', 'MIXEL Creative Apps')
        block = re.sub(r'(?:Made by the |By the )?(?:<a\b[^>]*>)?ArtCraft(?:</a>)? team(?: and community)?\.?',
                       'Based on upstream work by Brandon Thomas and contributors.', block, flags=re.I)
        block = block.replace('ArtCraft by Brandon Thomas', 'upstream work by Brandon Thomas')
        block = re.sub(r'(<a\b[^>]*href=[\"\x27]https://www\.mixel\.ch[\"\x27][^>]*>)ArtCraft(</a>)', r'\1MIXEL Website\2', block)
        block = block.replace('>getartcraft.com<', '>www.mixel.ch<')
        block = block.replace('href="#the-crafting-apps"', 'href="#mixel-creative-apps"')
        for label in ('All Crafting Apps', '全部 Crafting Apps', 'The Crafting Apps', 'Crafting Apps'):
            block = block.replace('>' + label + '</a>', '>MIXEL Creative Apps</a>')

        # Unknown branding prose is not turned into a fabricated MIXEL feature.
        if re.search(r'artcraft', block, re.I):
            raise ValueError('unsupported optional README branding requires explicit review')
        pieces[i] = block
    text = ''.join(pieces)

    # Clone destinations change only inside the same fenced quickstart block.
    lines = text.splitlines(keepends=True)
    in_fence = changed_default = False
    clone = re.compile(r'(\bgit\s+clone[^\n]*?\s)https://github\.com/storytold/' + re.escape(slug) + r'(\.git)?(?=\s|`|$)')
    for i, line in enumerate(lines):
        if re.search(r'copyright', line, re.I):
            continue
        if re.match(r'^\s*(?:```|~~~)', line):
            in_fence = not in_fence
            changed_default = False
            continue
        match = clone.search(line)
        if match:
            tail = line[match.end():].strip()
            changed_default = in_fence and (not tail or tail.startswith('#'))
            lines[i] = clone.sub(lambda m: m.group(1) + fork + (m.group(2) or ''), line)
        elif in_fence and changed_default:
            lines[i], count = re.subn(r'^(\s*(?:\$ )?cd\s+)' + re.escape(slug) + r'(?=\s|$)',
                                      lambda m: m.group(1) + 'mixel-' + app, line)
            if count:
                changed_default = False
    return ''.join(lines)


def apply_exact_readme_patch(original, patch):
    """One root README unified patch, exact lines/counts; unsupported forms refuse."""
    lines = patch.splitlines(keepends=True)
    if not lines:
        raise ValueError('empty patch')
    header = re.fullmatch(r'diff --git a/(README[^/\s]*\.md) b/(README[^/\s]*\.md)\n', lines[0])
    if not header or header.group(1) != header.group(2) or not root_readme(header.group(1)):
        raise ValueError('fallback supports one unchanged root README path only')
    path = header.group(1)
    index = 1
    if index < len(lines) and re.fullmatch(r'index [0-9a-f]+\.\.[0-9a-f]+(?: [0-7]+)?\n', lines[index]):
        index += 1
    if lines[index:index+2] != ['--- a/' + path + '\n', '+++ b/' + path + '\n']:
        raise ValueError('binary/rename/mode/multiple-file patch is unsupported')
    index += 2
    source, output, cursor, hunks = original.splitlines(keepends=True), [], 0, 0
    while index < len(lines):
        hunk = re.fullmatch(r'@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@[^\n]*\n', lines[index])
        if not hunk:
            raise ValueError('exact unified hunk required')
        start, count, newstart, newcount = [int(value) if value is not None else 1 for value in hunk.groups()]
        oldpos = start - 1 if start else 0
        if oldpos < cursor or oldpos > len(source):
            raise ValueError('overlapping/out-of-range hunk')
        output.extend(source[cursor:oldpos])
        if newstart != len(output) + 1:
            raise ValueError('new hunk position differs')
        cursor, consumed, produced = oldpos, 0, 0
        index += 1
        while index < len(lines) and not lines[index].startswith('@@ '):
            line = lines[index]
            if not line or line[0] not in ' +-':
                raise ValueError('unsupported patch directive or missing-newline form')
            kind, value = line[0], line[1:]
            if kind in ' -':
                if cursor >= len(source) or source[cursor] != value:
                    raise ValueError('hunk source/context differs')
                cursor += 1
                consumed += 1
            if kind in ' +':
                output.append(value)
                produced += 1
            index += 1
        if (consumed, produced) != (count, newcount):
            raise ValueError('hunk counts differ')
        hunks += 1
    if not hunks:
        raise ValueError('no hunks')
    output.extend(source[cursor:])
    return path, ''.join(output)



def current_link_regression(path, text, app):
    """Only the two approved obsolete UI/test preimages; no general text rename."""
    if app == 'photo' and path == 'crates/ui-egui/src/titlebar.rs':
        old = re.compile(
            r'(?m)^(?P<indent>[ \t]*)// Wide windows show the whole group; the narrowest drops Discord \(also Help › Discord\)\.\n'
            r'(?P=indent)let has_discord = texts\(&out\)\.iter\(\)\.any\(\|\(t, _\)\| t == "Discord"\);\n'
            r'(?P=indent)assert_eq!\(has_discord, width > 1000\.0, "Discord at \{width\}"\);')
        if len(list(old.finditer(text))) > 1:
            raise ValueError('Duplicate exact Photo caption-test preimage')
        return old.sub(lambda match:
            match.group('indent') + '// No upstream community control is present at any window width.\n'
            + match.group('indent') + 'let has_discord = texts(&out).iter().any(|(t, _)| t == "Discord");\n'
            + match.group('indent') + 'assert!(!has_discord, "Discord must be absent at {width}");', text)
    if app == 'film' and path == 'crates/ui-egui/src/panels/import_mode.rs':
        old_label = 'let label = if primary { tl!("Join us on Discord") } else { crate::i18n::t(label) };'
        old_icons = '[crate::icons::Icon::Chat, crate::icons::Icon::Globe, crate::icons::Icon::Globe, crate::icons::Icon::Code][i]'
        if old_label in text or old_icons in text:
            if text.count(old_label) != 1 or text.count(old_icons) != 1:
                raise ValueError('Exact paired Film import label/icon preimages required')
            return text.replace(old_label, 'let label = crate::i18n::t(label);', 1).replace(old_icons,
                '[crate::icons::Icon::Globe, crate::icons::Icon::Globe, crate::icons::Icon::Code, crate::icons::Icon::Chat][i]', 1)
    return text


def public_source_path(path):
    if private_source_path(path):
        return False
    parts = pathlib.PurePosixPath(path).parts
    if not parts or parts[0] not in {'apps', 'crates', 'assets', 'web', 'packaging'}:
        return False
    if any(p in {'vendor', 'node_modules', 'target', 'dist', 'private', '_scratch', '_logs', '.git', 'tests', 'migrations', 'migration'} for p in parts):
        return False
    name = parts[-1]
    if re.match(r'(?:LICENSE|NOTICE|ATTRIBUTION)', name) or name.endswith('.attribution'):
        return False
    if name.startswith(('test_', 'tests_', '.env', 'CLAUDE')) or name.endswith(('_test.rs', '.test.ts', '.test.js', '.spec.ts', '.spec.js')):
        return False
    return (pathlib.PurePosixPath(name).suffix.lower() in {'.rs', '.tsv', '.json', '.html', '.htm', '.js', '.ts', '.jsx', '.tsx', '.wxs', '.xml'}
            or name.lower().endswith('.xml.in'))


def without_comments(text):
    # Keep line/column positions and literal URLs. Mask comments only outside
    # strings; inline Rust/JS comments and HTML comments are not public branding.
    out = list(text)
    i = 0
    quote = None
    while i < len(text):
        if quote:
            if text[i] == '\\':
                i += 2
                continue
            if text[i] == quote:
                quote = None
            i += 1
            continue
        raw = re.match(r'(?:br|r)(#*)"', text[i:]) if i == 0 or not (text[i-1].isalnum() or text[i-1] == '_') else None
        if raw:
            ending = '"' + raw.group(1)
            end = text.find(ending, i + raw.end())
            i = len(text) if end < 0 else end + len(ending)
            continue
        if text.startswith('<!--', i):
            end = text.find('-->', i + 4)
            end = len(text) if end < 0 else end + 3
        elif text.startswith('/*', i):
            end, depth = i + 2, 1
            while end < len(text) and depth:
                if text.startswith('/*', end):
                    depth += 1
                    end += 2
                elif text.startswith('*/', end):
                    depth -= 1
                    end += 2
                else:
                    end += 1
        elif text.startswith('//', i) and (i == 0 or text[i-1] != ':'):
            end = text.find('\n', i + 2)
            end = len(text) if end < 0 else end
        else:
            if text[i] in ('"', "'", '`'):
                # Rust lifetimes have no closing apostrophe on the same line.
                endline = text.find('\n', i)
                if text[i] != "'" or "'" in text[i+1:endline if endline >= 0 else len(text)]:
                    quote = text[i]
            i += 1
            continue
        for j in range(i, end):
            if out[j] != '\n':
                out[j] = ' '
        i = end
    return ''.join(out)


def runtime_branding_matches(source):
    matches = []
    for path, text in sorted(source.items()):
        if not public_source_path(path):
            continue
        active = without_comments(text)
        if path.endswith('.rs'):
            active = without_rust_tests(active)
        for number, line in enumerate(active.splitlines(), 1):
            # The legal field names are explicit; a file or constant named
            # "credit" is not an exemption for optional marketing.
            if re.match(r'^\s*\.set\(\s*"LegalCopyright"\s*,\s*"(?:\\.|[^"\\])*"\s*\)\s*[,;]?\s*$', line):
                continue
            if re.search(r'artcraft|https?://(?:www\.)?discord\.(?:gg|com)/', line, re.I):
                matches.append({'path': path, 'line': number, 'text': text.splitlines()[number - 1].strip()})
    return matches


def rust_literal_end(text, start):
    raw = re.match(r'(?:br|r)(#*)"', text[start:])
    if raw:
        ending = '"' + raw.group(1)
        close = text.find(ending, start + raw.end())
        return len(text) if close < 0 else close + len(ending)
    if text[start] != '"' and not re.match(r"'(?:\\.|[^'\n])'", text[start:]):
        return None
    quote, end = text[start], start + 1
    while end < len(text):
        if text[end] == '\\':
            end += 2
        elif text[end] == quote:
            return end + 1
        else:
            end += 1
    return len(text)


def without_rust_tests(text):
    """Mask explicitly test-only Rust items; keep their original line positions."""
    out, cursor = list(text), 0
    while cursor < len(text):
        literal = rust_literal_end(text, cursor)
        if literal is not None:
            cursor = literal
            continue
        match = re.match(r'#\[\s*(?:cfg\(\s*test\s*\)|test)\s*\]', text[cursor:])
        if not match:
            cursor += 1
            continue
        start, end = cursor, cursor + match.end()
        depth = 0
        while end < len(text):
            literal = rust_literal_end(text, end)
            if literal is not None:
                end = literal
                continue
            if text[end] == ';' and depth == 0:
                end += 1
                break
            if text[end] == '{':
                depth += 1
            elif text[end] == '}':
                depth -= 1
                if depth == 0:
                    end += 1
                    break
            end += 1
        for i in range(start, end):
            if out[i] != '\n':
                out[i] = ' '
        cursor = end
    return ''.join(out)
PYBRANDING
)"
export REBRAND_BRANDING_PY

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
    if private_source_path(path) or immutable_branding_path(path):
        return None
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
    if private_source_path(path) or immutable_branding_path(path):
        return False
    parts = pathlib.PurePosixPath(path).parts
    if "/" not in path and path.startswith("README") and path.endswith(".md") and b"\0" not in data:
        return b"copyright" in data.lower()
    if not parts or parts[0] not in {"apps", "crates", "packaging"} or b"\0" in data:
        return False
    if path in {'crates/ui-egui/src/titlebar.rs', 'crates/ui-egui/src/panels/import_mode.rs'}:
        return True
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
    text = current_link_regression(path, text, app)
    product = "MIXEL " + app.capitalize()
    credit = " " + product + " modifications by MIXEL contributors."
    if "/" not in path and path.startswith("README") and path.endswith(".md"):
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

# Filter filenames before any grep/Perl/Python body reader sees them.
# The filter performs only lexical checks and safe public-path metadata checks.
safe_files() {
  git ls-files -z "$@" | python3 -c '
import os, sys
exec(os.environ["REBRAND_BRANDING_PY"])
for raw in sys.stdin.buffer.read().split(b"\0"):
    if raw and not immutable_branding_path(os.fsdecode(raw)) and safe_content_file(os.fsdecode(raw)):
        sys.stdout.buffer.write(raw + b"\0")
'
}

# Every text transformation leaves legal notices and attribution authors intact.
code_files() {
  safe_files "$@" \
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
    if ! python3 - "$patch" <<'PYPATCH_TARGETS'
import os, subprocess, sys
exec(os.environ["REBRAND_BRANDING_PY"])
path = sys.argv[1]
if not safe_content_file(path) or not safe_patch_targets(pathlib.Path(path).read_text()):
    raise SystemExit(1)
# Check the exact read-only transformation used by the second reverse check
# before either Git fast path can open a target body.
transformed = subprocess.run(["perl", "-pe", os.environ["REBRAND_PERL"], path],
                             capture_output=True, text=True, check=True).stdout
if not safe_patch_targets(transformed):
    raise SystemExit(1)
PYPATCH_TARGETS
    then
      echo "error: unsafe patch input" >&2; exit 1
    fi
    if git apply --reverse --check "$patch" 2>/dev/null || \
       perl -pe "$REBRAND_PERL" "$patch" | git apply --reverse --check --unidiff-zero - 2>/dev/null; then
      # A prior run may have branded a patch's context after applying it.
      # Verify the reverse of that same deterministic transformation too. In this
      # check only, allow the README header to move an otherwise matching hunk
      # away from the file's start; all supplied context must still match.
      :
    elif python3 - "$patch" <<'PYREADME_PATCH'
import os, pathlib, re, subprocess, sys
exec(os.environ["REBRAND_BRANDING_PY"])
exec(os.environ["REBRAND_METADATA_PY"])
try:
    patch_text = pathlib.Path(sys.argv[1]).read_text()
    header = re.match(r"diff --git a/(README[^/\s]*\.md) b/\1\n", patch_text)
    if not header:
        raise ValueError("not a single root README patch")
    path = header.group(1)
    if private_source_path(path):
        raise ValueError("private README patch target")
    original = subprocess.run(["git", "show", "upstream/main:" + path], capture_output=True, check=True).stdout
    replay_path, patched = apply_exact_readme_patch(original.decode("utf-8"), patch_text)
    if replay_path != path:
        raise ValueError("patch path differs")
    replayed = metadata_bytes(path, patched.encode("utf-8"), original).decode("utf-8")
    expected = transform_readme(replayed, os.environ["REBRAND_APP"], os.environ["REBRAND_SLUG"], os.environ["REBRAND_FORK"]).encode("utf-8")
    current = pathlib.Path(path)
    if not safe_content_file(path) or current.read_bytes() != expected:
        raise ValueError("complete current README differs from exact replay")
except (ValueError, UnicodeError, OSError, subprocess.CalledProcessError):
    raise SystemExit(1)
print("verified exact upstream README patch replay: " + sys.argv[1])
PYREADME_PATCH
    then
      :
    elif ! git apply "$patch"; then
      echo "error: $patch does not apply; resolve or retire it before continuing" >&2
      exit 1
    fi
  done

  # 1. Text content in code + packaging (not docs history, not legal notices).
  code_files apps crates packaging xtask assets .github/workflows \
    | xargs -0 /usr/bin/grep -lI --null -E 'PhotoCraft|VectorCraft|FilmCraft|LightCraft|PdfCraft|PDFCraft|EffectCraft|DesignCraft|ai\.storyteller\.|Learning Machines LLC|More ArtCraft apps|Other ArtCraft Apps|Sibling apps of the ArtCraft family|hd\[160\.\.169\]\.copy_from_slice\(b"MIXEL Film"\)' 2>/dev/null \
    | xargs -0 -r perl -pi -e "$REBRAND_PERL" || exit 1

  # 2. File names carrying the old app ID (e.g. ai.storyteller.photocraft.desktop).
  safe_files | while IFS= read -r -d '' f; do
    case "$f" in *ai.storyteller.*) ;; *) continue ;; esac
    nf=$(printf '%s' "$f" | perl -pe "$REBRAND_PERL")
    if [ "$f" != "$nf" ]; then git mv "$f" "$nf" || exit 1; fi
  done || exit 1

  # 3. App-page, source and update-check links point at the MIXEL fork.
  code_files crates apps packaging .github/workflows \
    | xargs -0 /usr/bin/grep -lI --null -E "getartcraft\.com/apps/(photocraft|vectorcraft|filmcraft|lightcraft|pdfcraft|effectcraft|designcraft)|github\.com/storytold/$slug|api\.github\.com/repos/storytold/$slug/" 2>/dev/null \
    | xargs -0 -r perl -pi -e "$REBRAND_DIRECT_LINK_PERL" || exit 1

  # 4. Links built from a template, their labels, and tests of the URL scheme.
  #    General upstream promotion is not an attribution requirement; unsupported UI fails the final check.
  code_files crates apps \
    | xargs -0 /usr/bin/grep -lI --null -E 'getartcraft|storytold/\{|on getartcraft\.com|pub fn (github_of|page_of)\(slug:' 2>/dev/null \
    | xargs -0 -r perl -pi -e "$REBRAND_TEMPLATE_LINK_PERL" || exit 1

  # Fork packaging identity and embedded author credits, including recovery of
  # copies branded by an older rebrand.sh. No application source names change.
  python3 - <<'PYMETADATA_RUN' || exit 1
import os, pathlib, subprocess
exec(os.environ["REBRAND_BRANDING_PY"])
exec(os.environ["REBRAND_METADATA_PY"])
paths = subprocess.run(["git", "ls-files", "-z", "apps", "crates", "packaging", ":(top,glob)README*.md"], capture_output=True, check=True).stdout
for raw in paths.split(b"\0"):
    if not raw:
        continue
    name = os.fsdecode(raw)
    if immutable_branding_path(name) or not safe_content_file(name):
        continue
    path = pathlib.Path(name)
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
import os, re
exec(os.environ["REBRAND_BRANDING_PY"])

for path in sorted(Path(".github/workflows").glob("*.y*ml")):
    if not safe_content_file(path.as_posix()):
        continue
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
  safe_files '*.tsv' | xargs -0 /usr/bin/grep -lI --null 'project page' 2>/dev/null \
    | xargs -0 -r perl -pi -e 's/^(\tMIXEL [A-Z][a-z]+ project page\t.*?)getartcraft\.com/$1GitHub/' || exit 1

  # 6. Asset manifests that pin file hashes (ATTRIBUTION.toml): re-pin only the files this
  #    rebrand changed, i.e. where upstream's copy matched the pinned hash. Anything else stays
  #    a real provenance failure for `cargo xtask assets`.
  # Renamed files (step 2) keep their attribution entries: only the app-ID part of paths changes
  # in the manifests; titles, authors and credits stay upstream's.
  safe_files | /usr/bin/grep --null-data -E '(^|/)(ATTRIBUTION[^/]*|ASSETS)\.(toml|md)$|\.attribution$' \
    | xargs -0 /usr/bin/grep -lI --null 'ai\.storyteller\.' 2>/dev/null \
    | xargs -0 -r perl -pi -e 's/ai\.storyteller\.photocraft/ch.mixel.photo/g; s/ai\.storyteller\.vectorcraft/ch.mixel.vector/g; s/ai\.storyteller\.filmcraft/ch.mixel.film/g; s/ai\.storyteller\.lightcraft/ch.mixel.light/g; s/ai\.storyteller\.pdfcraft/ch.mixel.print/g; s/ai\.storyteller\.effectcraft/ch.mixel.effects/g; s/ai\.storyteller\.designcraft/ch.mixel.design/g' || exit 1

  # 7. macOS release artifacts carry the MIXEL name (mixel-photo-<version>-macos-<arch>.dmg).
  #    Other platforms keep upstream's artifact names, which their CI and update feeds expect.
  safe_files packaging/macos | xargs -0 /usr/bin/grep -lI --null -E "$slug(-cli)?-\\\$\\{?VERSION" 2>/dev/null \
    | xargs -0 -r perl -pi -e "s/(?<![A-Za-z0-9_])$slug(-cli)?-(\\\$\\{?VERSION)/mixel-$n\$1-\$2/g" || exit 1

  # 5. README header: what this is and where it comes from.
  python3 -c 'import os,sys; exec(os.environ["REBRAND_BRANDING_PY"]); sys.exit(0 if safe_content_file("README.md") else 1)' || exit 1
  if ! /usr/bin/grep -q 'MIXEL-HEADER' README.md; then
    N="$(printf '%s' "${n:0:1}" | tr '[:lower:]' '[:upper:]')${n:1}"
    { printf '<!-- MIXEL-HEADER -->\n# MIXEL %s\n\n**MIXEL %s** is part of [MIXEL Creative Apps](https://www.mixel.ch).\n\n' "$N" "$N" || exit 1
      # Markdown backticks are literal output, never shell command substitution.
      # shellcheck disable=SC2016
      printf 'Maintained by [MIXEL](https://www.mixel.ch). Based on [storytold/%s](https://github.com/storytold/%s) by Brandon Thomas and contributors; licensed under Apache-2.0 / MIT (see `LICENSE-APACHE`, `LICENSE-MIT`, `NOTICE`). Upstream changes are merged from the `upstream` remote and re-branded with `rebrand.sh`.\n\n---\n\n' "$slug" "$slug" || exit 1
      cat README.md || exit 1; } > README.md.new && mv README.md.new README.md || exit 1
  fi
  # README renders MIXEL identity and retains upstream credits in plain text.
  python3 - <<'PYREADME' || exit 1
from pathlib import Path
import os

exec(os.environ["REBRAND_BRANDING_PY"])
for path in sorted(Path(".").glob("README*.md")):
    if private_source_path(path.as_posix()):
        continue
    if not safe_content_file(path.as_posix()):
        raise SystemExit(f"error: README must be a regular non-symlink file: {path}")
    original = path.read_text()
    updated = transform_readme(original, os.environ["REBRAND_APP"], os.environ["REBRAND_SLUG"], os.environ["REBRAND_FORK"])
    if updated != original:
        path.write_text(updated)

PYREADME

  # Re-pin only after every final content transform, including README cleanup.
  if [ -f ATTRIBUTION.toml ]; then
    python3 - <<'PY' || exit 1
import hashlib, os, re, subprocess, pathlib
exec(os.environ["REBRAND_BRANDING_PY"])
exec(os.environ["REBRAND_METADATA_PY"])
toml = pathlib.Path("ATTRIBUTION.toml")
if not safe_content_file(toml.as_posix()):
    raise SystemExit("error: unsafe attribution input")
text = toml.read_text()
IDS = {"photo": "photocraft", "vector": "vectorcraft", "film": "filmcraft", "light": "lightcraft",
       "print": "pdfcraft", "effects": "effectcraft", "design": "designcraft"}
def upstream_bytes(path):
    if private_source_path(path) or immutable_branding_path(path):
        return None
    path = re.sub(r"ch\.mixel\.([a-z]+)", lambda m: "ai.storyteller." + IDS.get(m.group(1), m.group(1)), path)
    r = subprocess.run(["git", "show", f"upstream/main:{path}"], capture_output=True)
    return r.stdout if r.returncode == 0 else None
def branded_bytes(path, original):
    # Run the same deterministic programs as steps 1/3/4 above. A changed byte
    # outside those transformations must remain a provenance failure.
    parts = pathlib.PurePosixPath(path).parts
    if immutable_branding_path(path) or not parts or b"\0" in original:
        return original
    if re.match(r"(?:LICENSE[^/]*|NOTICE[^/]*|ATTRIBUTION[^/]*|.*\.attribution)$", parts[-1]):
        return original
    workflow = path.startswith(".github/workflows/")
    content_scope = parts[0] in {"apps", "crates", "packaging", "xtask", "assets"} or workflow
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
    if "/" not in path and path.startswith("README") and path.endswith(".md"):
        rules = {}
        exec(os.environ["REBRAND_BRANDING_PY"], rules)
        result = rules["transform_readme"](result.decode("utf-8"), os.environ["REBRAND_APP"],
                                           os.environ["REBRAND_SLUG"], os.environ["REBRAND_FORK"]).encode("utf-8")
    return result
def fix(block):
    m_path = re.search(r'^path = "([^"]+)"', block, re.M); m_sha = re.search(r'^sha256 = "([0-9a-f]{64})"', block, re.M)
    if not (m_path and m_sha): return block
    if immutable_branding_path(m_path.group(1)) or not safe_content_file(m_path.group(1)):
        return block
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

  # No generic UI/legal renaming: unknown upstream UI, locale or web branding
  # must receive an explicit product patch before this generator can succeed.
  python3 - <<'PYBRANDING_CHECK' || exit 1
import os, pathlib, subprocess, sys
exec(os.environ["REBRAND_BRANDING_PY"])
raw = subprocess.run(["git", "ls-files", "-z", "apps", "crates", "assets", "web", "packaging"], capture_output=True, check=True).stdout
source = {}
for value in raw.split(b"\0"):
    if not value:
        continue
    name = os.fsdecode(value)
    if not public_source_path(name):
        continue
    path = pathlib.Path(name)
    if not safe_content_file(name):
        raise SystemExit(f"error: public source must be a regular non-symlink file: {name}")
    source[name] = path.read_text()
found = runtime_branding_matches(source)
for item in found:
    print(f"error: unsupported public branding {item['path']}:{item['line']}: {item['text']}", file=sys.stderr)
if found:
    raise SystemExit(1)
PYBRANDING_CHECK
done
echo "rebrand done"
