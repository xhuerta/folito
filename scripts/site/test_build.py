"""Tests for scripts/site/build.py. Run: python3 -m unittest discover -s scripts/site"""

from __future__ import annotations

import json
import re
import sys
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import build  # noqa: E402

OUT = build.OUT


class SiteBuildTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.outputs = build.build()

    def test_generated_output_is_valid(self) -> None:
        self.assertEqual(build.validate(self.outputs), [])

    def test_robots_allows_all_and_points_to_sitemap(self) -> None:
        robots = self.outputs[OUT / "robots.txt"].splitlines()
        self.assertIn("User-agent: *", robots)
        self.assertIn("Allow: /", robots)
        self.assertIn("Sitemap: https://folito.app/sitemap.xml", robots)

    def test_sitemap_lists_every_page_with_alternates(self) -> None:
        root = ET.fromstring(self.outputs[OUT / "sitemap.xml"].encode("utf-8"))
        ns = {"s": build.SITEMAP_NS, "x": build.XHTML_NS}
        locs = [u.findtext("s:loc", namespaces=ns) for u in root.findall("s:url", ns)]
        self.assertEqual(len(locs), len(build.LANGUAGES) * len(build.PAGES))
        self.assertIn("https://folito.app/", locs)
        self.assertIn("https://folito.app/es/", locs)
        self.assertIn("https://folito.app/pt-br/support.html", locs)
        self.assertFalse([loc for loc in locs if loc.endswith("index.html")])
        for entry in root.findall("s:url", ns):
            langs = {link.get("hreflang") for link in entry.findall("x:link", ns)}
            self.assertEqual(langs, set(build.LANGUAGES) | {"x-default"})

    def test_index_pages_use_folder_urls(self) -> None:
        es = self.outputs[OUT / "es" / "index.html"]
        self.assertIn('<link rel="canonical" href="https://folito.app/es/">', es)
        self.assertIn('<link rel="alternate" hreflang="x-default" href="https://folito.app/">', es)
        self.assertNotIn("index.html", es)
        self.assertIn('<link rel="canonical" href="https://folito.app/privacy.html">',
                      self.outputs[OUT / "privacy.html"])

    def test_internal_links(self) -> None:
        self.assertEqual(build.href("en", "en", "index"), "./")
        self.assertEqual(build.href("es", "es", "index"), "./")
        self.assertEqual(build.href("en", "es", "index"), "es/")
        self.assertEqual(build.href("es", "en", "index"), "../")
        self.assertEqual(build.href("es", "fr", "index"), "../fr/")
        self.assertEqual(build.href("es", "es", "support"), "support.html")
        self.assertEqual(build.href("es", "en", "privacy"), "../privacy.html")

    def test_landing_pages_have_localized_json_ld(self) -> None:
        for lang in build.LANGUAGES:
            text = self.outputs[OUT / build.folder(lang) / "index.html"]
            match = re.search(r'<script type="application/ld\+json">\n(.*?)\n</script>', text, re.S)
            self.assertIsNotNone(match, lang)
            graph = json.loads(match.group(1))["@graph"]
            app = next(item for item in graph if item["@type"] == "MobileApplication")
            self.assertEqual(app["name"], "Folito")
            self.assertEqual(app["operatingSystem"], "watchOS, iOS")
            self.assertEqual(app["applicationCategory"], "BookApplication")
            self.assertEqual(app["inLanguage"], lang)
            self.assertEqual(app["url"], build.page_url(lang, "index"))
            self.assertNotIn("aggregateRating", app)
            self.assertEqual(app["offers"], {"@type": "Offer", "price": "0", "priceCurrency": "USD"})
            self.assertNotIn("downloadUrl", app)
            self.assertTrue(any(item["@type"] == "Person" and item["name"] == "Xabier Lahuerta" for item in graph))
        self.assertNotIn("application/ld+json", self.outputs[OUT / "support.html"])

    def test_smart_app_banner_only_with_app_store_id(self) -> None:
        self.assertNotIn("apple-itunes-app", self.outputs[OUT / "index.html"])
        original = build.APP_STORE_ID
        try:
            build.APP_STORE_ID = "123456789"
            outputs = build.build()
        finally:
            build.APP_STORE_ID = original
        self.assertIn('<meta name="apple-itunes-app" content="app-id=123456789">', outputs[OUT / "es" / "support.html"])

    def test_call_to_action_switches_with_app_store_id(self) -> None:
        index = self.outputs[OUT / "index.html"]
        self.assertIn('<p class="pill">', index)
        self.assertNotIn('class="cta"', index)
        original = build.APP_STORE_ID
        try:
            build.APP_STORE_ID = "123456789"
            outputs = build.build()
        finally:
            build.APP_STORE_ID = original
        for lang in build.LANGUAGES:
            text = outputs[OUT / build.folder(lang) / "index.html"]
            self.assertIn('<a class="cta" href="https://apps.apple.com/app/id123456789">', text, lang)
            self.assertNotIn('<p class="pill">', text, lang)
        self.assertIn('"downloadUrl": "https://apps.apple.com/app/id123456789"', outputs[OUT / "index.html"])

    def test_every_index_has_five_localized_screenshots(self) -> None:
        for lang in build.LANGUAGES:
            text = self.outputs[OUT / build.folder(lang) / "index.html"]
            self.assertNotIn("TODO(#54)", text, lang)
            strip = re.search(r'<ul class="shots"[^>]*>\n(.*?)\n</ul>', text, re.S)
            self.assertIsNotNone(strip, lang)
            images = re.findall(r"<img\b[^>]*>", strip.group(1))
            self.assertEqual(len(images), 5, lang)
            alts = set()
            for tag in images:
                attrs = dict(build.ATTR.findall(tag))
                self.assertTrue(attrs.get("alt", "").strip(), (lang, tag))
                alts.add(attrs["alt"])
                self.assertEqual((attrs.get("width"), attrs.get("height")), ("600", "1304"), (lang, tag))
                self.assertIn(f"assets/screenshots/{lang.lower()}/", attrs["src"], lang)
                data = self.outputs[(OUT / build.folder(lang) / attrs["src"]).resolve()]
                self.assertEqual(build.webp_size(data), (600, 1304), (lang, attrs["src"]))
            self.assertEqual(len(alts), 5, f"{lang}: duplicate alt texts")

    def test_validate_rejects_missing_screenshot(self) -> None:
        outputs = dict(self.outputs)
        del outputs[OUT / "assets" / "screenshots" / "ja" / "03-send.webp"]
        self.assertIn("ja/index.html: image ../assets/screenshots/ja/03-send.webp is not generated",
                      build.validate(outputs))

    def test_titles_and_descriptions(self) -> None:
        strings = build.load_strings()
        for lang, s in strings.items():
            self.assertIn("Apple Watch", s["meta.title_index"], lang)
            self.assertIn("EPUB", s["meta.title_index"], lang)
            for page in build.PAGES:
                self.assertLessEqual(len(s[f"meta.title_{page}"]), 60, (lang, page))
                self.assertLessEqual(len(s[f"meta.description_{page}"]), 155, (lang, page))
            descriptions = [s[f"meta.description_{page}"] for page in build.PAGES]
            self.assertEqual(len(set(descriptions)), len(descriptions), f"{lang}: duplicate descriptions")

    # validate() must catch broken output.

    def broken(self, name: str, text: str) -> list[str]:
        outputs = dict(self.outputs)
        outputs[OUT / name] = text
        return build.validate(outputs)

    def test_validate_rejects_malformed_sitemap(self) -> None:
        problems = self.broken("sitemap.xml", "<urlset><url></urlset>")
        self.assertTrue(any("not well-formed" in p for p in problems), problems)

    def test_validate_rejects_missing_page(self) -> None:
        sitemap = self.outputs[OUT / "sitemap.xml"]
        entry = re.search(r"<url>\n<loc>https://folito.app/es/</loc>\n.*?</url>\n", sitemap, re.S).group(0)
        problems = self.broken("sitemap.xml", sitemap.replace(entry, ""))
        self.assertIn("sitemap.xml does not list https://folito.app/es/", problems)

    def test_validate_rejects_missing_hreflang_target(self) -> None:
        sitemap = self.outputs[OUT / "sitemap.xml"].replace(
            'hreflang="ja" href="https://folito.app/ja/"', 'hreflang="ja" href="https://folito.app/jp/"')
        problems = self.broken("sitemap.xml", sitemap)
        self.assertTrue(any("https://folito.app/jp/ is not a generated page" in p for p in problems), problems)

    def test_validate_rejects_broken_page_alternate(self) -> None:
        page = self.outputs[OUT / "fr" / "support.html"].replace(
            'href="https://folito.app/de/support.html"', 'href="https://folito.app/de/help.html"')
        problems = self.broken("fr/support.html", page)
        self.assertTrue(any(p.startswith("fr/support.html hreflang de") for p in problems), problems)

    def test_validate_rejects_robots_without_sitemap(self) -> None:
        problems = self.broken("robots.txt", "User-agent: *\nDisallow: /\n")
        self.assertIn("robots.txt does not point to https://folito.app/sitemap.xml", problems)
        self.assertIn("robots.txt blocks the whole site", problems)


if __name__ == "__main__":
    unittest.main()
