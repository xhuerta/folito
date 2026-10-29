#!/usr/bin/env python3
"""Checks the String Catalogs (.xcstrings) of the iPhone and Apple Watch apps. Runs on Linux (no Xcode).

Fails (exit 1) when:
  * a catalog is not valid JSON or not a String Catalog;
  * a key has no translation, or a translation that is not in state "translated", in one of the
    supported languages (plural variations are checked one by one);
  * the format specifiers (%@, %lld, %d, %1$@ ...) of a translation differ from the source string's;
  * a string that SwiftUI / `String(localized:)` would look up in a target's sources is missing from that
    target's Localizable catalog (so a new UI string cannot ship untranslated);
  * an obvious user-facing literal bypasses localization (`Text(verbatim: "Words")`, or a literal sentence
    assigned to an `...error` / `...message` / `...title` / `...text` property).
    Add `// i18n-ignore` at the end of the line for a deliberate exception.

Catalog keys that no source uses any more are reported as warnings (Xcode marks them "stale").

Usage: scripts/check_strings.py [--list-keys]
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# Source language first. Keep in sync with project.yml (CFBundleLocalizations) and docs/LOCALIZATION.md.
LANGUAGES = ["en", "es", "fr", "de", "it", "pt-BR", "ja", "zh-Hans"]

# target name -> (Localizable catalog, other catalogs, source directories, excluded directory names)
TARGETS = {
    "WristReader (iOS)": (
        "iOSApp/Resources/Localizable.xcstrings",
        ["iOSApp/Resources/InfoPlist.xcstrings"],
        ["iOSApp", "Shared"],
        {"Tests", "UITests"},
    ),
    "WristReaderWatch (watchOS)": (
        "WatchApp/Resources/Localizable.xcstrings",
        ["WatchApp/Resources/InfoPlist.xcstrings"],
        ["WatchApp", "Shared"],
        {"Tests"},
    ),
}

# printf-style specifiers as used by Foundation (%@, %lld, %1$@, %.2f ...). "%%" is a literal percent.
SPEC_RE = re.compile(r"%(?:(\d+)\$)?[-+ #0']*\d*(?:\.\d+)?(hh|h|ll|l|q|z|t|j|L)?([@dDiuUxXoOfFeEgGcCsSpaA])")
PERCENT_ESCAPE_RE = re.compile(r"%%")


def specifiers(text: str) -> dict[int, str]:
    """Argument position -> normalized conversion (length modifier + type)."""
    text = PERCENT_ESCAPE_RE.sub("", text)
    result: dict[int, str] = {}
    sequential = 0
    for m in SPEC_RE.finditer(text):
        position, length, conv = m.group(1), m.group(2) or "", m.group(3)
        if conv in "dDi":
            conv = "d"  # %d and %i are the same conversion
        if position:
            index = int(position)
        else:
            sequential += 1
            index = sequential
        result[index] = length + conv
    return result


# ---------------------------------------------------------------------------------------------------------
# Catalog checks


def string_units(entry: dict, language: str):
    """Yields (variant name, stringUnit dict or None) for one language of a catalog entry."""
    loc = entry.get("localizations", {}).get(language)
    if loc is None:
        yield ("", None)
        return
    if "stringUnit" in loc:
        yield ("", loc["stringUnit"])
    variations = loc.get("variations", {})
    for kind, cases in variations.items():
        for case, value in cases.items():
            yield (f"{kind}.{case}", value.get("stringUnit"))
    if "stringUnit" not in loc and not variations:
        yield ("", None)


def check_catalog(path: Path, errors: list[str]) -> dict:
    rel = path.relative_to(ROOT)
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as e:
        errors.append(f"{rel}: cannot read catalog: {e}")
        return {}
    if data.get("sourceLanguage") != LANGUAGES[0] or not isinstance(data.get("strings"), dict):
        errors.append(f"{rel}: not a String Catalog with sourceLanguage '{LANGUAGES[0]}'")
        return {}
    for key, entry in data["strings"].items():
        if entry.get("shouldTranslate") is False:
            continue
        # Source specifiers: from the English value(s) if present, else from the key itself.
        source_specs = specifiers(key)
        for language in LANGUAGES:
            for variant, unit in string_units(entry, language):
                where = f"{rel}: '{key}' [{language}{(' ' + variant) if variant else ''}]"
                if unit is None:
                    if language == LANGUAGES[0]:
                        continue  # the key is the English text
                    errors.append(f"{where}: missing translation")
                    continue
                if unit.get("state") != "translated":
                    errors.append(f"{where}: state is '{unit.get('state')}', expected 'translated'")
                value = unit.get("value", "")
                if not value.strip():
                    errors.append(f"{where}: empty value")
                    continue
                specs = specifiers(value)
                # A plural "one"/"zero" case may spell the number out ("un point") and drop it.
                if variant.startswith("plural.") and variant != "plural.other":
                    if any(source_specs.get(i) != s for i, s in specs.items()):
                        errors.append(f"{where}: format specifiers {sorted(specs.items())} "
                                      f"don't match the source {sorted(source_specs.items())}")
                elif specs != source_specs:
                    errors.append(f"{where}: format specifiers {sorted(specs.items())} "
                                  f"don't match the source {sorted(source_specs.items())}")
    return data


# ---------------------------------------------------------------------------------------------------------
# Swift source scanning

# Initializers / modifiers whose first unlabeled string literal is a LocalizedStringKey, plus this project's
# own wrappers that take a LocalizedStringKey (TintedLabel, adaptivePicker, slider).
LOCALIZED_CALLS = [
    "Text", "Label", "Button", "Section", "Toggle", "Picker", "TextField", "SecureField", "NavigationLink",
    "LabeledContent", "ContentUnavailableView", "Stepper", "Link", "Menu", "TintedLabel", "adaptivePicker",
    "slider", "LocalizedStringKey", "LocalizedStringResource",
    ".navigationTitle", ".accessibilityLabel", ".accessibilityHint", ".accessibilityValue",
    ".confirmationDialog", ".alert", ".help", ".badge",
]
CALL_RE = re.compile(r"(?<![\w.])(" + "|".join(re.escape(c) for c in LOCALIZED_CALLS if not c.startswith("."))
                     + r")\(\s*\"|(" + "|".join(re.escape(c) for c in LOCALIZED_CALLS if c.startswith("."))
                     + r")\(\s*\"|\b(localized|named):\s*(?:Text\(\s*)?\"")
VERBATIM_RE = re.compile(r"\bverbatim:\s*\"")
ASSIGN_RE = re.compile(r"\b\w*(?:[eE]rror|[mM]essage|[tT]itle|[tT]ext|[wW]arning|[hH]int)\s*=\s*\"")

ESCAPES = {"n": "\n", "t": "\t", "r": "\r", "0": "\0", "\"": "\"", "'": "'", "\\": "\\"}


def read_literal(src: str, start: int) -> tuple[str, int]:
    """Reads the Swift string literal whose opening quote is at src[start - 1]. Interpolations become
    the placeholder "%@". Returns (text, index after the closing quote)."""
    out = []
    i = start
    while i < len(src):
        c = src[i]
        if c == "\"":
            return "".join(out), i + 1
        if c == "\n":
            break
        if c == "\\" and i + 1 < len(src):
            n = src[i + 1]
            if n == "(":
                # Interpolation: skip to the matching parenthesis, including nested string literals.
                depth, j = 1, i + 2
                while j < len(src) and depth:
                    if src[j] == "\"":
                        _, j = read_literal(src, j + 1)
                        continue
                    depth += {"(": 1, ")": -1}.get(src[j], 0)
                    j += 1
                out.append("%@")
                i = j
                continue
            if n == "u" and i + 2 < len(src) and src[i + 2] == "{":
                end = src.index("}", i + 3)
                out.append(chr(int(src[i + 3:end], 16)))
                i = end + 1
                continue
            out.append(ESCAPES.get(n, n))
            i += 2
            continue
        out.append(c)
        i += 1
    raise ValueError("unterminated string literal")


def normalize(text: str) -> str:
    """Key form used to compare source literals and catalog keys: every format specifier becomes %@."""
    return SPEC_RE.sub("%@", text)


def strip_comments(line: str) -> str:
    """Drops a trailing // comment that is not inside a string literal (good enough for this code base)."""
    in_string = False
    i = 0
    while i < len(line):
        c = line[i]
        if c == "\\" and in_string:
            i += 2
            continue
        if c == "\"":
            in_string = not in_string
        elif not in_string and line.startswith("//", i):
            return line[:i]
        i += 1
    return line


