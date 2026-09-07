#!/usr/bin/env bash
# tests/preflight.sh — every machine-checkable marketplace and reviewer rule, offline.
#
#   tests/preflight.sh [DIR] [--submission=BODY.md] [--strict] [--marketplace-only]
#
# Mirrors, rule for rule:
#   scripts/build-catalog.mjs               validateManifest / validateManifestFiles /
#                                           validateRepositoryDocs / inspectPluginManifests /
#                                           previewPathFor
#   scripts/submission.mjs                  parseCurrentSubmission (issue body)
#   scripts/security-baseline-scope.mjs     isSecurityScanPath + the four scan limits
#   scripts/security-baseline-analysis.mjs  the 5 findings + the 7 capabilities
#   scripts/security-baseline-policy.mjs    selective enforcement (which findings block)
#   /usr/bin/omarchy-plugin-validate        run directly when present
#   HANCORE-linux's manual review           the demands raised on THIS author twice
#
# Out of scope for an offline run: validate-submission.mjs's assertSubmissionIsUnlisted
# rejects a submission whose repository is already listed, whose plugin id is already
# listed, or whose plugin id was retired by an earlier listing. All three ask the
# marketplace about its own state, which nothing here can see. Check them by hand
# against site/catalog.json and registry.json in omacom/omarchy-plugin-marketplace
# before opening the issue.
#
# WARN never fails the run unless --strict. FAIL always does. No network calls.
# Needs: bash, jq, python3, git, find, grep. Safe in CI.
set -uo pipefail

DIR="."; SUBMISSION=""; STRICT=0; MKT_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --submission=*)     SUBMISSION="${arg#*=}" ;;
    --strict)           STRICT=1 ;;
    --marketplace-only) MKT_ONLY=1 ;;
    -h|--help)          sed -n '2,25p' "$0"; exit 0 ;;
    -*) printf 'preflight: unknown option %s\n' "$arg" >&2; exit 2 ;;
    *)  DIR="$arg" ;;
  esac
done
cd "$DIR" || { printf 'preflight: cannot enter %s\n' "$DIR" >&2; exit 2; }
for t in jq python3 git find grep sed; do
  command -v "$t" >/dev/null 2>&1 || { printf 'preflight: %s is required\n' "$t" >&2; exit 2; }
done

WORK="$(mktemp -d)" || exit 2
trap 'rm -rf "$WORK"' EXIT
FILES="$WORK/files"; LINKS="$WORK/links"; MODES="$WORK/modes"; TALLY="$WORK/tally"
: >"$TALLY"; : >"$MODES"

if [ -t 1 ]; then G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; Z=$'\033[0m'
else G=""; R=""; Y=""; Z=""; fi
pass() { printf '%sPASS%s  %-44s %s\n' "$G" "$Z" "$1" "${2-}"; }
fail() { printf '%sFAIL%s  %-44s %s\n' "$R" "$Z" "$1" "${2-}"; printf 'FAIL\n' >>"$TALLY"; }
warn() { printf '%sWARN%s  %-44s %s\n' "$Y" "$Z" "$1" "${2-}"; printf 'WARN\n' >>"$TALLY"; }
soft() { if [ "$STRICT" -eq 1 ]; then fail "$@"; else warn "$@"; fi; }

# The marketplace reads the pushed git TREE, never the worktree.
if git rev-parse --git-dir >/dev/null 2>&1; then
  git ls-files >"$FILES"
  git ls-files -s | awk -F'\t' '$1 ~ /^120000/ { print $2 }' >"$LINKS"
  # The scan scope admits a file for being mode 100755, and that mode is read off the
  # pushed tree, not off the worktree -- a lost +x bit locally changes nothing there.
  git ls-files -s | awk -F'\t' '{ split($1, m, " "); print m[1] "\t" $2 }' >"$MODES"
  SRC="git tree"
else
  find . -path ./.git -prune -o -type f -print 2>/dev/null | sed 's|^\./||' | LC_ALL=C sort >"$FILES"
  find . -path ./.git -prune -o -type l -print 2>/dev/null | sed 's|^\./||' >"$LINKS"
  SRC="worktree"
fi
printf 'preflight — omarchy marketplace + reviewer rules  (%s, %s files)\n\n' "$SRC" "$(wc -l <"$FILES" | tr -d ' ')"

# ------------------------------------------------ (a) repository layout
echo "-- (a) marketplace validation: repository layout --"
ORIGIN="$(git config --get remote.origin.url 2>/dev/null || true)"
NORM="$(printf '%s' "$ORIGIN" | sed -E 's|^git@github\.com:|https://github.com/|; s|\.git$||; s|/$||')"
if printf '%s' "$NORM" | grep -qE '^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'; then
  pass "submission-repository-invalid" "$NORM"
else
  fail "submission-repository-invalid" "origin must be https://github.com/owner/repo (got '${ORIGIN:-none}')"
fi

if grep -qiE '^readme(\.[^/]+)?$' "$FILES"; then pass "readme-missing" "root README present"
else fail "readme-missing" "A README file is required in the repository root."; fi

if grep -qiE '^(licen[cs]e|copying)(\.[^/]+)?$' "$FILES"; then pass "license-missing" "root license present"
else fail "license-missing" "A license file is required in the repository root."; fi

N_ANY="$(grep -icE '^([^/]+/)?manifest\.json$' "$FILES" || true)"
N_ROOT="$(grep -cE '^manifest\.json$' "$FILES" || true)"
if [ "${N_ANY:-0}" = "1" ] && [ "${N_ROOT:-0}" = "1" ]; then
  pass "unsupported-repository-layout" "exactly one manifest.json, at the root"
else
  fail "unsupported-repository-layout" \
       "New submissions require one plugin with manifest.json in the repository root (any=${N_ANY:-0} root=${N_ROOT:-0})"
fi

# validateManifestFiles: for a ROOT manifest pluginRoot is "" so entries === the
# whole tree. One mode-120000 blob anywhere -- docs/ and tests/ included -- is a
# fatal manifest-invalid, and the security scanner never looks in those dirs.
if [ -s "$LINKS" ]; then
  fail "manifest-invalid/symlinks" "symlinks are not allowed in plugin folders: $(tr '\n' ' ' <"$LINKS")"
else
  pass "manifest-invalid/symlinks" "no mode-120000 entry anywhere in the tree"
fi

if grep -qE '[[:cntrl:]]' "$FILES"; then
  fail "repository/paths" "a tracked path contains a control character"
else
  pass "repository/paths" "every tracked path is plain"
fi
echo

