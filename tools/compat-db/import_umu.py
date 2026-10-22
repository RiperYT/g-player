#!/usr/bin/env python3
"""Builds Sources/GPlayerCore/Resources/GameFixes.json.

Reads the Steam fixes of umu-protonfixes (BSD-2-Clause) statically with `ast` (nothing from it is ever
imported or run), keeps what makes sense for Wine on a Mac, then merges G-Player's own curated entries from
gplayer-fixes.json (curated entries win).

    python3 tools/compat-db/import_umu.py /path/to/umu-protonfixes

See README.md in this folder for what is kept, what is dropped and why.
"""
import argparse
import ast
import collections
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_OUT = ROOT / "Sources/GPlayerCore/Resources/GameFixes.json"
DEFAULT_CURATED = Path(__file__).resolve().parent / "gplayer-fixes.json"
SHIPPED_LICENSE = ROOT / "Sources/GPlayerCore/Resources/licenses/umu-protonfixes-LICENSE.txt"
UMU_URL = "https://github.com/Open-Wine-Components/umu-protonfixes"

# umu's OverrideOrder (util.py) → the values GameFix.dllOverrides uses (DLLOverrideMode raw values).
OVERRIDE_ORDER = {"DISABLED": "", "NATIVE": "n", "BUILTIN": "b", "NATIVE_BUILTIN": "n,b", "BUILTIN_NATIVE": "b,n"}
DLL_MODES = set(OVERRIDE_ORDER.values())

# Calls that only make sense on Linux/Proton, or edit files we can't describe. Removed, the rest of the fix stays.
DROPPED_CALLS = {
    "disable_esync", "disable_fsync", "disable_ntsync", "disable_nvapi",
    "set_cpu_topology", "set_cpu_topology_nosmt", "set_cpu_topology_limit",
    "set_xml_options", "set_ini_options", "create_dosbox_conf", "create_dos_device",
    "import_saves_folder", "install_eac_runtime", "install_battleye_runtime", "set_game_drive",
}
# Environment variables of Proton, Linux graphics/audio drivers, Steam Deck. Compared in upper case.
DROPPED_ENV_PREFIXES = ("PROTON_", "WINEFSYNC", "WINEESYNC", "WINENTSYNC", "__GL_", "__NV_", "RADV_", "RADEONSI_",
                        "MESA_", "VKD3D", "VK_X11_", "PULSE_")
DROPPED_ENV_NAMES = {"STEAMDECK", "STEAMOS", "AMD_DEBUG", "ENABLE_GAMESCOPE_WSI"}
# util.del_environment only ever removes Steam Deck markers in the files we accept; anything else skips the file.
DROPPED_DEL_ENV = {"STEAMDECK", "STEAMOS"}
# winetricks verbs that aren't components: `gui` opens a window, `sound=alsa` picks a Linux audio driver.
# Everything else umu lists in protontricks() is kept exactly as written, even what G-Player can't install: settings
# (`win7`, `winxp`, `hidewineexports=enable`), stand-ins (`vcrun2019` for `vcrun2022`), aliases and verbs that aren't
# winetricks'. The data stays faithful to the source; CompatResolver decides at launch time what each id means
# (a per-program registry value, another component, or a line saying G-Player can't install it).
DROPPED_VERBS = re.compile(r"^(gui|sound=.*)$")
REGISTRY_TYPES = {"REG_SZ", "REG_DWORD"}

FIX_KEYS = {"id", "title", "steamAppIDs", "exeNames", "components", "dllOverrides", "environment", "arguments",
            "replacements", "registry", "notes", "source", "verifiedOnMac", "macStatus"}
MAC_STATUSES = {"works", "issues", "broken"}


def dropped_env_label(key):
    """Names the rule that removes this variable, or None to keep it."""
    upper = key.upper()
    if upper in DROPPED_ENV_NAMES:
        return f"env {upper}"
    return next((f"env {p}*" for p in DROPPED_ENV_PREFIXES if upper.startswith(p)), None)


class Skip(Exception):
    """The file can't be imported; the message is the reason (used for the summary)."""


def dotted(node):
    parts = []
    while isinstance(node, ast.Attribute):
        parts.append(node.attr)
        node = node.value
    if isinstance(node, ast.Name):
        parts.append(node.id)
        return ".".join(reversed(parts))
    return None


def literal(node):
    try:
        return ast.literal_eval(node)
    except (ValueError, TypeError, SyntaxError):
        raise Skip("argument is not a literal")


def literal_str(node):
    value = literal(node)
    if not isinstance(value, str):
        raise Skip("argument is not a string")
    return value


def override_order(node):
    name = dotted(node)
    if name and name.split(".")[-2:-1] == ["OverrideOrder"] and name.split(".")[-1] in OVERRIDE_ORDER:
        return OVERRIDE_ORDER[name.split(".")[-1]]
    raise Skip("argument is not an OverrideOrder constant")


