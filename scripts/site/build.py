#!/usr/bin/env python3
"""Build the static website (docs/site/) from docs/site-src/.

Every page in PAGES is rendered for every language in LANGUAGES from the shared templates in
docs/site-src/templates/ and the strings in docs/site-src/i18n/<lang>.json. English goes to the
site root; every other language to a folder named after its lower-cased code (es/, pt-br/, ...).
docs/site/CNAME (the GitHub Pages custom domain) is written from SITE_URL. Static files (style.css,
assets/) live in docs/site/ directly and are not touched.

Adding a language: copy docs/site-src/i18n/en.json to <code>.json, translate the values, and add
the code to LANGUAGES below. Then run this script and commit docs/site/.

Usage:
    python3 scripts/site/build.py            # write docs/site/
    python3 scripts/site/build.py --check    # exit 1 if docs/site/ is stale or a strings file is incomplete

Standard library only.
"""

from __future__ import annotations

import argparse
import html
import json
import re
import sys
from pathlib import Path

# BCP 47 codes, in the order the language picker lists them. The first one is the default (x-default) and
# is published at the site root.
LANGUAGES = [
    "en",
    "es",
    "fr",
    "de",
    "it",
    "pt-BR",
    "ja",
    "zh-Hans",
]

PAGES = ["index", "privacy", "support"]
SITE_URL = "https://folito.app/"

REPO = Path(__file__).resolve().parents[2]
SRC = REPO / "docs" / "site-src"
OUT = REPO / "docs" / "site"

PLACEHOLDER = re.compile(r"\{\{ ([\w.]+) \}\}")

GLOBE = ('<svg class="globe" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" '
         'stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" focusable="false">'
         '<circle cx="12" cy="12" r="9"/><path d="M3 12h18"/><path d="M12 3c2.5 2.6 3.8 5.6 3.8 9s-1.3 6.4-3.8 9'
         'c-2.5-2.6-3.8-5.6-3.8-9S9.5 5.6 12 3z"/></svg>')
DISCLOSURE = ('<svg class="disclosure" viewBox="0 0 12 8" fill="none" stroke="currentColor" stroke-width="1.8" '
              'stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" focusable="false">'
              '<path d="m1.5 1.75 4.5 4.5 4.5-4.5"/></svg>')
CHECK = ('<svg class="check" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="2.2" '
         'stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" focusable="false">'
         '<path d="m2.5 8.6 3.6 3.6 7.4-8.4"/></svg>')

# Progressive enhancement for the <details> language picker: close it on Escape or a click outside.
# The picker works without it.
PICKER_SCRIPT = """<script>
(function () {
  function openPickers() { return document.querySelectorAll("details.lang-picker[open]"); }
  document.addEventListener("click", function (e) {
    openPickers().forEach(function (d) { if (!d.contains(e.target)) d.removeAttribute("open"); });
  });
  document.addEventListener("keydown", function (e) {
    if (e.key !== "Escape") return;
    openPickers().forEach(function (d) {
      var hadFocus = d.contains(document.activeElement);
      d.removeAttribute("open");
      if (hadFocus) d.querySelector("summary").focus();
    });
  });
})();
</script>"""

