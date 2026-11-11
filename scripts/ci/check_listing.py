#!/usr/bin/env python3
"""Checks the App Store listing text in docs/appstore/LISTING.md. Runs on Linux (linux.yml, job ci-scripts).

LISTING.md has one "## <language>, `<locale>`" section per App Store Connect localization, and in each one a
"### <field>" heading followed by a ```text block holding the field's value. Fails (exit 1) when:

  * a language of the app (LOCALES) has no section, or a section lacks a field;
  * a field exceeds App Store Connect's limit: name 30 characters (and at least 2), subtitle 30, promotional
    text 170, description 4000 (characters), keywords 100 bytes of UTF-8 (App Store Connect Help, "App
    information" and "Platform version information", read 2026-11-11);
  * the keywords have an empty entry, a duplicate, a space next to a comma, or the app name;
  * a third-party name (THIRD_PARTY) appears in any field but the description, or a store or competitor name
    (NEVER) appears anywhere;
  * an English field talks about a price or a purchase (PRICING);
  * a URL is not https on folito.app, or does not point at a page the site builds for that language.

Usage:
    python3 scripts/ci/check_listing.py [path/to/LISTING.md]
    python3 scripts/ci/check_listing.py --self-test
"""
import pathlib
import re
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
LISTING = ROOT / "docs" / "appstore" / "LISTING.md"
SITE = ROOT / "docs" / "site"

APP_NAME = "Folito"

# App Store Connect locale -> folder of the website for that language ("" = the site root, English).
LOCALES = {
    "en-US": "",
    "es-ES": "es",
    "fr-FR": "fr",
    "de-DE": "de",
    "it": "it",
    "pt-BR": "pt-br",
    "ja": "ja",
    "zh-Hans": "zh-hans",
}

# field -> (maximum, unit)
LIMITS = {
    "Name": (30, "characters"),
    "Subtitle": (30, "characters"),
    "Promotional text": (170, "characters"),
    "Description": (4000, "characters"),
    "Keywords": (100, "bytes"),
    "Support URL": (None, None),
    "Privacy Policy URL": (None, None),
    "Marketing URL": (None, None),
}

# Named only in the description, to say what sync is compatible with (guideline 5.2, REVIEW_RISKS.md).
THIRD_PARTY = ["KOReader", "Readest", "kosync"]
# Never named: stores, other reading apps.
NEVER = ["Kindle", "Kobo", "Nook", "Apple Books", "Google Play", "Libby", "Audible", "Pocketbook", "Moon+"]
# The owner has not decided pricing: the listing does not mention it (checked in English).
PRICING = re.compile(r"\b(price|priced|pricing|purchases?|buy|subscriptions?|subscribe|in-app|(?<!-)free|trial|premium|"
                     r"pro version|one-time)\b|[$€£¥]", re.IGNORECASE)

SECTION = re.compile(r"^## .*?`([A-Za-z-]+)`", re.MULTILINE)
FIELD = re.compile(r"^### (.+?)\s*\n+```text\n(.*?)\n```", re.MULTILINE | re.DOTALL)


def parse(text):
    """{locale: {field: value}}; fields outside a language section are ignored."""
    starts = list(SECTION.finditer(text))
    result = {}
    for i, match in enumerate(starts):
        end = starts[i + 1].start() if i + 1 < len(starts) else len(text)
        body = text[match.end():end]
        result[match.group(1)] = {m.group(1): m.group(2) for m in FIELD.finditer(body)}
    return result


def check(text, site=SITE):
    errors = []
    listing = parse(text)
    for locale, folder in LOCALES.items():
        fields = listing.get(locale)
        if fields is None:
            errors.append(f"{locale}: no section")
            continue
        for field, (limit, unit) in LIMITS.items():
            value = fields.get(field)
            if value is None:
                errors.append(f"{locale}: no {field}")
                continue
            if not value.strip():
                errors.append(f"{locale}: {field} is empty")
            size = len(value.encode("utf-8")) if unit == "bytes" else len(value)
            if limit is not None and size > limit:
                errors.append(f"{locale}: {field} is {size} {unit}, the limit is {limit}")
            if field != "Description":
                for name in THIRD_PARTY:
                    if name.lower() in value.lower():
                        errors.append(f"{locale}: {field} names {name} (only the description may)")
            for name in NEVER:
                if name.lower() in value.lower():
                    errors.append(f"{locale}: {field} names {name}")
            if locale == "en-US" and not field.endswith("URL"):
                found = PRICING.search(value)
                if found:
                    errors.append(f"{locale}: {field} mentions pricing ({found.group(0)!r})")
        name = fields.get("Name", "")
        if name and len(name) < 2:
            errors.append(f"{locale}: Name is shorter than 2 characters")
        if name and not name.startswith(APP_NAME):
            errors.append(f"{locale}: Name does not start with {APP_NAME}")
        keywords = fields.get("Keywords")
        if keywords is not None:
            if "\n" in keywords:
                errors.append(f"{locale}: Keywords span more than one line")
            entries = keywords.split(",")
            if any(e != e.strip() for e in entries):
                errors.append(f"{locale}: Keywords have a space next to a comma (it counts towards the limit)")
            cleaned = [e.strip().lower() for e in entries]
            if any(not e for e in cleaned):
                errors.append(f"{locale}: Keywords have an empty entry")
            if len(set(cleaned)) != len(cleaned):
                errors.append(f"{locale}: Keywords have a duplicate")
            if APP_NAME.lower() in cleaned:
                errors.append(f"{locale}: Keywords repeat the app name")
        prefix = "https://folito.app/" + (folder + "/" if folder else "")
        for field, page in (("Support URL", "support.html"), ("Privacy Policy URL", "privacy.html"),
                            ("Marketing URL", "")):
            url = fields.get(field)
            if url is None:
                continue
            if url != prefix + page:
                errors.append(f"{locale}: {field} is {url!r}, expected {prefix + page!r}")
            built = site / folder / (page or "index.html")
            if not built.is_file():
                errors.append(f"{locale}: {field}: the site has no {built.relative_to(site)}")
    for locale in listing:
        if locale not in LOCALES:
            errors.append(f"{locale}: section for a language the app is not localized into")
    return errors, listing


