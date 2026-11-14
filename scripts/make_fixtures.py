#!/usr/bin/env python3
"""Generate tiny, deterministic EPUB fixtures for the ReaderCore EPUB tests.

Usage: scripts/make_fixtures.py [output_dir]
Default output: Packages/ReaderCore/Tests/Fixtures
"""
import os
import struct
import sys
import zipfile
import zlib

CONTAINER = """<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>"""

XHTML_HEAD = ('<?xml version="1.0" encoding="utf-8"?>\n'
              '<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">\n'
              '<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">'
              '<head><title>t</title><style>p { color: red }</style></head>')


def xhtml(body):
    return XHTML_HEAD + "<body>" + body + "</body></html>"


def opf(title, creators, lang, identifiers, manifest, spine, version="2.0", toc="ncx"):
    ids = "".join(
        '<dc:identifier id="id%d"%s>%s</dc:identifier>' % (
            i, (' opf:scheme="%s"' % s) if s else "", v)
        for i, (s, v) in enumerate(identifiers))
    cr = "".join('<dc:creator opf:role="aut">%s</dc:creator>' % c for c in creators)
    items = "".join(
        '<item id="%s" href="%s" media-type="%s"%s/>' % (i, h, m, (' properties="%s"' % p) if p else "")
        for (i, h, m, p) in manifest)
    refs = "".join('<itemref idref="%s"%s/>' % (r, ' linear="no"' if not lin else "") for (r, lin) in spine)
    toc_attr = (' toc="%s"' % toc) if toc else ""
    return ('<?xml version="1.0" encoding="UTF-8"?>\n'
            '<package xmlns="http://www.idpf.org/2007/opf" version="%s" unique-identifier="id0">'
            '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">'
            '<dc:title>%s</dc:title>%s<dc:language>%s</dc:language>%s</metadata>'
            '<manifest>%s</manifest><spine%s>%s</spine></package>') % (
        version, title, cr, lang, ids, items, toc_attr, refs)


def ncx(points):
    pts = "".join(
        '<navPoint id="n%d" playOrder="%d"><navLabel><text>%s</text></navLabel><content src="%s"/></navPoint>'
        % (i, i + 1, t, s) for i, (t, s) in enumerate(points))
    return ('<?xml version="1.0"?><ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">'
            '<head/><docTitle><text>x</text></docTitle><navMap>%s</navMap></ncx>' % pts)


def nav(points):
    lis = "".join('<li><a href="%s">%s</a></li>' % (s, t) for t, s in points)
    return xhtml('<nav epub:type="toc"><ol>%s</ol></nav>'
                 '<nav epub:type="landmarks"><ol><li><a href="c1.xhtml">Landmark</a></li></ol></nav>' % lis)


def write_epub(path, files, raw_container=None):
    info_date = (2020, 1, 1, 0, 0, 0)
    with zipfile.ZipFile(path, "w") as z:
        zi = zipfile.ZipInfo("mimetype", info_date)
        z.writestr(zi, "application/epub+zip", compress_type=zipfile.ZIP_STORED)
        zi = zipfile.ZipInfo("META-INF/container.xml", info_date)
        z.writestr(zi, raw_container or CONTAINER, compress_type=zipfile.ZIP_DEFLATED)
        for name, data in files.items():
            zi = zipfile.ZipInfo(name, info_date)
            if isinstance(data, str):
                data = data.encode("utf-8")
            z.writestr(zi, data, compress_type=zipfile.ZIP_DEFLATED)


XH = "application/xhtml+xml"