# Root index only: offer (never force) the page in the visitor's browser language. Dismissal is remembered
# when storage is available. Nothing is shown without JavaScript or when English comes first.
SUGGEST_SCRIPT = """<script>
(function () {
  var offers = %s;
  var KEY = "folito.langSuggestDismissed";
  try { if (localStorage.getItem(KEY)) return; } catch (e) {}
  function match(tag) {
    tag = String(tag || "").toLowerCase();
    if (/^zh-(hant|tw|hk|mo)/.test(tag)) return null;
    if (/^zh/.test(tag)) return "zh-Hans";
    if (/^pt/.test(tag)) return "pt-BR";
    return tag.split("-")[0];
  }
  var prefs = navigator.languages && navigator.languages.length ? navigator.languages : [navigator.language];
  var offer = null;
  for (var i = 0; i < prefs.length && !offer; i++) {
    var code = match(prefs[i]);
    if (code === "en") return;
    if (code && offers[code]) offer = offers[code];
  }
  if (!offer) return;
  var bar = document.createElement("div");
  bar.className = "lang-suggest";
  bar.setAttribute("lang", offer.lang);
  var wrap = document.createElement("div");
  wrap.className = "wrap";
  var link = document.createElement("a");
  link.href = offer.href;
  link.hreflang = offer.lang;
  link.textContent = offer.view;
  var close = document.createElement("button");
  close.type = "button";
  close.setAttribute("aria-label", offer.dismiss);
  close.textContent = "\\u00d7";
  close.addEventListener("click", function () {
    try { localStorage.setItem(KEY, "1"); } catch (e) {}
    bar.remove();
  });
  wrap.appendChild(link);
  wrap.appendChild(close);
  bar.appendChild(wrap);
  var main = document.getElementById("main");
  main.parentNode.insertBefore(bar, main);
})();
</script>"""


def folder(lang: str) -> str:
    """Output folder relative to the site root: "" for the default language, else "es/", "pt-br/", ..."""
    return "" if lang == LANGUAGES[0] else lang.lower() + "/"


def href(from_lang: str, to_lang: str, page: str) -> str:
    """Relative link from a page in from_lang to the same page in to_lang."""
    if from_lang == to_lang:
        return f"{page}.html"
    up = "../" if folder(from_lang) else ""
    return f"{up}{folder(to_lang)}{page}.html"


def load_strings() -> dict[str, dict[str, str]]:
    strings = {}
    for lang in LANGUAGES:
        path = SRC / "i18n" / f"{lang}.json"
        strings[lang] = json.loads(path.read_text(encoding="utf-8"))
    return strings


def check_keys(strings: dict[str, dict[str, str]]) -> list[str]:
    problems = []
    reference = set(strings[LANGUAGES[0]])
    for lang, table in strings.items():
        missing = sorted(reference - set(table))
        extra = sorted(set(table) - reference)
        if missing:
            problems.append(f"{lang}.json is missing keys: {', '.join(missing)}")
        if extra:
            problems.append(f"{lang}.json has keys not in {LANGUAGES[0]}.json: {', '.join(extra)}")
        empty = sorted(k for k, v in table.items() if v == "" and strings[LANGUAGES[0]].get(k, "") != "")
        if empty:
            problems.append(f"{lang}.json has empty values: {', '.join(empty)}")
    on_disk = sorted(p.stem for p in (SRC / "i18n").glob("*.json"))
    unlisted = sorted(set(on_disk) - set(LANGUAGES))
    if unlisted:
        problems.append(f"strings files not listed in LANGUAGES: {', '.join(unlisted)}")
    return problems


def picker(lang: str, page: str, strings: dict[str, dict[str, str]], placement: str) -> str:
    s = strings[lang]
    items = []
    for other in LANGUAGES:
        name = strings[other]["language.name"]
        current = f' aria-current="true">{CHECK}' if other == lang else ">"
        items.append(f'<li><a href="{href(lang, other, page)}" lang="{other}" hreflang="{other}"{current}'
                     f'<span>{name}</span></a></li>')
    return (f'<details class="lang-picker {placement}">\n'
            f'<summary>{GLOBE}<span class="vh">{s["picker.label_prefix"]}</span>'
            f'<span class="lang-name">{s["language.name"]}</span>{DISCLOSURE}</summary>\n'
            f'<ul class="lang-menu" aria-label="{s["picker.label"]}">\n' + "\n".join(items) + "\n</ul>\n</details>")


def render(template: str, values: dict[str, str], where: str) -> str:
    def sub(m: re.Match) -> str:
        key = m.group(1)
        if key not in values:
            raise KeyError(f"{where}: unknown placeholder {{{{ {key} }}}}")
        return values[key]
    return PLACEHOLDER.sub(sub, template)