# ------------------------------------------------ (a) manifest contract
echo "-- (a) marketplace validation: manifest contract (community=true) --"
if [ ! -f manifest.json ]; then
  fail "manifest-invalid" "manifest.json is missing"
else
python3 - manifest.json "$FILES" "$TALLY" <<'PY'
import json, re, sys
mpath, flist, tally = sys.argv[1], sys.argv[2], sys.argv[3]
files = set(l for l in open(flist, encoding="utf-8").read().split("\n") if l)
T = open(tally, "a", encoding="utf-8")
def ok(r, n=""): print("PASS  %-44s %s" % (r, n))
def no(r, m):    print("FAIL  %-44s %s" % (r, m)); T.write("FAIL\n")
def wa(r, m):    print("WARN  %-44s %s" % (r, m)); T.write("WARN\n")

try:
    m = json.loads(open(mpath, encoding="utf-8").read())
except Exception as e:
    no("manifest-invalid", "%s: invalid JSON (%s)" % (mpath, e)); T.close(); sys.exit(0)
if not isinstance(m, dict):
    no("manifest-invalid", "manifest must be a JSON object"); T.close(); sys.exit(0)
ok("manifest-invalid/json", "manifest.json parses as an object")

sv = m.get("schemaVersion")
if sv == 1 and not isinstance(sv, bool):
    ok("manifest-invalid/schemaVersion", "schemaVersion is exactly 1")
else:
    no("manifest-invalid/schemaVersion", 'manifest field "schemaVersion" must be exactly 1')

CTRL = re.compile(r"[\x00-\x1f\x7f-\x9f]")
LIM  = [("id",128),("name",120),("version",64),("author",120),("description",500),("license",120)]
probs = []
for f in ("id","name","version","author","description"):
    v = m.get(f)
    if not isinstance(v, str) or not v.strip():
        probs.append('manifest field "%s" is required' % f); continue
    if f == "id" and v != v.strip():
        probs.append('manifest field "id" must not contain leading or trailing whitespace')
    if CTRL.search(v.strip()):
        probs.append('manifest field "%s" contains control characters' % f)
if probs: no("manifest-invalid/required-fields", probs[0])
else:     ok("manifest-invalid/required-fields", "id, name, version, author, description")

# license is OPTIONAL (not in `required`) but has its own control-char + length checks.
lic = m.get("license")
if lic is None:
    ok("manifest-invalid/license", "absent (optional)")
elif not isinstance(lic, str) or not lic.strip():
    no("manifest-invalid/license", 'manifest field "license" must be a non-empty string')
elif CTRL.search(lic.strip()):
    no("manifest-invalid/license", 'manifest field "license" contains control characters')
elif len(lic.strip()) > 120:
    no("manifest-invalid/license", 'manifest field "license" must not exceed 120 characters')
else:
    ok("manifest-invalid/license", lic)

over  = ["%s=%d>%d" % (f, len(m[f].strip()), n) for f, n in LIM
         if isinstance(m.get(f), str) and len(m[f].strip()) > n]
sizes = " ".join("%s=%d/%d" % (f, len(m[f].strip()), n) for f, n in LIM if isinstance(m.get(f), str))
if over: no("manifest-invalid/field-limits", "must not exceed the community limit: " + "; ".join(over))
else:    ok("manifest-invalid/field-limits", sizes)
d = m.get("description")
if isinstance(d, str) and 460 <= len(d.strip()) <= 500:
    wa("manifest/description-headroom", "description is %d/500 -- under 40 chars of headroom" % len(d.strip()))

pid = m.get("id") if isinstance(m.get("id"), str) else ""
if not re.match(r"^[A-Za-z0-9][A-Za-z0-9._-]*$", pid) or ".." in pid:
    no("manifest-invalid/id-charset", "manifest id contains unsupported characters")
elif pid != pid.lower():
    no("manifest-invalid/id-lowercase", "community manifest ids must use lowercase characters")
else:
    ok("manifest-invalid/id-charset", pid)
if pid.lower().startswith("omarchy."):
    no("reserved-plugin-id", "the omarchy.* namespace is reserved")
else:
    ok("reserved-plugin-id", "id is outside the reserved omarchy.* namespace")

KINDS = {"bar","bar-widget","menu","overlay","panel","service"}
kinds = m.get("kinds")
if not isinstance(kinds, list) or not kinds or any(not isinstance(k, str) or k not in KINDS for k in kinds):
    no("manifest-invalid/kinds", 'manifest "kinds" contains unsupported values (allowed: %s)' % sorted(KINDS))
    kinds = []
else:
    ok("manifest-invalid/kinds", ", ".join(kinds))

eps = m.get("entryPoints")
if not isinstance(eps, dict):
    no("manifest-invalid/entryPoints", 'manifest "entryPoints" must be an object'); eps = {}
else:
    ok("manifest-invalid/entryPoints", "entryPoints is an object")

bw = m.get("barWidget")
if isinstance(bw, dict) and "defaultSection" in bw and bw["defaultSection"] not in ("left","center","right"):
    no("manifest-invalid/defaultSection", '"barWidget.defaultSection" must be left, center, or right')
else:
    ok("manifest-invalid/defaultSection",
       bw.get("defaultSection", "absent (optional)") if isinstance(bw, dict) else "no barWidget block")

key = lambda k: "barWidget" if k == "bar-widget" else k
missing = [k for k in kinds if key(k) not in eps]
if missing: no("entry-point-missing/declared", 'entry point for "%s" is missing' % missing[0])
else:       ok("entry-point-missing/declared", "every kind declares its entry point")

vals = list(eps.values())
unsafe = [str(p) for p in vals if not isinstance(p, str) or not p.strip()
          or p.startswith("/") or ".." in p or re.search(r"[\\:\r\n\x00]", p)]
if not vals:  no("manifest-invalid/entry-point-paths", "entry points must be safe relative paths (none declared)")
elif unsafe:  no("manifest-invalid/entry-point-paths", "entry points must be safe relative paths (%s)" % unsafe[0])
else:         ok("manifest-invalid/entry-point-paths", ", ".join(vals))

absent = [p for p in vals if isinstance(p, str) and p not in files]
if absent: no("entry-point-missing/file", "declared entry point is missing: %s" % absent[0])
else:      ok("entry-point-missing/file", "every declared entry point is a blob in the tree")

EXCL = {".github","coverage","docs","fixtures","node_modules","spec","specs","test","tests"}
forced = [p for p in vals if isinstance(p, str) and any(s in EXCL for s in p.split("/")[:-1])]
if forced: no("scan-scope/entry-point-forced",
              "%s sits under a scan-excluded directory and force-includes its path" % forced[0])
else:      ok("scan-scope/entry-point-forced", "no entry point under docs/ tests/ .github/")