def swift_files(dirs: list[str], excluded: set[str]):
    for d in dirs:
        for path in sorted((ROOT / d).rglob("*.swift")):
            if excluded & set(path.relative_to(ROOT / d).parts[:-1]):
                continue
            yield path


def has_words(text: str) -> bool:
    return re.search(r"[A-Za-z]{2,}", text.replace("%@", "")) is not None


def scan_sources(dirs: list[str], excluded: set[str], errors: list[str]) -> dict[str, str]:
    """Returns normalized key -> 'file:line' for every localizable literal; reports unlocalized literals."""
    keys: dict[str, str] = {}
    for path in swift_files(dirs, excluded):
        rel = path.relative_to(ROOT)
        for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if "i18n-ignore" in raw:
                continue
            line = strip_comments(raw)
            if line.lstrip().startswith(("///", "//", "*")):
                continue
            for m in CALL_RE.finditer(line):
                try:
                    text, _ = read_literal(line, m.end())
                except ValueError:
                    continue
                if text:
                    keys.setdefault(normalize(text), f"{rel}:{number}")
            for regex, what in ((VERBATIM_RE, "verbatim text"), (ASSIGN_RE, "literal assigned to a UI property")):
                for m in regex.finditer(line):
                    try:
                        text, _ = read_literal(line, m.end())
                    except ValueError:
                        continue
                    if has_words(text) and (regex is VERBATIM_RE or " " in text.strip()):
                        errors.append(f"{rel}:{number}: unlocalized {what} \"{text}\" "
                                      "(use String(localized:) or add // i18n-ignore)")
    return keys