class Collector:
    """What one gamefix asks for, plus what was left out."""

    def __init__(self):
        self.components, self.arguments, self.replacements, self.registry = [], [], [], []
        self.dll_overrides, self.environment = {}, {}
        self.dropped = collections.Counter()

    def call(self, node):
        name = dotted(node.func)
        if not name or not name.startswith("util."):
            raise Skip(f"calls {name or 'something else'}")
        fn = name[len("util."):]
        if fn in DROPPED_CALLS:
            self.dropped[f"util.{fn}"] += 1
            return
        handler = getattr(self, f"_{fn}", None)
        if handler is None:
            raise Skip(f"calls util.{fn}")
        handler(node)

    @staticmethod
    def _args(node, count, keywords=()):
        if len(node.args) != count or any(k.arg not in keywords for k in node.keywords):
            raise Skip(f"unexpected arguments to {dotted(node.func)}")
        return node.args

    def _protontricks(self, node):
        (verbs,) = self._args(node, 1)
        for verb in literal_str(verbs).split():
            if DROPPED_VERBS.match(verb):
                self.dropped[f"verb {verb.split('=')[0]}"] += 1
            elif verb not in self.components:
                self.components.append(verb)

    def _winedll_override(self, node):
        dll, order = self._args(node, 2)
        dll = literal_str(dll)
        if re.search(r"[,;=\s]", dll):
            raise Skip("unsupported DLL name")
        self.dll_overrides[dll] = override_order(order)

    def _set_environment(self, node):
        key, value = self._args(node, 2)
        key = literal_str(key)
        label = dropped_env_label(key)
        if label:
            self.dropped[label] += 1
        else:
            self.environment[key] = literal_str(value)

    def _del_environment(self, node):
        (key,) = self._args(node, 1)
        if literal_str(key).upper() not in DROPPED_DEL_ENV:
            raise Skip("calls util.del_environment")
        self.dropped["util.del_environment"] += 1

    def _append_argument(self, node):
        (argument,) = self._args(node, 1)
        self.arguments.append(literal_str(argument))

    def _replace_command(self, node):
        old, new = self._args(node, 2)
        self.replacements.append({"from": literal_str(old), "to": literal_str(new)})

    def _regedit_add(self, node):
        if not 1 <= len(node.args) <= 4 or any(k.arg != "arch" for k in node.keywords):
            raise Skip("unexpected arguments to util.regedit_add")
        values = [literal_str(a) for a in node.args]
        if len(values) < 4:
            self.dropped["registry key without a value"] += 1
        elif values[2] not in REGISTRY_TYPES:
            self.dropped[f"registry {values[2]}"] += 1
        else:
            key, name, typ, value = values
            self.registry.append({"key": key, "name": name, "type": typ, "value": value})

    def fix(self, appid, title, source):
        return {
            "id": f"steam-{appid}", "title": title, "steamAppIDs": [appid], "exeNames": [],
            "components": self.components, "dllOverrides": self.dll_overrides, "environment": self.environment,
            "arguments": self.arguments, "replacements": self.replacements, "registry": self.registry,
            "source": source, "verifiedOnMac": False,
        }

    @property
    def is_empty(self):
        return not (self.components or self.dll_overrides or self.environment or self.arguments
                    or self.replacements or self.registry)


def clean_title(text, appid):
    """`Game fix for Foo: Bar.` → `Foo: Bar`. Only the first line counts."""
    line = next((l.strip() for l in (text or "").splitlines() if l.strip()), "")
    line = re.sub(r"^(?:game\s+fix(?:es)?(?:\s+for)?|fix(?:es)?\s+for)\s+", "", line, flags=re.I)
    line = re.sub(rf"\s*[-:(]?\s*(?:id\s*[:#]?\s*)?{appid}\)?$", "", line, flags=re.I)
    line = re.sub(r"\s+needs\s+.*$", "", line)
    return line.replace("\\&", "&").rstrip(". ") or None


def first_comment(source):
    for line in source.splitlines():
        if line.startswith("#"):
            return line.lstrip("# ")
    return None


def analyze(path, source_tag):
    """→ (fix dict, dropped Counter). Raises Skip."""
    text = path.read_text(encoding="utf-8")
    try:
        tree = ast.parse(text)
    except SyntaxError:
        raise Skip("does not parse")
    entry = {n.name: n for n in tree.body if isinstance(n, ast.FunctionDef)}
    main = entry.get("main_with_id") or entry.get("main")
    if main is None:
        raise Skip("has no main()")
    collector = Collector()
    for stmt in main.body:
        if isinstance(stmt, ast.Pass):
            continue
        if isinstance(stmt, ast.Expr) and isinstance(stmt.value, ast.Constant) and isinstance(stmt.value.value, str):
            continue  # a docstring used as a comment
        if isinstance(stmt, ast.Expr) and isinstance(stmt.value, ast.Call):
            collector.call(stmt.value)
        else:
            raise Skip(f"main() has {type(stmt).__name__}")
    if collector.is_empty:
        raise Skip("empty after filtering")
    title = clean_title(ast.get_docstring(tree) or first_comment(text), path.stem)
    return collector.fix(path.stem, title, source_tag), collector.dropped


