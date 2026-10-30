#!/usr/bin/env python3
"""Build the static website (docs/site/) from docs/site-src/.

Every page in PAGES is rendered for every language in LANGUAGES from the shared templates in
docs/site-src/templates/ and the strings in docs/site-src/i18n/<lang>.json. English goes to the
site root; every other language to a folder named after its lower-cased code (es/, pt-br/, ...).
docs/site/CNAME (the GitHub Pages custom domain) is written from SITE_URL, and so are robots.txt and
sitemap.xml (every page in every language, with hreflang alternates). Static files (style.css, favicon.ico,
assets/) live in docs/site/ directly and are not touched.

Index pages are addressed by their folder (https://folito.app/, https://folito.app/es/), never by
index.html: canonical and hreflang URLs, the sitemap and internal links all use that form, and GitHub Pages
serves a folder's index.html for it. Other pages keep their file name (privacy.html, support.html).

The sitemap has no <lastmod>: a date taken from git would differ between the commit that rebuilds the site
and the commit that is checked, so --check could never pass; search engines ignore a lastmod they cannot
trust anyway.

Every build validates its own output (well-formed sitemap, every page listed, every canonical/hreflang
target generated, robots.txt pointing at the sitemap); see validate(). Tests: scripts/site/test_build.py.

Adding a language: copy docs/site-src/i18n/en.json to <code>.json, translate the values, and add
the code to LANGUAGES below. Then run this script and commit docs/site/.

Usage:
    python3 scripts/site/build.py            # write docs/site/
    python3 scripts/site/build.py --check    # exit 1 if docs/site/ is stale or a strings file is incomplete
    python3 -m unittest discover -s scripts/site    # tests

Standard library only.
"""

from __future__ import annotations

import argparse
import html
import json
import re
import sys
import xml.etree.ElementTree as ET
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
DEVELOPER = "Xabier Lahuerta"
SHARE_IMAGE = SITE_URL + "assets/icon-512.png"

# App Store Smart App Banner (<meta name="apple-itunes-app">) on every page. Empty until the app is on the
# App Store: set it to the numeric Apple ID from App Store Connect (App Information > Apple ID), e.g.
# "6400000000", rebuild and commit docs/site/. See docs/RELEASE.md.
APP_STORE_ID = ""

SITEMAP_NS = "http://www.sitemaps.org/schemas/sitemap/0.9"
XHTML_NS = "http://www.w3.org/1999/xhtml"

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


def page_path(lang: str, page: str) -> str:
    """Public path of a page relative to the site root: "", "es/", "privacy.html", "es/privacy.html", ..."""
    return folder(lang) + ("" if page == "index" else f"{page}.html")


def page_url(lang: str, page: str) -> str:
    """Absolute public URL of a page; index pages use the folder form (https://folito.app/es/)."""
    return SITE_URL + page_path(lang, page)


def href(from_lang: str, to_lang: str, page: str) -> str:
    """Relative link from any page in from_lang to the given page in to_lang (index pages as folders)."""
    if from_lang == to_lang:
        target = page_path(LANGUAGES[0], page)  # same folder: just the file name, or "./" for the index
    else:
        target = ("../" if folder(from_lang) else "") + page_path(to_lang, page)
    return target or "./"


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


def json_ld(lang: str, strings: dict[str, dict[str, str]]) -> str:
    """schema.org data for a landing page: the app and its developer, in the page's language. No price
    (none is announced yet) and no ratings."""
    s = strings[lang]
    developer = {"@type": "Person", "@id": SITE_URL + "#developer", "name": DEVELOPER, "url": SITE_URL}
    app = {
        "@type": "MobileApplication",
        "@id": SITE_URL + "#app",
        "name": "Folito",
        "description": html.unescape(s["meta.description_index"]),
        "url": page_url(lang, "index"),
        "image": SHARE_IMAGE,
        "operatingSystem": "watchOS, iOS",
        "applicationCategory": "BookApplication",
        "inLanguage": lang,
        "author": {"@id": developer["@id"]},
    }
    data = {"@context": "https://schema.org", "@graph": [app, developer]}
    text = json.dumps(data, ensure_ascii=False, indent=1).replace("</", "<\\/")
    return f'<script type="application/ld+json">\n{text}\n</script>'


def build_page(lang: str, page: str, strings: dict[str, dict[str, str]], templates: dict[str, str]) -> str:
    s = strings[lang]
    url = page_url(lang, page)
    alternates = [f'<link rel="alternate" hreflang="{other}" href="{page_url(other, page)}">'
                  for other in LANGUAGES]
    alternates.append(f'<link rel="alternate" hreflang="x-default" href="{page_url(LANGUAGES[0], page)}">')
    head = []
    if APP_STORE_ID:
        head.append(f'<meta name="apple-itunes-app" content="app-id={APP_STORE_ID}">')
    if page == "index":
        head.append(json_ld(lang, strings))
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
        "description": s[f"meta.description_{page}"],
        "home": href(lang, lang, "index"),
        "share_image": SHARE_IMAGE,
        "head_extra": "".join(item + "\n" for item in head),
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
    outputs[OUT / "robots.txt"] = robots()
    outputs[OUT / "sitemap.xml"] = sitemap()
    problems = validate(outputs)
    if problems:
        raise SystemExit("\n".join(problems))
    return outputs