if isinstance(bw, dict):
    schema   = bw.get("schema") or []
    defaults = bw.get("defaults") or {}
    sk = sorted(e["key"] for e in schema if isinstance(e, dict) and isinstance(e.get("key"), str))
    if sk != sorted(defaults.keys()):
        no("manifest/schema-defaults", "schema keys and barWidget.defaults disagree")
    else:
        ok("manifest/schema-defaults", "%d settings, keys and defaults agree" % len(sk))
    bad = [e.get("key") for e in schema if isinstance(e, dict)
           and not all(k in e for k in ("key","type","label","defaultValue"))]
    if bad: no("manifest/schema-complete", "setting %s lacks key/type/label/defaultValue" % bad[0])
    else:   ok("manifest/schema-complete", "every setting has key, type, label, defaultValue")
T.close()
PY
fi
echo

# ------------------------------------------------ (a) optional preview
echo "-- (a) marketplace validation: optional root preview --"
# previewPathFor does not take the alphabetically first root candidate: it sorts them
# against a fixed format priority, so a repository shipping both preview.png and
# preview.jpg is listed with the png. Ties within one format fall back to sort order.
PREVIEW=""
for ext in png webp jpg jpeg avif; do
  [ -n "$PREVIEW" ] && continue
  PREVIEW="$(grep -iE "^preview\.$ext\$" "$FILES" | LC_ALL=C sort | head -1 || true)"
done
if [ -z "$PREVIEW" ]; then
  soft "preview-absent" "no root preview -- the bot prints the fallback notice, not an error"
else
python3 - "$PREVIEW" "$TALLY" <<'PY'
import os, struct, sys
p, tally = sys.argv[1], sys.argv[2]
T = open(tally, "a", encoding="utf-8")
size = os.path.getsize(p); BYTE, PIX = 50*1024*1024, 40000000
# Far more than a header needs, but an AVIF's ispe sits behind a whole meta box.
d = open(p, "rb").read(65536); w = h = 0
if d[:8] == b"\x89PNG\r\n\x1a\n" and d[12:16] == b"IHDR":
    w, h = struct.unpack(">II", d[16:24])
elif d[:4] == b"RIFF" and d[8:12] == b"WEBP":
    # Three WebP dialects share one container. Reading only the extended VP8X form
    # blinds the check to every plain lossy and lossless preview sharp accepts.
    if d[12:16] == b"VP8X":
        w = int.from_bytes(d[24:27], "little") + 1; h = int.from_bytes(d[27:30], "little") + 1
    elif d[12:16] == b"VP8 " and d[23:26] == b"\x9d\x01\x2a":
        w = int.from_bytes(d[26:28], "little") & 0x3fff
        h = int.from_bytes(d[28:30], "little") & 0x3fff
    elif d[12:16] == b"VP8L" and d[20:21] == b"\x2f":
        bits = int.from_bytes(d[21:25], "little")
        w = (bits & 0x3fff) + 1; h = ((bits >> 14) & 0x3fff) + 1
elif d[4:8] == b"ftyp":
    # An AVIF carries one ispe per item -- the primary image, then any alpha plane or
    # thumbnail. Take the largest, so the pixel budget is never under-reported.
    i = d.find(b"ispe")
    while i > 0:
        aw = int.from_bytes(d[i+8:i+12], "big"); ah = int.from_bytes(d[i+12:i+16], "big")
        if aw * ah > w * h: w, h = aw, ah
        i = d.find(b"ispe", i + 4)
elif d[:2] == b"\xff\xd8":
    f = open(p, "rb"); f.seek(2)
    while True:
        b = f.read(1)
        if not b: break
        if b != b"\xff": continue
        mk = f.read(1)
        if mk in (b"\xc0",b"\xc1",b"\xc2",b"\xc3",b"\xc5",b"\xc6",b"\xc7",b"\xc9",b"\xca",b"\xcb"):
            f.read(3); h, w = struct.unpack(">HH", f.read(4)); break
        ln = f.read(2)
        if len(ln) < 2: break
        f.seek(struct.unpack(">H", ln)[0] - 2, 1)
note = "%s %dB %dx%d" % (p, size, w, h)
if size < 1 or size > BYTE or (w and h and w * h > PIX):
    print("FAIL  %-44s %s exceeds the 50MB / 40MP limit" % ("preview-invalid", note)); T.write("FAIL\n")
elif not (w and h):
    # validatePreviewMetadata demands a width and a height of at least 1, so a header
    # this parser could not read is an open question and must not be reported as 0x0
    # within the limits -- the one shape of answer that is certainly wrong.
    print("WARN  %-44s %s header unread; confirm the 40MP limit by hand" % ("preview-invalid", note))
    T.write("WARN\n")
else:
    print("PASS  %-44s %s within 50MB / 40MP" % ("preview-invalid", note))
    if w < 1600:
        print("WARN  %-44s long edge %d < 1600; withoutEnlargement leaves it small" % ("preview-small", w))
        T.write("WARN\n")
T.close()
PY
fi
echo

# ------------------------------------------------ (b) security baseline
echo "-- (b) automated security baseline (scope, limits, findings, capabilities) --"
python3 - "$FILES" "$MODES" "$TALLY" "$STRICT" <<'PY'
import json, os, re, sys
flist, mlist, tally, strict = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == "1"
files = [l for l in open(flist, encoding="utf-8").read().split("\n") if l]
MODES = dict(l.split("\t", 1)[::-1] for l in open(mlist, encoding="utf-8").read().split("\n") if "\t" in l)
def mode_of(p):
    # Outside a checkout there is no index to read, so fall back to the bit on disk.
    return MODES.get(p) or ("100755" if os.access(p, os.X_OK) else "100644")
T = open(tally, "a", encoding="utf-8")
def ok(r, n=""): print("PASS  %-44s %s" % (r, n))
def no(r, m):    print("FAIL  %-44s %s" % (r, m)); T.write("FAIL\n")
def wa(r, m):    print("WARN  %-44s %s" % (r, m)); T.write("WARN\n")
def soft(r, m):  (no if strict else wa)(r, m)

EXCL = {".github","coverage","docs","fixtures","node_modules","spec","specs","test","tests"}
SCANNED = {".bash",".cjs",".desktop",".fish",".js",".lua",".mjs",".pl",".py",".qml",".rb",
           ".service",".sh",".sudoers",".toml",".yaml",".yml",".zsh"}
# isBinaryAssetPath exempts images and nothing else. An archive, a font or a video is
# not exempt at all -- it simply is not a scanned extension, which the clauses below
# already settle, and widening this set silently drops files upstream still reads.
ASSET = {".apng",".avif",".bmp",".gif",".heic",".heif",".ico",".jfif",".jpe",".jpeg",
         ".jpg",".jxl",".png",".tif",".tiff",".webp"}
