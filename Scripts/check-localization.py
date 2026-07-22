#!/usr/bin/env python3
"""Report localization gaps for KasetPlus.

Two questions it answers:
  1. Which `String(localized: "...")` keys used in Sources/ are MISSING from the
     String Catalog (so they silently fall back to English)?
  2. For each language the catalog already supports, what % of strings are
     actually translated?

Usage:
    python3 Scripts/check-localization.py          # report
    python3 Scripts/check-localization.py --strict # exit 1 if keys are missing
    python3 Scripts/check-localization.py --selftest

Deliberately scans only `String(localized:)` literals (explicit localization
intent) — not `Text("...")`, which is noisier. ponytail: good enough to catch
the "new feature shipped English-only" case; widen the regex if needed.
"""
import json
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
CATALOG = REPO / "Sources/Kaset/Resources/Localizable.xcstrings"
SOURCES = REPO / "Sources"

# Captures the literal inside String(localized: "..."), honoring \" escapes.
LOCALIZED_RE = re.compile(r'String\(localized:\s*"((?:[^"\\]|\\.)*)"')


def source_keys(root: Path) -> set[str]:
    keys: set[str] = set()
    for path in root.rglob("*.swift"):
        keys.update(LOCALIZED_RE.findall(path.read_text(encoding="utf-8", errors="ignore")))
    return keys


def languages(catalog: dict) -> set[str]:
    langs = {catalog.get("sourceLanguage", "en")}
    for entry in catalog.get("strings", {}).values():
        langs.update(entry.get("localizations", {}).keys())
    return langs


def is_translated(entry: dict, lang: str, source_lang: str) -> bool:
    # The source language needs no localization entry — it IS the source.
    if lang == source_lang:
        return True
    unit = entry.get("localizations", {}).get(lang, {}).get("stringUnit", {})
    return unit.get("state") == "translated"


def analyze(catalog: dict, used: set[str]):
    strings = catalog.get("strings", {})
    source_lang = catalog.get("sourceLanguage", "en")
    langs = sorted(languages(catalog))

    # Skip interpolated literals: their catalog key uses %@/%lld placeholders,
    # so a raw string compare would report false positives.
    missing = sorted(k for k in used if k not in strings and "\\(" not in k)

    # Only count strings the catalog intends to translate.
    translatable = {k: e for k, e in strings.items() if e.get("shouldTranslate", True)}
    coverage = {}
    for lang in langs:
        done = sum(1 for e in translatable.values() if is_translated(e, lang, source_lang))
        coverage[lang] = (done, len(translatable))
    return missing, coverage, source_lang


LANG_NAMES = {
    "en": "English", "it": "Italian", "fr": "French", "de": "German", "es": "Spanish",
    "pt": "Portuguese", "pt-BR": "Portuguese (Brazil)", "nl": "Dutch", "pl": "Polish",
    "ru": "Russian", "uk": "Ukrainian", "sv": "Swedish", "ar": "Arabic", "ko": "Korean",
    "tr": "Turkish", "id": "Indonesian", "ja": "Japanese", "zh-Hans": "Chinese (Simplified)",
    "zh-Hant": "Chinese (Traditional)", "cs": "Czech", "da": "Danish", "fi": "Finnish",
    "el": "Greek", "he": "Hebrew", "hu": "Hungarian", "no": "Norwegian", "ro": "Romanian",
    "sr": "Serbian", "vi": "Vietnamese", "ca": "Catalan", "af": "Afrikaans",
}


def render_markdown(coverage: dict, source_lang: str) -> str:
    """A README table of per-language coverage, between markers so it can be
    regenerated in place (e.g. `check-localization.py --markdown`)."""
    rows = []
    for lang, (done, total) in coverage.items():
        pct = 100 * done / total if total else 100
        filled = round(pct / 10)
        bar = "█" * filled + "░" * (10 - filled)
        rows.append((pct, lang, LANG_NAMES.get(lang, lang), bar))
    rows.sort(key=lambda r: (-r[0], r[2]))
    out = ["<!-- LOCALIZATION-STATUS:START -->", "| Language | Progress |", "| --- | --- |"]
    for pct, lang, name, bar in rows:
        out.append(f"| {name} (`{lang}`) | `{bar}` {pct:.0f}% |")
    out.append("<!-- LOCALIZATION-STATUS:END -->")
    return "\n".join(out)


def main(argv: list[str]) -> int:
    if "--selftest" in argv:
        return selftest()

    if "--markdown" in argv:
        catalog = json.loads(CATALOG.read_text(encoding="utf-8"))
        _, coverage, source_lang = analyze(catalog, source_keys(SOURCES))
        print(render_markdown(coverage, source_lang))
        return 0

    catalog = json.loads(CATALOG.read_text(encoding="utf-8"))
    used = source_keys(SOURCES)
    missing, coverage, source_lang = analyze(catalog, used)

    print(f"String Catalog: {CATALOG.relative_to(REPO)}")
    print(f"Source language: {source_lang}\n")

    print(f"Coverage by language ({len(coverage)} languages):")
    for lang, (done, total) in sorted(coverage.items(), key=lambda kv: kv[1][0] / max(kv[1][1], 1)):
        pct = 100 * done / total if total else 100
        flag = "" if pct >= 99.5 or lang == source_lang else "  <-- gaps"
        print(f"  {lang:6} {done:5}/{total:<5} {pct:5.1f}%{flag}")

    print(f"\n{len(missing)} `String(localized:)` keys used in code but NOT in the catalog "
          f"(they fall back to {source_lang}):")
    for key in missing[:40]:
        print(f"  - {key!r}")
    if len(missing) > 40:
        print(f"  ... and {len(missing) - 40} more")

    if "--strict" in argv and missing:
        return 1
    return 0


def selftest() -> int:
    catalog = {
        "sourceLanguage": "en",
        "strings": {
            "Home": {"localizations": {"it": {"stringUnit": {"state": "translated", "value": "Inizio"}}}},
            "Explore": {"localizations": {"it": {"stringUnit": {"state": "new", "value": ""}}}},
            "Untouched": {},
            "DoNotTranslate": {"shouldTranslate": False},
        },
    }
    used = {"Home", "Explore", "Untouched", "BrandNewKey"}
    missing, coverage, source_lang = analyze(catalog, used)

    assert missing == ["BrandNewKey"], missing
    assert source_lang == "en"
    # 3 translatable strings (DoNotTranslate excluded).
    assert coverage["en"] == (3, 3), coverage["en"]
    # it: only "Home" is translated; "Explore" is new, "Untouched" has none.
    assert coverage["it"] == (1, 3), coverage["it"]
    print("selftest OK")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