def robots() -> str:
    return f"User-agent: *\nAllow: /\n\nSitemap: {SITE_URL}sitemap.xml\n"


def sitemap() -> str:
    """Every page in every language, each with its hreflang alternates (x-default is the English page)."""
    lines = ['<?xml version="1.0" encoding="UTF-8"?>',
             f'<urlset xmlns="{SITEMAP_NS}" xmlns:xhtml="{XHTML_NS}">']
    for page in PAGES:
        for lang in LANGUAGES:
            lines.append("<url>")
            lines.append(f"<loc>{page_url(lang, page)}</loc>")
            for other in LANGUAGES:
                lines.append(f'<xhtml:link rel="alternate" hreflang="{other}" href="{page_url(other, page)}"/>')
            lines.append(f'<xhtml:link rel="alternate" hreflang="x-default" href="{page_url(LANGUAGES[0], page)}"/>')
            lines.append("</url>")
    lines.append("</urlset>")
    return "\n".join(lines) + "\n"


def url_to_output(url: str) -> Path | None:
    """The generated file a public URL is served from, or None if the URL is not on this site."""
    if not url.startswith(SITE_URL):
        return None
    path = url[len(SITE_URL):]
    if path == "" or path.endswith("/"):
        path += "index.html"
    return OUT / path


LINK_TAG = re.compile(r"<link\b[^>]*>")
ATTR = re.compile(r'(\w[\w:-]*)="([^"]*)"')


def validate(outputs: dict[Path, str]) -> list[str]:
    """Problems with the generated robots.txt, sitemap.xml and the pages' canonical/hreflang links."""
    problems = []
    expected_hreflangs = set(LANGUAGES) | {"x-default"}
    sitemap_url = SITE_URL + "sitemap.xml"

    robots_txt = outputs.get(OUT / "robots.txt")
    if robots_txt is None:
        problems.append("robots.txt is not generated")
    else:
        if f"Sitemap: {sitemap_url}" not in robots_txt.splitlines():
            problems.append(f"robots.txt does not point to {sitemap_url}")
        if any(line.strip().lower() == "disallow: /" for line in robots_txt.splitlines()):
            problems.append("robots.txt blocks the whole site")

    def check_target(where: str, url: str) -> None:
        target = url_to_output(url)
        if target is None or target not in outputs:
            problems.append(f"{where}: {url} is not a generated page")

    text = outputs.get(OUT / "sitemap.xml")
    if text is None:
        problems.append("sitemap.xml is not generated")
    else:
        try:
            root = ET.fromstring(text.encode("utf-8"))
        except ET.ParseError as e:
            problems.append(f"sitemap.xml is not well-formed XML: {e}")
            root = None
        if root is not None:
            if root.tag != f"{{{SITEMAP_NS}}}urlset":
                problems.append("sitemap.xml: root element is not a sitemap <urlset>")
            listed = []
            for entry in root.findall(f"{{{SITEMAP_NS}}}url"):
                loc = (entry.findtext(f"{{{SITEMAP_NS}}}loc") or "").strip()
                listed.append(loc)
                check_target("sitemap.xml <loc>", loc)
                links = entry.findall(f"{{{XHTML_NS}}}link")
                langs = [link.get("hreflang") for link in links]
                if set(langs) != expected_hreflangs or len(langs) != len(expected_hreflangs):
                    problems.append(f"sitemap.xml: {loc} hreflang alternates are {sorted(map(str, langs))}, "
                                    f"expected {sorted(expected_hreflangs)}")
                for link in links:
                    check_target(f"sitemap.xml hreflang {link.get('hreflang')} of {loc}", link.get("href") or "")
                if loc not in {link.get("href") for link in links}:
                    problems.append(f"sitemap.xml: {loc} is not among its own hreflang alternates")
            for url in sorted({page_url(lang, page) for lang in LANGUAGES for page in PAGES} - set(listed)):
                problems.append(f"sitemap.xml does not list {url}")
            for url in sorted({u for u in listed if listed.count(u) > 1}):
                problems.append(f"sitemap.xml lists {url} more than once")

    for path, page_text in outputs.items():
        if path.suffix != ".html":
            continue
        where = str(path.relative_to(OUT))
        hreflangs = []
        for tag in LINK_TAG.findall(page_text):
            attrs = dict(ATTR.findall(tag))
            if attrs.get("rel") == "canonical":
                check_target(f"{where} canonical", attrs.get("href", ""))
            elif attrs.get("rel") == "alternate" and "hreflang" in attrs:
                hreflangs.append(attrs["hreflang"])
                check_target(f"{where} hreflang {attrs['hreflang']}", attrs.get("href", ""))
        if set(hreflangs) != expected_hreflangs:
            problems.append(f"{where}: hreflang alternates are {sorted(hreflangs)}, expected {sorted(expected_hreflangs)}")
    return problems


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
        print(f"docs/site/ is up to date ({len(outputs)} files, {len(LANGUAGES)} languages).")
        return 0

    for path, text in outputs.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
    for orphan in sorted(existing - set(outputs)):
        orphan.unlink()
    print(f"Wrote {len(outputs)} files ({len(LANGUAGES)} languages) to {OUT.relative_to(REPO)}/")
    return 0


if __name__ == "__main__":
    sys.exit(main())