def build(out):
    # 1. simple (EPUB2 + NCX)
    write_epub(os.path.join(out, "simple.epub"), {
        "OEBPS/content.opf": opf("Simple Book", ["Jane Author", "John Coauthor"], "en",
                                 [("UUID", "urn:uuid:1234"), ("ISBN", "9781234567890")],
                                 [("ncx", "toc.ncx", "application/x-dtbncx+xml", None), ("c1", "c1.xhtml", XH, None)],
                                 [("c1", True)]),
        "OEBPS/toc.ncx": ncx([("Chapter One", "c1.xhtml")]),
        "OEBPS/c1.xhtml": xhtml("<h1>Chapter One</h1>\n<p>Hello,   world.\n  Second line.</p>\n<p>Another paragraph.</p>"),
    })
    # 2. nested divs / mixed content / blockquote / list
    write_epub(os.path.join(out, "nested.epub"), {
        "OEBPS/content.opf": opf("Nested", ["N"], "en", [(None, "nested-1")],
                                 [("c1", "c1.xhtml", XH, None)], [("c1", True)], toc=None),
        "OEBPS/c1.xhtml": xhtml(
            "<div class=\"a\"><div class=\"b\"><p>Inner one</p><p>Inner two</p></div>"
            "Tail text<div>Deep <span>span <em>em</em></span> text</div></div>"
            "<blockquote><p>Quoted</p></blockquote><ul><li>Item A</li><li>Item <b>B</b></li></ul>"
            "<div><img src=\"x.png\"/></div><p>   </p><h2>Sub</h2>"),
    })
    # 3. inline styles
    write_epub(os.path.join(out, "inline.epub"), {
        "OEBPS/content.opf": opf("Inline", ["I"], "en", [(None, "inline-1")],
                                 [("c1", "c1.xhtml", XH, None)], [("c1", True)], toc=None),
        "OEBPS/c1.xhtml": xhtml(
            "<p>Plain <b>bold</b> and <i>italic</i> and <strong><em>both</em></strong> end.</p>"
            "<p><b>All bold</b></p><p>a<b>b</b><b>c</b>d</p>"),
    })
    # 4. multi spine: linear=no item, svg cover item, EPUB3 nav
    write_epub(os.path.join(out, "multispine.epub"), {
        "OEBPS/content.opf": opf("Multi", ["M"], "fr", [(None, "multi-1")],
                                 [("nav", "nav.xhtml", XH, "nav"),
                                  ("cover", "cover.svg", "image/svg+xml", None),
                                  ("c1", "text/c1.xhtml", XH, None),
                                  ("c2", "text/c2.xhtml", XH, None),
                                  ("c3", "text/c3.xhtml", XH, None)],
                                 [("cover", True), ("c1", True), ("c2", False), ("c3", True)],
                                 version="3.0", toc=None),
        "OEBPS/nav.xhtml": nav([("Un", "text/c1.xhtml"), ("Deux", "text/c2.xhtml#s1"), ("Trois", "text/c3.xhtml")]),
        "OEBPS/cover.svg": "<svg xmlns=\"http://www.w3.org/2000/svg\"><text>cover</text></svg>",
        "OEBPS/text/c1.xhtml": xhtml("<p>One</p>"),
        "OEBPS/text/c2.xhtml": xhtml("<p>Two</p>"),
        "OEBPS/text/c3.xhtml": xhtml("<p>Three</p>"),
    })
    # 5. entities + not well-formed XHTML
    write_epub(os.path.join(out, "entities.epub"), {
        "OEBPS/content.opf": opf("Entities &amp; More", ["E"], "en", [(None, "ent-1")],
                                 [("c1", "c1.xhtml", XH, None), ("c2", "c2.xhtml", XH, None)],
                                 [("c1", True), ("c2", True)], toc=None),
        "OEBPS/c1.xhtml": xhtml("<p>A&nbsp;B &copy; &eacute;t&eacute; &mdash; &#8212; &#x41; &amp; &lt;ok&gt;</p>"),
        "OEBPS/c2.xhtml": ("<html><body><p>Unclosed <br>break &unknown; AT&T"
                           "<p>Second <b>bold</p><p>Third</body></html>"),
    })
    # 6. unicode
    write_epub(os.path.join(out, "unicode.epub"), {
        "OEBPS/content.opf": opf("日本語の本", ["山田 太郎"], "ja", [(None, "uni-1")],
                                 [("c1", "c1.xhtml", XH, None)], [("c1", True)], toc=None),
        "OEBPS/c1.xhtml": xhtml("<p>日本語のテキスト。</p><p>Emoji \U0001F600 and é combining.</p>"),
    })