# Two readings of one name. setupLikeBasename is an unanchored substring match, so
# preinstall.sh and reinstall-notes are setup-named to the scanner; the anchored form
# is the narrower one, kept where a false hit would invent a runtime or a capability
# the reviewer would then have to be argued out of.
SETUP       = re.compile(r"(?:^|[-_])(install|installer|setup|uninstall)(?:[-_.]|$)", re.I)
SETUP_LOOSE = re.compile(r"install|installer|setup|uninstall", re.I)

def is_root_readme(p):
    return "/" not in p and re.match(r"^readme(\.[^/]+)?$", p, re.I) is not None
def extof(b):
    i = b.rfind(".")
    return b[i:].lower() if i > 0 else ""
def is_scan_path(p):
    if is_root_readme(p): return True
    parts = p.lower().split("/")
    if any(x in EXCL for x in parts[:-1]): return False
    b = parts[-1]; e = extof(b)
    # resolveSecuritySnapshot drops an excluded directory FIRST and only then admits a
    # blob for being executable or extensionless, so neither clause can drag docs/ or
    # tests/ back into the scan. Order matters here; the union below does not.
    if mode_of(p) == "100755": return True
    if "." not in b: return True
    if e in SCANNED: return True
    if e in ASSET:   return False
    if parts[0] in ("bin", "scripts"): return "." not in b
    return SETUP_LOOSE.search(b) is not None

FORCED = set()
try:
    mf = json.load(open("manifest.json", encoding="utf-8"))
    FORCED = {v for v in (mf.get("entryPoints") or {}).values() if isinstance(v, str)}
except Exception:
    pass

# A declared entry point is forced in even from an excluded directory; everything else
# has already been through the exclusion inside is_scan_path.
scanned = [p for p in files if p in FORCED or is_scan_path(p)]
ok("scan-scope", "%d scanned: %s" % (len(scanned), ", ".join(sorted(scanned)[:8])))

FILE_LIMIT, TOTAL_LIMIT, PER_FILE, PROBE = 1000, 8*1024*1024, 512*1024, 4096
sizes = dict((p, os.path.getsize(p) if os.path.exists(p) else 0) for p in scanned)
# readSnapshotFile lets an oversized mode-100755 blob through on a 4096-byte probe of
# its magic instead of refusing the scan, and declaredTextSize then charges the budget
# that probe rather than the blob -- so a committed binary cannot exhaust the 8 MiB.
charged = dict((p, PROBE if (s > PER_FILE and mode_of(p) == "100755") else s)
               for p, s in sizes.items())
big   = [p for p, s in sizes.items() if s > PER_FILE and mode_of(p) != "100755"]
total = sum(charged.values())
(ok if len(scanned) <= FILE_LIMIT else no)(
    "security-baseline-scan-limit/files", "%d relevant files (limit %d)" % (len(scanned), FILE_LIMIT))
(ok if total <= TOTAL_LIMIT else no)(
    "security-baseline-scan-limit/bytes", "%d B relevant text (limit %d)" % (total, TOTAL_LIMIT))
(ok if not big else no)(
    "security-baseline-scan-limit/per-file",
    ("largest %d B charged (limit %d)" % (max(charged.values()) if charged else 0, PER_FILE)) if not big
    else "%s exceeds 512 KiB" % big[0])
setup_bin = [p for p in files if extof(p.split("/")[-1]) in ASSET
             and SETUP_LOOSE.search(p.split("/")[-1])
             and not any(s in EXCL for s in p.lower().split("/")[:-1])]
(ok if not setup_bin else no)(
    "security-baseline-unavailable/setup-asset",
    "no setup-named binary asset" if not setup_bin
    else "a complete setup-named binary asset cannot be excluded: %s" % setup_bin[0])

INTERP = (r"(?:bash|sh|zsh|dash|ash|ksh|fish|python(?:[23](?:\.[0-9]+)?)?"
          r"|node|ruby|perl|php|java|deno|dotnet)")
FENCE_OPEN = re.compile(r"^ {0,3}(`{3,}|~{3,})\s*(?:(?:ba|z|fi|da|a|k)?sh|shell)\s*$", re.I)
FENCE_SKIP = re.compile(r"\b(development|contributing|contributors?|testing|tests?)\b", re.I)

def read(p):
    try: return open(p, encoding="utf-8", errors="replace").read()
    except Exception: return ""
def is_shell_runtime(p):
    b = p.split("/")[-1]
    if re.search(r"\.(ba|z|fi)?sh$", b, re.I): return True
    if "." not in b and re.match(r"^(bin|scripts)/", p, re.I): return True   # bin/agent-skills
    if SETUP.search(b) and not re.search(r"\.(md|json)$", b, re.I): return True
    return False
def units(p):
    """(label, text, runtime). The raw file, plus each TAGGED root-README fence."""
    text = read(p)
    execish = os.access(p, os.X_OK) or bool(
        re.search(r"^#!.*\b(sh|bash|zsh|dash|ash|ksh|fish)\b", text, re.M))
    out = [(p, text, is_shell_runtime(p) or execish or p in FORCED)]
    if not is_root_readme(p): return out
    lines = text.split("\n"); sec = ""; para = []; prev = []; i = 0
    while i < len(lines):
        hd = re.match(r"^ {0,3}#{1,6}\s+(.+)$", lines[i])
        if hd:
            sec = hd.group(1).strip().lower(); para = []; prev = []; i += 1; continue
        opn = FENCE_OPEN.match(lines[i])
        if not opn:
            if lines[i].strip(): para.append(lines[i])
            elif para: prev, para = para, []
            else: prev = []
            i += 1; continue
        mark, n, body = opn.group(1)[0], len(opn.group(1)), []
        i += 1
        while i < len(lines):
            cl = re.match(r"^ {0,3}(`{3,}|~{3,})\s*$", lines[i])
            if cl and cl.group(1)[0] == mark and len(cl.group(1)) >= n: break
            body.append(lines[i]); i += 1
        if not FENCE_SKIP.search(sec + "\n" + "\n".join(para or prev)):
            out.append((p + " (tagged shell fence)", "\n".join(body), True))
        para, prev = [], []; i += 1
    return out

CURL_PIPE = re.compile(r"\b(?:curl|wget)\b[^\n|]*\|\s*(?:sudo\s+|env\s+\S+=\S+\s+)*(?:/\S*/)?"
                       + INTERP + r"\b", re.I)
