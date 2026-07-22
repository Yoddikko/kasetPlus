#!/usr/bin/env python3
"""Regenerate the per-language `.lproj/Localizable.strings` from the String Catalog.

`Localizable.xcstrings` is the single source of truth, but `swift build` doesn't
compile it into runtime resources (only `build-app.sh` does, for the packaged
app). So dev builds (`swift build` / `swift run`) load these checked-in
`.strings`. This script regenerates them from the catalog so they never drift —
run it after translations change (e.g. after merging a Crowdin PR).

    python3 Scripts/sync-lproj.py            # regenerate in place
    python3 Scripts/sync-lproj.py --check    # report what would change, write nothing
"""
import json
import pathlib
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
CAT = REPO / "Sources/Kaset/Resources/Localizable.xcstrings"
RES = REPO / "Sources/Kaset/Resources"
HEADER = "/* Regenerated from Localizable.xcstrings by Scripts/sync-lproj.py — do not edit by hand. */"


def esc(s: str) -> str:
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\t", "\\t")


def value_for(entry: dict, lang: str):
    loc = (entry.get("localizations") or {}).get(lang)
    if not loc:
        return None
    # Emit any non-empty translated value (don't filter on state — "needs_review"
    # and stateless entries are still real translations we must not drop).
    unit = loc.get("stringUnit")
    if unit and unit.get("value"):
        return unit["value"]
    # Fall back to the "other" plural form for pluralized keys.
    other = ((loc.get("variations") or {}).get("plural") or {}).get("other", {}).get("stringUnit")
    if other and other.get("value"):
        return other.get("value")
    return None


def parse_existing_keys(path: pathlib.Path) -> set[str]:
    keys = set()
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line.startswith('"') and '" = "' in line:
            keys.add(line[1:].split('" = "', 1)[0])
    return keys


def main(argv: list[str]) -> int:
    check = "--check" in argv
    strings = json.loads(CAT.read_text(encoding="utf-8"))["strings"]
    # Skip "en": it's the source language (runtime falls back to the key text).
    langs = sorted(p.name[:-6] for p in RES.glob("*.lproj") if p.name != "en.lproj")
    grand = 0
    for lang in langs:
        pairs = {k: v for k, e in strings.items() if (v := value_for(e, lang)) is not None}
        dest = RES / f"{lang}.lproj" / "Localizable.strings"
        if check:
            old = parse_existing_keys(dest) if dest.exists() else set()
            new = set(pairs)
            removed, added = old - new, new - old
            flag = f"  removed={len(removed)} added={len(added)}" if (removed or added) else ""
            print(f"  {lang}: {len(pairs)} strings{flag}")
            if removed:
                print(f"      REMOVED e.g.: {sorted(removed)[:3]}")
        else:
            body = [HEADER, ""] + [f'"{esc(k)}" = "{esc(v)}";' for k, v in sorted(pairs.items())]
            dest.write_text("\n".join(body) + "\n", encoding="utf-8")
            print(f"  {lang}: {len(pairs)} strings")
        grand += len(pairs)
    print(f"total: {grand} across {len(langs)} languages")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