def build_toc(out):
    """Table-of-contents fixtures (several chapters per file, group headings, NCX-only, odd hrefs)."""
    # Parts with several chapters per file: fragments on headings, a wrapper div, an inline span mid-paragraph,
    # an empty <a id>, <a name>, an id inside svg, an image-only paragraph and a missing id. The nav has a
    # <span> group heading, an <a> labelled only by @title, a hidden sub-list, landmarks and a page-list;
    # the stale NCX disagrees and must lose.
    toc_nav = xhtml(
        '<nav epub:type="toc"><h1>Contents</h1><ol>'
        '<li><a href="part1.xhtml#p1">Part One</a><ol hidden="">'
        '<li><a href="part1.xhtml#c1">Chapter 1</a></li>'
        '<li><a href="part1.xhtml#c2">Chapter 2</a></li>'
        '<li><a href="part1.xhtml#c3">Chapter 3</a></li></ol></li>'
        '<li><span>Part Two</span><ol>'
        '<li><a href="part2.xhtml#c4">Chapter 4</a></li>'
        '<li><a href="part2.xhtml#c5">Chapter 5</a></li>'
        '<li><a href="part2.xhtml#c6" title="Chapter 6"></a></li></ol></li>'
        '<li><a href="part3.xhtml#fig">Figure</a></li>'
        '<li><a href="part3.xhtml#img">Image</a></li>'
        '<li><a href="part3.xhtml#missing">Missing</a></li>'
        '<li><a href="https://example.com/">External</a></li>'
        '</ol></nav>'
        '<nav epub:type="landmarks" hidden=""><ol><li><a epub:type="bodymatter" href="part1.xhtml">Start</a></li></ol></nav>'
        '<nav epub:type="page-list" hidden=""><ol><li><a href="part1.xhtml#c2">2</a></li></ol></nav>')
    write_epub(os.path.join(out, "toc_parts.epub"), {
        "OEBPS/content.opf": opf("Parts", ["P"], "en", [(None, "toc-parts-1")],
                                 [("nav", "nav.xhtml", XH, "nav"), ("ncx", "toc.ncx", "application/x-dtbncx+xml", None),
                                  ("p1", "part1.xhtml", XH, None), ("p2", "part2.xhtml", XH, None),
                                  ("p3", "part3.xhtml", XH, None)],
                                 [("p1", True), ("p2", True), ("p3", True)], version="3.0"),
        "OEBPS/nav.xhtml": toc_nav,
        "OEBPS/toc.ncx": ncx([("Stale One", "part1.xhtml"), ("Stale Two", "part2.xhtml")]),
        "OEBPS/part1.xhtml": xhtml(
            '<h1 id="p1">Part One</h1><h2 id="c1">Chapter 1</h2><p>Body one.</p>'
            '<h2 id="c2">Chapter 2</h2><p>Body two.</p>'
            '<div id="c3" class="chapter"><h2>Chapter 3</h2><p>Body three.</p></div>'),
        "OEBPS/part2.xhtml": xhtml(
            '<h1>Part Two</h1><p>Intro text. <span id="c4"></span>Chapter four starts here.</p>'
            '<p>Four body.</p><a id="c5"></a><h2>Chapter 5</h2><p>Five body.</p>'
            '<p><a name="c6"></a>Chapter six text.</p>'),
        "OEBPS/part3.xhtml": xhtml(
            '<p>Before figure.</p><svg xmlns="http://www.w3.org/2000/svg"><g id="fig"><text>x</text></g></svg>'
            '<p>After figure.</p><p id="img"><img src="x.png" alt=""/></p><p>After image.</p>'),
    })
    # EPUB 2, NCX only: nesting, wrong/duplicate playOrder, an empty label, percent-encoded hrefs and ids,
    # a textless spine item, a chapter split over two files, a non-spine and a missing target, and an
    # out-of-order duplicate.
    points = [
        (0, 3, "Book One", "Text/Chapter%201.xhtml"),
        (1, 1, "Chapter One", "Text/Chapter%201.xhtml#c1"),
        (1, 1, "", "Text/Chapter%201.xhtml#c2"),
        (0, 7, "Book Two", "Text/blank.xhtml"),
        (1, 2, "Été", "Text/%C3%A9t%C3%A9.xhtml#%C3%A9t%C3%A9"),
        (1, 4, "Split", "Text/ch5_split_000.xhtml"),
        (0, 5, "Notes", "Text/notes.xhtml"),
        (0, 6, "Missing", "Text/missing.xhtml"),
        (0, 2, "Again", "Text/Chapter%201.xhtml#c1"),
    ]
    xml, depth = "", -1
    for i, (d, order, label, src) in enumerate(points):
        if d <= depth:
            xml += "</navPoint>" * (depth - d + 1)
        xml += ('<navPoint id="n%d" playOrder="%d"><navLabel><text>%s</text></navLabel><content src="%s"/>'
                % (i, order, label, src))
        depth = d
    xml += "</navPoint>" * (depth + 1)
    write_epub(os.path.join(out, "toc_ncx.epub"), {
        "OEBPS/content.opf": opf("NCX Only", ["N"], "en", [(None, "toc-ncx-1")],
                                 [("ncx", "toc.ncx", "application/x-dtbncx+xml", None),
                                  ("a", "Text/Chapter%201.xhtml", XH, None), ("b", "Text/blank.xhtml", XH, None),
                                  ("e", "Text/%C3%A9t%C3%A9.xhtml", XH, None),
                                  ("s0", "Text/ch5_split_000.xhtml", XH, None), ("s1", "Text/ch5_split_001.xhtml", XH, None),
                                  ("notes", "Text/notes.xhtml", XH, None)],
                                 [("a", True), ("b", True), ("e", True), ("s0", True), ("s1", True)]),
        "OEBPS/toc.ncx": ('<?xml version="1.0"?><ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">'
                          '<head/><docTitle><text>x</text></docTitle><navMap>%s</navMap>'
                          '<pageList><pageTarget id="pg1" type="normal" value="1"><navLabel><text>1</text></navLabel>'
                          '<content src="Text/Chapter%%201.xhtml"/></pageTarget></pageList></ncx>' % xml),
        "OEBPS/Text/Chapter 1.xhtml": xhtml(
            '<section id="c1"><h2>First Heading</h2><p>One.</p></section><h2 id="c2">Second Heading</h2><p>Two.</p>'),
        "OEBPS/Text/blank.xhtml": xhtml('<div><img src="x.png" alt=""/></div>'),
        "OEBPS/Text/été.xhtml": xhtml('<p>Intro.</p><h2 id="été">Été</h2><p>Summer.</p>'),
        "OEBPS/Text/ch5_split_000.xhtml": xhtml('<h2>Split</h2><p>First half.</p>'),
        "OEBPS/Text/ch5_split_001.xhtml": xhtml('<p>Second half.</p>'),
        "OEBPS/Text/notes.xhtml": xhtml('<p>A note.</p>'),
    })
    # No nav, no NCX: the TOC falls back to h1-h3 headings (h1 then h3 still nests one level deep).
    write_epub(os.path.join(out, "toc_none.epub"), {
        "OEBPS/content.opf": opf("No TOC", ["X"], "en", [(None, "toc-none-1")],
                                 [("c1", "c1.xhtml", XH, None), ("c2", "c2.xhtml", XH, None)],
                                 [("c1", True), ("c2", True)], toc=None),
        "OEBPS/c1.xhtml": xhtml('<h1>Alpha</h1><p>a</p><h3>Alpha sub</h3><p>b</p><h4>Too deep</h4><p>c</p>'),
        "OEBPS/c2.xhtml": xhtml('<h2>Beta</h2><p>d</p>'),
    })