PROC_SUB  = re.compile(r"(?:(?:ba|z|fi|da|a|k)?sh|source|\.)\s+(?:<\s*)?<\(\s*(?:curl|wget)\b", re.I)
CMD_SUB   = re.compile(r"(?:eval\s+|(?:ba|z|fi|da|a|k)?sh\s+-c\s+)[\"']?\$\(\s*(?:curl|wget)\b", re.I)
CARGO_GIT = re.compile(r"\bcargo\s+(?:\+\S+\s+)?install\b[^\n]*\s--git(?:\s|=)", re.I)
REV_PIN   = re.compile(r"--rev(?:\s+|=)[\"']?[a-f0-9]{40}[\"']?", re.I)
GIT_ACQ   = re.compile(r"\bgit\s+(?:-C\s+\S+\s+)?(?:clone|fetch|pull)\b", re.I)
EXEC_SINK = re.compile(r"\b(?:make|gmake|cmake|ninja|meson|gradle|gradlew|mvn|go|cargo|npm|pnpm"
                       r"|yarn|bun|" + INTERP + r")\b|(?:^|\s)\./\S+", re.I)
SHA_PIN   = re.compile(r"\bgit\s+(?:-C\s+\S+\s+)?(?:checkout|reset|switch)\b[^\n]*\b[a-f0-9]{40}\b", re.I)
NOPASSWD  = re.compile(r"\bNOPASSWD\s*:", re.I)
DANGEROUS = re.compile(r"\bNOPASSWD\s*:\s*(?:ALL|/[^\s,]*(?:\*|\?|\[)"
                       r"|/[^\s,]*/(?:kill|pkill|systemctl|systemd-run|rm|mv|cp|install|tee|chmod"
                       r"|chown|mount|umount|wg-quick|sudo|su|env|busybox|toybox|sh|bash|zsh|fish"
                       r"|dash|ash|ksh|perl|ruby|node|php|deno|java|dotnet|python[0-9.]*)\s*$)", re.I)
TMP_PID   = re.compile(r"/tmp/[^\s\"']*\.?pid\b", re.I)
PRIV_KILL = re.compile(r"\b(?:sudo|pkexec)\b[^\n]*\b(?:kill|pkill|renice|systemctl)\b", re.I)
SUDOERS_F = re.compile(r"(?:^|/)(?:sudoers(?:\.d)?(?:/|$)|[^/]+\.sudoers$)", re.I)

hits = dict((k, []) for k in ("curl-pipe-shell","cargo-git-unpinned","remote-git-execution-unpinned",
                              "sudoers-dangerous-passwordless-command",
                              "privileged-process-control-from-shared-temp"))
for p in scanned:
    for label, text, runtime in units(p):
        lines = text.split("\n")
        # dangerousPasswordlessSudoersFindings runs OUTSIDE the runtime gate:
        # raw README prose counts, under any heading.
        if SUDOERS_F.search(p) or NOPASSWD.search(text):
            for i, ln in enumerate(lines, 1):
                if DANGEROUS.search(ln):
                    hits["sudoers-dangerous-passwordless-command"].append(
                        "%s:%d: %s" % (label, i, ln.strip()[:78]))
        if not runtime: continue
        pending = None
        for i, ln in enumerate(lines, 1):
            s = re.sub(r"\s+#.*$", "", ln).strip()
            if not s: continue
            if CURL_PIPE.search(s) or PROC_SUB.search(s) or CMD_SUB.search(s):
                hits["curl-pipe-shell"].append("%s:%d: %s" % (label, i, s[:78]))
            if CARGO_GIT.search(s) and not REV_PIN.search(s):
                hits["cargo-git-unpinned"].append("%s:%d: %s" % (label, i, s[:78]))
            if GIT_ACQ.search(s):
                pending = (i, s)
            elif pending and SHA_PIN.search(s):
                pending = None
            elif pending and EXEC_SINK.search(s):
                hits["remote-git-execution-unpinned"].append(
                    "%s:%d -> :%d %s" % (label, pending[0], i, s[:58])); pending = None
            if TMP_PID.search(s):
                for j in range(i - 1, min(i + 11, len(lines))):
                    if PRIV_KILL.search(lines[j]):
                        hits["privileged-process-control-from-shared-temp"].append(
                            "%s:%d: %s" % (label, i, s[:78])); break

BLOCKING = set(["sudoers-dangerous-passwordless-command",
                "privileged-process-control-from-shared-temp"])
for rule in sorted(hits):
    ev  = hits[rule]
    tag = "BLOCKS LISTING" if rule in BLOCKING else "maintainer-acceptable"
    if not ev:                 ok("finding/" + rule, "no match (%s)" % tag)
    elif rule in BLOCKING:     no("finding/" + rule, "[%s] %d hit(s); first: %s" % (tag, len(ev), ev[0]))
    else:                      soft("finding/" + rule, "[%s] %d hit(s); first: %s" % (tag, len(ev), ev[0]))

PKG = re.compile(r"\bomarchy\s+pkg\s+(?:add|drop|remove|update)\b"
                 r"|\b(?:pacman|paru|yay|apt|apt-get|dnf|zypper|apk)\s+"
                 r"(?:-[A-Za-z]*[SRU]|install|remove|upgrade|add|del)\b"
                 r"|(?:^|[\s/'\"])(?:pip|pip3|pipx)[\"']?\s+install\b"
                 r"|\bpython[23]?(?:\.[0-9]+)?\s+-m\s+pip\s+install\b"
                 r"|\b(?:npm|pnpm|yarn|bun)\s+(?:install|add)\b"
                 r"|\bcargo\s+install\b|\bgo\s+install\b|\bgem\s+install\b"
                 r"|\bbrew\s+(?:install|uninstall|upgrade)\b", re.I)
PRIV = re.compile(r"\b(?:sudo|pkexec)\b")
# The documented negation demands the BARE verb: "It never uses sudo." TRIPS IT.
NEG  = re.compile(r"\b(?:does\s+not|doesn't|do\s+not|don't|never)\s+(?:use|run|invoke|require|need)\s+"
                  r"|\bno\s+sudo\b(?:\s+or\s+pkexec)?\s+is\s+(?:required|needed)\b"
                  r"|\bwithout\s+sudo\b|\bsudo\s+is\s+not\s+(?:used|required)\b", re.I)
SVC     = re.compile(r"\bsystemctl\b|\bsystemd-run\b")
SUDOERS = re.compile(r"/etc/sudoers(?:\.d)?(?:/|\b)|\bvisudo\b|\bSUDOERS(?:_FILE)?\s*=", re.I)
REMOTE  = re.compile(r"\bgit\s+(?:clone|fetch|pull)\b|\bcurl\b|\bwget\b", re.I)

