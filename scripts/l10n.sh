#!/usr/bin/env bash
# Checks the Ukrainian translation against the strings the code asks for.
#   scripts/l10n.sh                        report missing, stale and mismatched keys (exit 1 on missing or mismatched)
#   scripts/l10n.sh --missing-json FILE    also write the missing keys as JSON, for translators:
#                                          [{key, comment, files: ["path:line"], plural, en}]
#
# The keys come from the compiler (swiftc -emit-localized-strings, what Xcode uses): every Text("..."), String(localized:)
# and so on. The translation is Localization/uk.lproj/Localizable.strings, plus Localizable.stringsdict for the keys that
# have a count which changes their words (1 game, 2 games): English plural rules are in en.lproj/Localizable.stringsdict, and
# those keys need one, few, many and other in Ukrainian. See Localization/README.md.
set -euo pipefail
cd "$(dirname "$0")/.."
MISSING_JSON=""
while [ $# -gt 0 ]; do
  case "$1" in
    --missing-json) MISSING_JSON="${2:?--missing-json needs a file}"; shift 2 ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

OUT="${L10N_TMP:-${TMPDIR:-/tmp}/g-player-l10n}"
DATA="$OUT/stringsdata"
rm -rf "$DATA"; mkdir -p "$DATA"
# A scratch path of its own keeps this build apart from `swift build`. Everything it built is thrown away first, since a
# file that isn't recompiled writes no .stringsdata; the packages it downloaded (Sparkle) stay.
SCRATCH=.build/l10n
rm -rf "$SCRATCH"/*-apple-macosx "$SCRATCH"/debug "$SCRATCH"/release "$SCRATCH"/build.db "$SCRATCH"/*.lock
swift build --product GPlayer --scratch-path "$SCRATCH" \
  -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$DATA" >"$OUT/build.log" 2>&1 \
  || { tail -30 "$OUT/build.log" >&2; echo "build failed (full log: $OUT/build.log)" >&2; exit 1; }

mkdir -p "$OUT/json"
plutil -convert json -o "$OUT/json/uk-strings.json" Localization/uk.lproj/Localizable.strings
plutil -convert json -o "$OUT/json/uk-stringsdict.json" Localization/uk.lproj/Localizable.stringsdict
plutil -convert json -o "$OUT/json/en-stringsdict.json" Localization/en.lproj/Localizable.stringsdict

python3 -I - "$DATA" "$OUT/json" "$MISSING_JSON" "$PWD" <<'PY'
import glob, json, os, re, sys

data_dir, json_dir, missing_json, root = sys.argv[1:5]

# --- the keys the code asks for -------------------------------------------------------------------------------------
code = {}   # key -> {"comment": str, "files": [path:line]}
for path in sorted(glob.glob(os.path.join(data_dir, "*.stringsdata"))):
    entry = json.load(open(path))
    src = os.path.relpath(entry.get("source", path), root)
    for table, items in entry.get("tables", {}).items():
        if table != "Localizable":
            print(f"warning: {src} uses the table '{table}', which isn't translated", file=sys.stderr)
            continue
        for it in items:
            if not it["key"].strip():
                continue                      # Text("") and the like: nothing to translate
            k = code.setdefault(it["key"], {"comment": "", "files": []})
            if it.get("comment") and it["comment"] not in k["comment"]:
                k["comment"] = (k["comment"] + " / " + it["comment"]) if k["comment"] else it["comment"]
            where = f"{src}:{it.get('location', {}).get('startingLine', 0)}"
            if where not in k["files"]:
                k["files"].append(where)

# --- the translation -------------------------------------------------------------------------------------------------
def load(name):
    return json.load(open(os.path.join(json_dir, name)))

strings = load("uk-strings.json")
plurals = load("uk-stringsdict.json")
en_plurals = load("en-stringsdict.json")   # the keys whose words change with their count
translated = set(strings) | set(plurals)

# --- format specifiers -----------------------------------------------------------------------------------------------
SPEC = re.compile(r"%(?:(\d+)\$)?[-+ #0']*(?:\d+|\*)?(?:\.(?:\d+|\*))?(hh|h|ll|l|q|L|z|t|j)?([@dDiuUxXoOfeEgGcCsSpaAF])")

def specs(text):
    """The arguments a format string takes, in order: [(position or None, type)]. %% takes none."""
    out = []
    for m in SPEC.finditer(text.replace("%%", "")):
        conv = {"i": "d", "D": "d", "U": "u", "O": "o"}.get(m.group(3), m.group(3))
        out.append((int(m.group(1)) if m.group(1) else None, (m.group(2) or "") + conv))
    return out

def signature(text):
    """Type of each argument by its position (a translation may reorder with %2$@)."""
    sig, n = {}, 0
    for pos, typ in specs(text):
        n += 1
        sig[pos if pos else n] = typ
    return sig

def fmt(sig):
    return "(" + ", ".join(f"{i}:{t}" for i, t in sorted(sig.items())) + ")" if sig else "(nothing)"

def mismatch(key, value):
    want, got = signature(key), signature(value)
    return None if want == got else f"key takes {fmt(want)}, translation takes {fmt(got)}"

problems = []   # (key, what is wrong)
stale_en = []

def check_plural(key, entry, forms, who):
    outer = entry.get("NSStringLocalizedFormatKey")
    if not outer:
        problems.append((key, f"{who} stringsdict entry has no NSStringLocalizedFormatKey"))
        return
    variables = {name: v for name, v in entry.items() if isinstance(v, dict)}
    for name in re.findall(r"%#@(\w+)@", outer):
        var = variables.get(name)
        if var is None:
            problems.append((key, f"{who}: variable {name} isn't defined"))
            continue
        for form in forms:
            if form not in var:
                problems.append((key, f"{who}: variable {name} lacks the '{form}' form"))
                continue
            text = outer
            for other, v in variables.items():
                text = text.replace(f"%#@{other}@", var[form] if other == name else v.get("other", ""))
            why = mismatch(key, text)
            if why:
                problems.append((key, f"{who}: form '{form}' of {name}: {why}"))

for key, value in strings.items():
    if key not in code:
        continue
    if key in en_plurals:
        problems.append((key, "has a count that changes its words: translate it in Localizable.stringsdict "
                              "(one, few, many, other), not in Localizable.strings"))
    elif not isinstance(value, str) or not value.strip():
        problems.append((key, "translation is empty"))
    else:
        why = mismatch(key, value)
        if why:
            problems.append((key, why))

for key, entry in en_plurals.items():
    if key not in code:
        stale_en.append(key)
    else:
        check_plural(key, entry, ["one", "other"], "English")
for key, entry in plurals.items():
    if key in code:
        check_plural(key, entry, ["one", "few", "many", "other"], "Ukrainian")

missing = sorted(k for k in code if k not in translated)
stale = sorted(k for k in translated if k not in code)

if missing_json:
    os.makedirs(os.path.dirname(os.path.abspath(missing_json)), exist_ok=True)
    rows = []
    for k in missing:
        row = {"key": k, "comment": code[k]["comment"], "files": code[k]["files"], "plural": k in en_plurals}
        if k in en_plurals:
            e = en_plurals[k]
            row["en"] = {"format": e.get("NSStringLocalizedFormatKey"),
                         **{n: {f: v[f] for f in ("one", "other")} for n, v in e.items() if isinstance(v, dict)}}
        rows.append(row)
    with open(missing_json, "w", encoding="utf-8") as f:
        json.dump(rows, f, ensure_ascii=False, indent=2)
        f.write("\n")

def show(title, rows):
    if rows:
        print(f"\n{title} ({len(rows)})")
        for r in rows:
            print("  " + r)

print(f"{len(code)} keys in the code ({len(en_plurals)} with plural forms), "
      f"{len(strings)} in uk Localizable.strings, {len(plurals)} in uk Localizable.stringsdict")
show("missing: in the code, not translated", [repr(k) + ("   [plural: Localizable.stringsdict]" if k in en_plurals else "") for k in missing])
show("stale: translated, no longer in the code", [repr(k) for k in stale])
show("stale: English plural rule for a key that is no longer in the code", [repr(k) for k in sorted(stale_en)])
show("mismatched", [f"{k!r}: {why}" for k, why in problems])
if missing_json:
    print(f"\nmissing keys with context: {missing_json}")
sys.exit(1 if missing or problems or stale_en else 0)
PY