# ---------------------------------------------------------------------------------------------------------


def main() -> int:
    errors: list[str] = []
    warnings: list[str] = []
    list_keys = "--list-keys" in sys.argv[1:]
    total = 0
    for target, (catalog, others, dirs, excluded) in TARGETS.items():
        path = ROOT / catalog
        data = check_catalog(path, errors) if path.exists() else {}
        if not path.exists():
            errors.append(f"{catalog}: missing")
        for other in others:
            if (ROOT / other).exists():
                check_catalog(ROOT / other, errors)
            else:
                errors.append(f"{other}: missing")
        catalog_keys = {normalize(k) for k in data.get("strings", {})}
        total += len(data.get("strings", {}))
        used = scan_sources(dirs, excluded, errors)
        if list_keys:
            print(f"# {target}")
            for key, where in sorted(used.items()):
                print(f"{where}\t{key}")
        for key, where in sorted(used.items(), key=lambda kv: kv[1]):
            if key not in catalog_keys:
                errors.append(f"{where}: \"{key}\" is not in {catalog} ({target})")
        for key in sorted(catalog_keys - set(used)):
            warnings.append(f"{catalog}: \"{key}\" is not used by any source of {target} (stale?)")

    # The same file can be scanned for two targets (Shared/); report each problem once.
    errors = list(dict.fromkeys(errors))
    for w in warnings:
        print(f"warning: {w}")
    for e in errors:
        print(f"error: {e}")
    if errors:
        print(f"\n{len(errors)} localization error(s).")
        return 1
    print(f"Localization OK: {total} keys in {len(TARGETS)} Localizable catalogs, "
          f"{len(LANGUAGES)} languages ({', '.join(LANGUAGES)}).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