caps = {}
def add(c, w): caps.setdefault(c, []).append(w)
for p in files:
    if any(s in EXCL for s in p.lower().split("/")[:-1]): continue
    if SETUP.search(p.split("/")[-1]):   add("installer", p)
    if p.lower().endswith(".service"):   add("service-management", p)
for p in scanned:
    for label, text, _ in units(p):
        for i, ln in enumerate(text.split("\n"), 1):
            where = "%s:%d: %s" % (label, i, ln.strip()[:66])
            if PKG.search(ln):                          add("package-manager", where)
            if PRIV.search(ln) and not NEG.search(ln):  add("privilege", where)
            if SVC.search(ln):                          add("service-management", where)
            if SUDOERS.search(ln):                      add("sudoers-modification", where)
            if REMOTE.search(ln):                       add("remote-build", where)
for p in scanned:
    if not os.access(p, os.X_OK): continue
    try: head = open(p, "rb").read(4)
    except Exception: continue
    if head[:4] == b"\x7fELF" or head[:2] == b"MZ" or head[:4] in (b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf"):
        add("bundled-executable-binary", p)

if not caps:
    ok("security-baseline-outcome", "passed -- zero findings, zero capabilities (automatic-Verified shape)")
else:
    no("security-baseline-capabilities",
       "outcome downgrades to review-required: " + ", ".join("%s(%d)" % (k, len(caps[k])) for k in sorted(caps)))
    for k in sorted(caps): print("        %-28s %s" % (k, caps[k][0]))

# A '## Development' heading exempts only fence-derived FINDINGS and the
# segment-based remote-build detector -- never the capability loop above.
for p in files:
    if not is_root_readme(p): continue
    tagged = [i for i, l in enumerate(read(p).split("\n"), 1) if FENCE_OPEN.match(l)]
    if tagged:
        soft("readme/tagged-shell-fence",
             "line %d opens a ```sh fence -- it becomes a synthetic mode-100755 file" % tagged[0])
    else:
        ok("readme/tagged-shell-fence", "all code fences untagged; none expanded into shell")
T.close()
PY
echo

# ------------------------------------------------ (c) reviewer bar
if [ "$MKT_ONLY" -eq 0 ]; then
echo "-- (c) reviewer bar: helper I/O and bounds (HANCORE-linux) --"
H="bin/agent-skills"
if [ ! -f "$H" ]; then
  warn "helper/present" "$H not found -- skipping reviewer checks"
else
  if grep -q 'O_NOFOLLOW' "$H" && grep -q 'O_NONBLOCK' "$H" && grep -q 'fstat' "$H"; then
    pass "helper/one-open-descriptor-decisions" "O_NOFOLLOW|O_NONBLOCK + fstat present"
  else
    fail "helper/one-open-descriptor-decisions" "open once no-follow/nonblocking and decide on the descriptor"
  fi
  if grep -q 'st_nlink' "$H"; then pass "helper/single-link-leaf" "st_nlink checked"
  else fail "helper/single-link-leaf" "no link-count check -- 'owner/type/link count/size' (#4252, #1441, #4033)"; fi
  if grep -q 'S_IWOTH' "$H"; then pass "helper/world-writable-refusal" "S_IWOTH checked"
  else fail "helper/world-writable-refusal" "no world-writable refusal on inputs"; fi
  if grep -q 'st_size' "$H" && grep -qE 'while .*(remaining|left|size)' "$H"; then
    pass "helper/read-to-st_size" "bounded read loop to st_size"
  else
    fail "helper/read-to-st_size" "single os.read() -- a short read yields a prefix parsed as a whole document"
  fi
  if grep -q 'RecursionError' "$H"; then pass "helper/deep-json-guard" "RecursionError handled"
  else fail "helper/deep-json-guard" "read_json catches only JSONDecodeError; deep nesting exits 1 with no stdout"; fi
  if grep -qE 'def +(as_dict|dict_items)\(' "$H"; then pass "helper/typed-config-walk" "typed config walk present"
  else fail "helper/typed-config-walk" '(x or {}) does not guard a non-empty str/list -- AttributeError on {"mcp":{"a":"s"}}'; fi
  if grep -qE 'MAX_OUTPUT|def +emit\(' "$H"; then pass "helper/producer-side-output-cap" "output ceiling present"
  else fail "helper/producer-side-output-cap" "json.dump goes straight to stdout with no byte ceiling"; fi
  if grep -qE 'MAX_DIR_ENTRIES|class +Budget' "$H"; then pass "helper/deadline-and-budgets" "scan budget present"
  else fail "helper/deadline-and-budgets" "no wall-clock deadline, no directory-entry budget"; fi
  if grep -qE 'def +redact|<redacted>' "$H"; then pass "helper/mcp-redaction" "MCP target redaction present"
  else fail "helper/mcp-redaction" "MCP command lines and URLs emitted verbatim (:578 :589 :599)"; fi
  if grep -qE '/tmp/' "$H"; then
    fail "helper/no-shared-temp" "a /tmp path in the helper risks privileged-process-control-from-shared-temp"
  else
    pass "helper/no-shared-temp" "no /tmp path"
  fi
  NSCAN="$(grep -c 'os\.scandir' "$H" || true)"
  NGUARD="$(grep -c 'except OSError' "$H" || true)"
  if [ "${NSCAN:-0}" -le "${NGUARD:-0}" ]; then
    pass "helper/scandir-guarded" "${NSCAN:-0} scandir call(s), ${NGUARD:-0} OSError guard(s)"
  else
    fail "helper/scandir-guarded" "${NSCAN:-0} scandir call(s) but only ${NGUARD:-0} OSError guard(s)"
  fi
  if head -1 "$H" | grep -q '^#!/usr/bin/env '; then
    soft "helper/path-resolved-interpreter" "#!/usr/bin/env -- the QML must still spawn /usr/bin/python3 explicitly"
  else
    pass "helper/path-resolved-interpreter" "absolute interpreter in the shebang"
  fi
fi
for t in mkfifo st_nlink RecursionError; do
  if [ -d tests ] && grep -rqs -- "$t" tests; then pass "tests/adversarial-$t" "covered"
  else soft "tests/adversarial-$t" "no regression test for this case"; fi
done
echo

echo "-- (c) reviewer bar: QML --"
QML_N=0
QML_LIST="$(grep -E '\.qml$' "$FILES" || true)"
while IFS= read -r q; do
  [ -n "$q" ] && [ -f "$q" ] || continue
  QML_N=$((QML_N + 1))
  TN="$(grep -cE '^[[:space:]]*(Text|Label)[[:space:]]*\{' "$q" || true)"
  FN="$(grep -c 'textFormat:' "$q" || true)"
  if [ "${TN:-0}" -le "${FN:-0}" ]; then
    pass "qml/plaintext $q" "${TN:-0} Text/Label vs ${FN:-0} textFormat"
  else
    fail "qml/plaintext $q" "${TN:-0} Text/Label but only ${FN:-0} textFormat -- the most-cited manual finding"
  fi
  if grep -qE 'command:[[:space:]]*\[[[:space:]]*"(bash|sh|python3?|timeout|setsid|env|node)"' "$q"; then
    fail "qml/absolute-interpreter $q" "Process.command starts with a PATH-resolved name (#4331, #3930)"
  else
    pass "qml/absolute-interpreter $q" "no PATH-resolved argv[0]"
  fi
  if grep -qE '"[^"]*\b(curl|wget|git|cargo)\b[^"]*"' "$q"; then
    fail "qml/literal-launcher $q" "a string literal carries curl/wget/git/cargo -- literalLauncherFiles() scans it"
  else
    pass "qml/literal-launcher $q" "no curl/wget/git/cargo in any string literal"
  fi
  # QML reserves a leading capital for type names and refuses to declare such a
  # property at all. That is not a style warning: the declaration is an error,
  # the error aborts the whole document, and the component never compiles -- so
  # a lazily-loaded Panel.qml silently becomes a null Loader item and the widget
  # opens nothing. It cost a full debugging session to find, because the only
  # symptom is a WARN line in the shell journal and a mark that takes its click
  # and does nothing. Cheap to check, impossible to see by reading.
  if grep -qE '^[[:space:]]*(readonly[[:space:]]+)?property[[:space:]]+[A-Za-z_][A-Za-z0-9_<>]*[[:space:]]+[A-Z]' "$q"; then
    fail "qml/property-case $q" "a property name begins with a capital -- QML refuses it and the file will not compile"
  else
    pass "qml/property-case $q" "no property name begins with a capital"
  fi
done <<EOF
$QML_LIST
EOF
# /usr/bin/qmllint is Qt5's v1.0 on Omarchy, and it is useless as a gate twice over:
# it writes every diagnostic to journald rather than to stdout, so a grep over its
# output can never match whatever it found, and its parser predates typed function
# signatures, so it calls `function open(): void` a syntax error in a file Qt6 accepts.
# Only a Qt6 binary is worth believing. Gate on its exit status, which is the one
# signal the journald redirection cannot swallow: Qt6 exits non-zero on an error and
# zero on warnings, so the unresolved qs.* imports on a machine without Quickshell
# installed stay warnings and no allowlist is needed to keep the gate usable.
QLINT=""
if [ -x /usr/lib/qt6/bin/qmllint ]; then
  QLINT=/usr/lib/qt6/bin/qmllint
elif command -v qmllint >/dev/null 2>&1 \
  && qmllint --version 2>&1 | grep -qE 'qmllint ([6-9]|[1-9][0-9])\.'; then
  QLINT="$(command -v qmllint)"
fi
QINC=""
[ -d /usr/share/omarchy/shell ] && QINC="-I /usr/share/omarchy/shell"
if [ "$QML_N" -eq 0 ]; then
  warn "qml/present" "no .qml file in the tree yet"
elif [ -z "$QLINT" ]; then
  warn "qml/qmllint" "no Qt6 qmllint found -- install qt6-declarative to run this gate"
else
  # Lint a copy under a neutral name, in a directory holding nothing else. A QML file
  # is implicitly a component named after itself, so Panel.qml, whose root element is
  # the imported Panel, resolves that name back to itself through the directory
  # import -- and on a document this size 6.11.2 never comes back from it. The same
  # bytes named Subject.qml finish in two seconds. Both of this repository's entry points
  # are written that way on purpose and both run, so the cycle qmllint sees is an
  # artifact of resolving qs.Ui here, not a defect, and giving it up costs the gate
  # nothing it was asked to find: whether the document itself compiles.
  mkdir -p "$WORK/qml"; QB="$WORK/qml/Subject.qml"
  while IFS= read -r q; do
    [ -n "$q" ] && [ -f "$q" ] || continue
    cp "$q" "$QB"
    # A file that wedges the parser anyway must not wedge CI with it, and a run that
    # never finished is an unread verdict rather than a broken document, so it warns.
    timeout 60 "$QLINT" $QINC "$QB" >"$WORK/qmllint" 2>&1; QRC=$?
    QN="$(grep -c '^Warning:' "$WORK/qmllint" || true)"
    if [ "$QRC" -eq 0 ]; then
      pass "qml/qmllint $q" "compiles; ${QN:-0} warning(s)"
    elif [ "$QRC" -eq 124 ]; then
      warn "qml/qmllint $q" "qmllint did not finish within 60s -- verdict unknown"
    else
      # Qt6 prints its diagnostics on stdout, so quoting the first one names the defect.
      # A build that routed them elsewhere would leave the line blank, and a FAIL with no
      # reason on it is the same unread verdict as a grep that never matches, so fall
      # back to the exit status -- the signal that arrives either way.
      QMSG="$(grep -m1 -E '^(Warning|Error):' "$WORK/qmllint" | sed "s|$QB|$q|")"
      fail "qml/qmllint $q" "${QMSG:-exit $QRC}"
    fi
  done <<EOF
$QML_LIST
EOF
fi
if command -v omarchy-plugin-validate >/dev/null 2>&1; then
  if omarchy-plugin-validate . >/dev/null 2>"$WORK/opv"; then
    pass "omarchy-plugin-validate" "exit 0"
  else
    fail "omarchy-plugin-validate" "$(head -1 "$WORK/opv")"
  fi
fi
echo
fi

# ------------------------------------------------ (d) README and packaging
echo "-- (d) README and packaging --"
RM="$(grep -iE '^readme(\.[^/]+)?$' "$FILES" | head -1 || true)"
if [ -z "$RM" ] || [ ! -f "$RM" ]; then
  warn "readme/present" "no root README to inspect"
else
  if grep -qiE '^#+[[:space:]]+(install|installation)' "$RM"; then
    pass "readme/install-section" "install instructions present"
  else
    fail "readme/install-section" "checklist item 1 attests to installation AND removal instructions"
  fi
  if grep -qiE '^#+[[:space:]]+(remove|removal|uninstall)' "$RM"; then
    pass "readme/removal-section" "removal instructions present"
  else
    fail "readme/removal-section" "checklist item 1 attests to installation AND removal instructions"
  fi
  if grep -qiE 'dependenc|requirement|python3' "$RM"; then
    pass "readme/dependencies" "dependencies documented"
  else
    fail "readme/dependencies" "checklist item 2 attests that dependencies are documented"
  fi
  if grep -qiE 'licen[cs]e' "$RM"; then pass "readme/license-stated" "license named in the README"
  else fail "readme/license-stated" "checklist item 2 attests that the license is documented"; fi
  if grep -qiE 'not (yet )?(installable|built|usable)|nothing is installable|not built yet|^#+[[:space:]]*status' "$RM"; then
    fail "readme/manual-setup-bait" "a 'Status: Early / not installable' section invites manual-setup or a decline"
  else
    pass "readme/manual-setup-bait" "nothing in the README says the plugin does not install"
  fi
  if grep -qiE '\b(verified|audited|security[- ]reviewed)\b' "$RM"; then
    soft "readme/no-verification-claims" "AGENTS.md forbids describing listing approval as a security review"
  else
    pass "readme/no-verification-claims" "no verification or audit claim"
  fi
  MNAME="$(jq -r '.name // empty' manifest.json 2>/dev/null || true)"
  if [ -n "$MNAME" ] && ! grep -qF -- "$MNAME" "$RM"; then
    soft "readme/name-agrees-with-manifest" "README never says \"$MNAME\" -- two names for one plugin"
  else
    pass "readme/name-agrees-with-manifest" "${MNAME:-n/a}"
  fi
fi

# ------------------------------------------------ submission issue body
if [ -n "$SUBMISSION" ]; then
  echo
  echo "-- submission issue body (scripts/submission.mjs) --"
python3 - "$SUBMISSION" "$TALLY" <<'PY'
import re, sys
body = open(sys.argv[1], encoding="utf-8").read()
T = open(sys.argv[2], "a", encoding="utf-8")
def ok(r, n=""): print("PASS  %-44s %s" % (r, n))
def no(r, m):    print("FAIL  %-44s %s" % (r, m)); T.write("FAIL\n")

HEAD = ["Repository URL","Category","Tags","Suggest a missing tag",
        "Maintainer notes","Submission checklist"]
CATS = ["Appearance","Desktop","Developer Tools","Hardware","Kids",
        "Productivity","System","Widgets","Other"]
TAGS = ["ai","bar","education","games","hyprland","kids","launcher","media",
        "power-management","quickshell","security","system","workspaces"]
ALIAS = set(["autohide","bar-widget","battery","command-palette","coming-soon","dell","dev",
             "firmware","hardware","hardware-control","laptop","music","ollama","omarchy",
             "overlay","overviews","plugin","power-profiles","previews","quickapps",
             "search","screenshot","shell-suite","sidebar","system-monitoring","updates",
             "visualizer"])
# The three aliases that map to null rather than to a tag. They are accepted on the
# way in and then vanish, which is why the count has to be taken twice.
DROPPED = set(["coming-soon","omarchy","plugin"])
CHECK = ["The repository is public and contains installation and removal instructions.",
         "I have documented the plugin license and any external dependencies.",
         "I confirm that I own or have permission to submit this plugin and its preview assets.",
         "The plugin does not overwrite user configuration without explicit consent.",
         "I understand that approval is for listing and is not a security review."]

first = body.split("\n", 1)[0].strip()
title = first[6:].strip() if first.lower().startswith("title:") else first
if re.match(r"^\[Plugin\]:\s*\S", title):
    ok("submission-title-invalid", title[:54])
else:
    no("submission-title-invalid",
       'title must match /^\\[Plugin\\]:\\s*\\S/ (put it on line 1 as "Title: [Plugin]: Name")')

# reservedSections() filters to the six reserved headings; others are ignored.
marks = [(m.group(1), m.start(), m.end())
         for m in re.finditer(r"^###\s+(.+?)\s*$", body, re.M) if m.group(1) in HEAD]
names = [h for h, _, _ in marks]
dup = [h for h in names if names.count(h) > 1]
if dup:
    no("submission-field-repeated", 'Submission repeats the "%s" field' % dup[0])
elif names == HEAD:
    ok("submission-fields-invalid", "all six reserved headings, in order")
else:
    no("submission-fields-invalid", "headings must be exactly %s (got %s)" % (", ".join(HEAD), names))

sec = {}
for i, (h, s, e) in enumerate(marks):
    sec[h] = body[e: marks[i+1][1] if i+1 < len(marks) else len(body)].strip()

repo = sec.get("Repository URL", "")
if re.match(r"^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:\.git)?$", repo):
    ok("submission-repository-invalid", repo)
else:
    no("submission-repository-invalid", "Repository URL must be a public GitHub repository root URL")

cat = sec.get("Category", "")
(ok if cat in CATS else no)("submission-category-invalid",
    cat if cat in CATS else 'unsupported submission category "%s"' % cat)

raw = [re.sub(r"\s+", "-", t.strip().lstrip("-*+ ").strip("`").lower())
       for t in re.split(r"[,\n]", sec.get("Tags", "")) if t.strip()]
uniq = list(dict.fromkeys(raw))
bad = [t for t in uniq if t not in TAGS and t not in ALIAS]
if not uniq or len(uniq) > 3:
    no("submission-tag-count-invalid",
       "between one and three tags; the COUNT is checked BEFORE aliasing (got %d)" % len(uniq))
elif bad:
    no("submission-tags-invalid",
       "unsupported tags: %s. Choose from: %s" % (", ".join(bad), ", ".join(TAGS)))
elif not [t for t in uniq if t not in DROPPED]:
    no("submission-tag-count-invalid",
       "every tag maps to nothing once aliased (%s); the count is taken AGAIN afterwards"
       % ", ".join(uniq))
else:
    ok("submission-tags-invalid", ", ".join(uniq))

cl = sec.get("Submission checklist", "")
miss = [s for s in CHECK
        if not re.search(r"^-\s*\[[xX]\]\s*" + re.escape(s) + r"\s*$", cl, re.M)]
if miss: no("submission-checklist-unconfirmed", "not confirmed, verbatim: %s" % miss[0])
else:    ok("submission-checklist-unconfirmed", "all five checklist items checked, verbatim")
T.close()
PY
fi

echo
NF="$(grep -c '^FAIL$' "$TALLY" || true)"
NW="$(grep -c '^WARN$' "$TALLY" || true)"
if [ "${NF:-0}" -eq 0 ]; then
  printf '%sready to submit%s — 0 failures, %s warning(s).\n' "$G" "$Z" "${NW:-0}"
  exit 0
fi
printf '%s%s rule(s) failed%s, %s warning(s). Fix these before opening the submission issue.\n' \
  "$R" "${NF:-0}" "$Z" "${NW:-0}"
exit 1