def build_page(lang: str, page: str, strings: dict[str, dict[str, str]], templates: dict[str, str]) -> str:
    s = strings[lang]
    url = SITE_URL + folder(lang) + f"{page}.html"
    alternates = [f'<link rel="alternate" hreflang="{other}" href="{SITE_URL}{folder(other)}{page}.html">'
                  for other in LANGUAGES]
    alternates.append(f'<link rel="alternate" hreflang="x-default" href="{SITE_URL}{page}.html">')
    og_alternates = [f'<meta property="og:locale:alternate" content="{strings[o]["language.og_locale"]}">'
                     for o in LANGUAGES if o != lang]

    note = s["privacy.translation_note"]
    scripts = [PICKER_SCRIPT]
    if page == "index" and lang == LANGUAGES[0]:
        offers = {o: {"lang": o, "href": href(lang, o, page),
                      "view": html.unescape(strings[o]["suggest.view"]),
                      "dismiss": html.unescape(strings[o]["suggest.dismiss"])}
                  for o in LANGUAGES[1:]}
        scripts.append(SUGGEST_SCRIPT % json.dumps(offers, ensure_ascii=False, separators=(",", ":")))

    values = dict(s)
    values.update({
        "lang": lang,
        "root": "../" if folder(lang) else "",
        "title": s[f"meta.title_{page}"],
        "canonical": url,
        "alternates": "\n".join(alternates),
        "og_locale": s["language.og_locale"],
        "og_locale_alternates": "\n".join(og_alternates),
        "current.index": ' aria-current="page"' if page == "index" else "",
        "current.privacy": ' aria-current="page"' if page == "privacy" else "",
        "current.support": ' aria-current="page"' if page == "support" else "",
        "picker.header": picker(lang, page, strings, "in-header"),
        "picker.footer": picker(lang, page, strings, "in-footer"),
        "privacy.note": f'<p class="translation-note">{note}</p>\n' if note else "",
        "scripts": "\n".join(scripts),
    })
    values["content"] = render(templates[page].rstrip("\n"), values, f"{page}.html ({lang})")
    return render(templates["_layout"], values, f"_layout.html ({lang}, {page})")


def build() -> dict[Path, str]:
    strings = load_strings()
    problems = check_keys(strings)
    if problems:
        raise SystemExit("\n".join(problems))
    templates = {p.stem: p.read_text(encoding="utf-8") for p in (SRC / "templates").glob("*.html")}
    outputs = {OUT / folder(lang) / f"{page}.html": build_page(lang, page, strings, templates)
               for lang in LANGUAGES for page in PAGES}
    # GitHub Pages custom domain: the deploy copies docs/site/ as-is, so CNAME must always be there.
    outputs[OUT / "CNAME"] = SITE_URL.split("//", 1)[1].rstrip("/") + "\n"
    return outputs


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--check", action="store_true", help="fail if docs/site/ differs from the generated pages")
    args = parser.parse_args()

    outputs = build()
    existing = {p for p in OUT.rglob("*.html")}
    if args.check:
        stale = [p for p, text in outputs.items() if not p.exists() or p.read_text(encoding="utf-8") != text]
        orphans = sorted(existing - set(outputs))
        for p in stale:
            print(f"stale: {p.relative_to(REPO)}")
        for p in orphans:
            print(f"not generated (remove it or add it to the build): {p.relative_to(REPO)}")
        if stale or orphans:
            print("docs/site/ is out of date: run python3 scripts/site/build.py and commit the result.")
            return 1
        print(f"docs/site/ is up to date ({len(outputs)} pages, {len(LANGUAGES)} languages).")
        return 0

    for path, text in outputs.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
    for orphan in sorted(existing - set(outputs)):
        orphan.unlink()
    print(f"Wrote {len(outputs)} pages ({len(LANGUAGES)} languages) to {OUT.relative_to(REPO)}/")
    return 0


if __name__ == "__main__":
    sys.exit(main())