def tiny_png(w=2, h=3, rgb=(0x3D, 0x5A, 0x80)):
    """A valid w x h solid-colour PNG, built without third-party modules."""
    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
    raw = b"".join(b"\x00" + bytes(rgb) * w for _ in range(h))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


# Not decodable; the parser never decodes images, it only finds them.
FAKE_JPEG = b"\xff\xd8\xff\xe0fixture-jpeg\xff\xd9"
FAKE_GIF = b"GIF89a-fixture"

OPF_NS = ('<?xml version="1.0" encoding="UTF-8"?>\n'
          '<package xmlns="http://www.idpf.org/2007/opf" version="%s" unique-identifier="id0">'
          '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">')


def build_covers(out):
    # EPUB 3: cover-image property, belongs-to-collection series, refined roles, escaped-HTML description.
    write_epub(os.path.join(out, "cover_epub3.epub"), {
        "OEBPS/content.opf": (OPF_NS % "3.0") +
        '<dc:identifier id="id0">urn:uuid:5e1a0000-0000-0000-0000-000000000001</dc:identifier>'
        '<dc:identifier id="isbn">urn:isbn:978-0-441-17271-9</dc:identifier>'
        '<dc:title>Dune Messiah</dc:title>'
        '<dc:creator id="c1">Frank Herbert</dc:creator>'
        '<meta refines="#c1" property="role" scheme="marc:relators">aut</meta>'
        '<meta refines="#c1" property="file-as">Herbert, Frank</meta>'
        '<dc:creator id="c2">Some Illustrator</dc:creator>'
        '<meta refines="#c2" property="role" scheme="marc:relators">ill</meta>'
        '<dc:description>&lt;p&gt;The &lt;b&gt;second&lt;/b&gt; book.&lt;/p&gt;&lt;p&gt;Paul rules &amp;amp; doubts.&lt;/p&gt;</dc:description>'
        '<dc:publisher>Ace</dc:publisher>'
        '<dc:date>1969-10-15</dc:date>'
        '<dc:language>en</dc:language>'
        '<dc:subject>Science fiction</dc:subject><dc:subject>Dune (Imaginary place)</dc:subject>'
        '<dc:subject>Science fiction</dc:subject>'
        '<meta property="belongs-to-collection" id="s1">Dune</meta>'
        '<meta refines="#s1" property="collection-type">series</meta>'
        '<meta refines="#s1" property="group-position">2</meta>'
        '<meta property="dcterms:modified">2020-01-01T00:00:00Z</meta>'
        '</metadata><manifest>'
        '<item id="img" href="images/cover.png" media-type="image/png" properties="cover-image"/>'
        '<item id="c1x" href="c1.xhtml" media-type="application/xhtml+xml"/>'
        '</manifest><spine><itemref idref="c1x"/></spine></package>',
        "OEBPS/images/cover.png": tiny_png(),
        "OEBPS/c1.xhtml": xhtml("<p>Text.</p>"),
    })
    # EPUB 2: <meta name="cover">, calibre series, opf:role/opf:file-as, plain description, ISBN-10 scheme.
    write_epub(os.path.join(out, "cover_meta.epub"), {
        "OEBPS/content.opf": (OPF_NS % "2.0") +
        '<dc:identifier id="id0" opf:scheme="calibre">c0ffee</dc:identifier>'
        '<dc:identifier opf:scheme="ISBN">0-306-40615-2</dc:identifier>'
        '<dc:title>Second Tale</dc:title>'
        '<dc:creator opf:role="aut" opf:file-as="Writer, Ann">Ann Writer</dc:creator>'
        '<dc:creator opf:role="edt">Ed Itor</dc:creator>'
        '<dc:creator opf:role="aut">Bo Coauthor</dc:creator>'
        '<dc:description>First paragraph.\n\nSecond   paragraph.</dc:description>'
        '<dc:date opf:event="modification">2020-02-02</dc:date>'
        '<dc:date opf:event="publication">2003</dc:date>'
        '<dc:language>es</dc:language>'
        '<meta name="calibre:series" content="The Tales"/>'
        '<meta name="calibre:series_index" content="2.5"/>'
        '<meta name="cover" content="cov"/>'
        '</metadata><manifest>'
        '<item id="cov" href="cover.jpg" media-type="image/jpeg"/>'
        '<item id="c1x" href="c1.xhtml" media-type="application/xhtml+xml"/>'
        '</manifest><spine><itemref idref="c1x"/></spine></package>',
        "OEBPS/cover.jpg": FAKE_JPEG,
        "OEBPS/c1.xhtml": xhtml("<p>Text.</p>"),
    })
    # Guide reference to a cover page holding an <img>; no other cover markers.
    write_epub(os.path.join(out, "cover_guide.epub"), {
        "OEBPS/content.opf": (OPF_NS % "2.0") +
        '<dc:identifier id="id0">guide-1</dc:identifier><dc:title>Guided</dc:title>'
        '<dc:creator>No Role</dc:creator><dc:language>en</dc:language>'
        '</metadata><manifest>'
        '<item id="cp" href="text/cover.xhtml" media-type="application/xhtml+xml"/>'
        '<item id="ci" href="images/c.gif" media-type="image/gif"/>'
        '<item id="c1x" href="text/c1.xhtml" media-type="application/xhtml+xml"/>'
        '</manifest><spine><itemref idref="c1x"/></spine>'
        '<guide><reference type="cover" title="Cover" href="text/cover.xhtml"/></guide></package>',
        "OEBPS/text/cover.xhtml": xhtml('<div><img src="../images/c.gif" alt="cover"/></div>'),
        "OEBPS/images/c.gif": FAKE_GIF,
        "OEBPS/text/c1.xhtml": xhtml("<p>Text.</p>"),
    })
    # Only the first spine item points at the cover, through an SVG <image xlink:href>.
    write_epub(os.path.join(out, "cover_spine.epub"), {
        "OEBPS/content.opf": (OPF_NS % "2.0") +
        '<dc:identifier id="id0">spine-1</dc:identifier><dc:title>Spined</dc:title>'
        '<dc:language>en</dc:language>'
        '</metadata><manifest>'
        '<item id="t" href="titlepage.xhtml" media-type="application/xhtml+xml"/>'
        '<item id="ci" href="img/c.jpeg" media-type="image/jpeg"/>'
        '<item id="c1x" href="c1.xhtml" media-type="application/xhtml+xml"/>'
        '</manifest><spine><itemref idref="t"/><itemref idref="c1x"/></spine></package>',
        "OEBPS/titlepage.xhtml": xhtml('<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" '
                                       'viewBox="0 0 2 3"><image width="2" height="3" xlink:href="img/c.jpeg"/></svg>'),
        "OEBPS/img/c.jpeg": FAKE_JPEG,
        "OEBPS/c1.xhtml": xhtml("<p>Text.</p>"),
    })


if __name__ == "__main__":
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(root, "Packages/ReaderCore/Tests/Fixtures")
    os.makedirs(out, exist_ok=True)
    build(out)
    build_covers(out)
    build_toc(out)
    print("fixtures written to", out)
