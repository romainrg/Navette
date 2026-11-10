#!/bin/bash
# Fails when a string the compiler extracted from the Debug build is missing from the catalog or lacks a translated French value.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
import glob, json, plistlib, sys

catalog = json.load(open("Navette/Resources/Localizable.xcstrings"))["strings"]
files = glob.glob("build/Build/Intermediates.noindex/Navette.build/Debug/**/*.stringsdata", recursive=True)
if not files:
    sys.exit("check-strings: no .stringsdata found, run `make build` first")

def load(path):
    with open(path, "rb") as f:
        data = f.read()
    try:
        return json.loads(data)
    except ValueError:
        return plistlib.loads(data)

def preview_line(source):
    try:
        for number, line in enumerate(open(source, encoding="utf-8"), 1):
            if line.lstrip().startswith("#Preview"):
                return number
    except OSError:
        pass
    return None

def units(localization):
    """Every stringUnit of a localization, including plural variations and substitutions."""
    found = []
    if "stringUnit" in localization:
        found.append(localization["stringUnit"])
    def walk(variations):
        for kind in variations.values():
            for variant in kind.values():
                if "stringUnit" in variant:
                    found.append(variant["stringUnit"])
                walk(variant.get("variations", {}))
    walk(localization.get("variations", {}))
    for substitution in localization.get("substitutions", {}).values():
        walk(substitution.get("variations", {}))
    return found

def translated(localization):
    found = units(localization)
    return bool(found) and all(u.get("state") == "translated" and u.get("value") for u in found)

missing = {}
for path in files:
    data = load(path)
    cutoff = preview_line(data.get("source", ""))
    for table, entries in data.get("tables", {}).items():
        if table != "Localizable":
            continue
        for entry in entries:
            line = entry.get("location", {}).get("startingLine", 0)
            if cutoff and line >= cutoff:
                continue
            key = entry["key"]
            fr = catalog.get(key, {}).get("localizations", {}).get("fr", {})
            if not translated(fr):
                missing[key] = data.get("source", path)

if missing:
    print("check-strings: keys missing from the catalog or without a translated French value:")
    for key, source in sorted(missing.items()):
        print(f"  {key!r}  ({source})")
    sys.exit(1)
print(f"check-strings: OK ({len(files)} files)")
PY