def self_test():
    good, _ = check(LISTING.read_text(encoding="utf-8"))
    assert not good, good
    with tempfile.TemporaryDirectory() as tmp:
        site = pathlib.Path(tmp)
        for folder in LOCALES.values():
            (site / folder).mkdir(parents=True, exist_ok=True)
            for page in ("index.html", "support.html", "privacy.html"):
                (site / folder / page).write_text("x")

        def section(locale, folder, **override):
            prefix = "https://folito.app/" + (folder + "/" if folder else "")
            fields = {"Name": "Folito: Reader", "Subtitle": "Books", "Promotional text": "Read.",
                      "Description": "Sync with KOReader.", "Keywords": "ebook,reading",
                      "Support URL": prefix + "support.html", "Privacy Policy URL": prefix + "privacy.html",
                      "Marketing URL": prefix}
            fields.update(override)
            out = f"## Language, `{locale}`\n\n"
            for field, value in fields.items():
                if value is not None:
                    out += f"### {field}\n\n```text\n{value}\n```\n\n"
            return out

        def run(**override):
            text = "# Listing\n\n" + "".join(section(l, f, **(override if l == "en-US" else {}))
                                             for l, f in LOCALES.items())
            return check(text, site)[0]

        assert run() == [], run()
        assert any("Name is 31" in e for e in run(Name="Folito" + "x" * 25))
        assert run(Name="Folito" + "x" * 24) == []
        assert any("Subtitle is 31" in e for e in run(Subtitle="x" * 31))
        assert any("Promotional text is 171" in e for e in run(**{"Promotional text": "x" * 171}))
        assert any("Description is 4001" in e for e in run(Description="x" * 4001))
        # Keywords count bytes: 34 three-byte characters are 102 bytes.
        assert any("Keywords is 102 bytes" in e for e in run(Keywords="書" * 34))
        assert run(Keywords="書" * 33) == []
        assert any("space next to a comma" in e for e in run(Keywords="ebook, reading"))
        assert any("duplicate" in e for e in run(Keywords="ebook,Ebook"))
        assert any("empty entry" in e for e in run(Keywords="ebook,,reading"))
        assert any("app name" in e for e in run(Keywords="ebook,folito"))
        assert any("names Readest" in e for e in run(Subtitle="Sync with Readest"))
        assert any("names Kindle" in e for e in run(Description="Better than Kindle"))
        assert any("pricing" in e for e in run(Description="Free to download"))
        assert run(Description="Reads DRM-free files") == []
        assert any("pricing" in e for e in run(**{"Promotional text": "Only $1"}))
        assert any("expected" in e for e in run(**{"Support URL": "http://folito.app/support.html"}))
        assert any("no Subtitle" in e for e in run(Subtitle=None))
        assert any("does not start with" in e for e in run(Name="Reader"))
        text = "".join(section(l, f) for l, f in LOCALES.items() if l != "ja")
        assert any(e == "ja: no section" for e in check(text, site)[0])
    print("check_listing self-test OK")


def main():
    args = sys.argv[1:]
    if args == ["--self-test"]:
        return self_test()
    path = pathlib.Path(args[0]) if args else LISTING
    errors, listing = check(path.read_text(encoding="utf-8"))
    for locale, fields in listing.items():
        sizes = ", ".join(f"{field} {len(v.encode('utf-8')) if LIMITS.get(field, (0, ''))[1] == 'bytes' else len(v)}"
                          for field, v in fields.items() if not field.endswith("URL"))
        print(f"{locale}: {sizes}")
    if errors:
        for error in errors:
            print(f"::error file={path}::{error}")
        sys.exit(1)
    print(f"Listing OK: {len(listing)} languages within the App Store Connect limits.")


if __name__ == "__main__":
    main()