def load_curated(path):
    fixes = []
    for raw in json.loads(path.read_text(encoding="utf-8"))["fixes"]:
        unknown = set(raw) - FIX_KEYS
        if unknown or "id" not in raw or "source" not in raw:
            sys.exit(f"{path.name}: {raw.get('id', '?')}: needs id and source, knows only {sorted(FIX_KEYS)}")
        fix = {"title": None, "steamAppIDs": [], "exeNames": [], "components": [], "dllOverrides": {},
               "environment": {}, "arguments": [], "replacements": [], "registry": [], "verifiedOnMac": False}
        fix.update(raw)
        for entry in fix["registry"]:
            entry.setdefault("type", "REG_SZ")
        if fix.get("macStatus") not in MAC_STATUSES | {None}:
            sys.exit(f"{path.name}: {fix['id']}: macStatus must be one of {sorted(MAC_STATUSES)}")
        if not set(fix["dllOverrides"].values()) <= DLL_MODES:
            sys.exit(f"{path.name}: {fix['id']}: dllOverrides values must be one of {sorted(DLL_MODES)}")
        fixes.append(fix)
    return fixes


def git_commit(umu):
    try:
        return subprocess.run(["git", "-C", str(umu), "rev-parse", "HEAD"], check=True, capture_output=True,
                              text=True).stdout.strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        sys.exit(f"{umu} is not a git checkout of umu-protonfixes")


def main():
    parser = argparse.ArgumentParser(description="Build GameFixes.json from umu-protonfixes and gplayer-fixes.json.")
    parser.add_argument("umu", type=Path, help="checkout of umu-protonfixes")
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT)
    parser.add_argument("--curated", type=Path, default=DEFAULT_CURATED)
    args = parser.parse_args()

    license_file = args.umu / "LICENSE"
    if not license_file.is_file() or "BSD 2-Clause License" not in license_file.read_text(encoding="utf-8"):
        sys.exit("umu-protonfixes/LICENSE is not the BSD 2-Clause License; check the licensing before importing")
    if not SHIPPED_LICENSE.is_file() or SHIPPED_LICENSE.read_text() != license_file.read_text():
        print(f"warning: {SHIPPED_LICENSE.relative_to(ROOT)} differs from upstream LICENSE; update it and NOTICE",
              file=sys.stderr)

    commit = git_commit(args.umu)
    source_tag = f"umu-protonfixes@{commit[:7]}"
    files = sorted(p for p in (args.umu / "gamefixes-steam").glob("*.py") if p.stem.isdigit())

    fixes, skipped, dropped = [], collections.Counter(), collections.Counter()
    for path in files:
        try:
            fix, drops = analyze(path, source_tag)
        except Skip as reason:
            skipped[str(reason)] += 1
            continue
        fixes.append(fix)
        dropped.update(drops)
    imported = len(fixes)

    curated = load_curated(args.curated)
    taken_ids = {c["id"] for c in curated}
    taken_apps = {a for c in curated for a in c["steamAppIDs"]}
    kept = [f for f in fixes if f["id"] not in taken_ids and not taken_apps & set(f["steamAppIDs"])]
    replaced = len(fixes) - len(kept)
    merged = sorted(kept + curated, key=lambda f: f["id"])
    if len({f["id"] for f in merged}) != len(merged):
        sys.exit("duplicate ids in gplayer-fixes.json")

    database = {
        "version": 1,
        "sources": [
            {"name": "umu-protonfixes", "url": UMU_URL, "commit": commit, "license": "BSD-2-Clause"},
            {"name": "g-player", "license": "Apache-2.0"},
        ],
        "fixes": merged,
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(database, indent=2, sort_keys=True, ensure_ascii=False) + "\n", encoding="utf-8")

    verbs = collections.Counter(c for f in fixes for c in f["components"])
    print(f"umu-protonfixes {commit}")
    print(f"scanned {len(files)}, imported {imported}, skipped {sum(skipped.values())}")
    for reason, count in skipped.most_common(10):
        print(f"  skipped {count:3}  {reason}")
    print("dropped from imported fixes:", ", ".join(f"{name} x{count}" for name, count in dropped.most_common()))
    print("top components:", ", ".join(f"{verb} x{count}" for verb, count in verbs.most_common(15)))
    print(f"curated {len(curated)}, replaced {replaced} imported")
    print(f"wrote {len(merged)} fixes to {args.out} ({args.out.stat().st_size / 1024:.1f} KB)")


if __name__ == "__main__":
    main()
