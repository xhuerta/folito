#!/usr/bin/env python3
"""Build the bundled sample books (iOSApp/Resources/SampleBooks/sample-<lang>.epub) from docs/samples-src/.

Each source file docs/samples-src/<lang>.txt holds one public-domain excerpt in a tiny plain-text format:

    title: Pride and Prejudice          <- front matter, one "key: value" per line, up to a line "---"
    author: Jane Austen
    language: en                        <- BCP 47 tag, written to dc:language and the XHTML lang attributes
    published: 1813
    source: https://www.gutenberg.org/ebooks/42671
    source-name: Project Gutenberg eBook #42671
    excerpt: Chapters I–VI
    rights: Public domain. ...
    ---

    ## Chapter I                        <- a new chapter (one XHTML file); "##" alone: a chapter with no heading

    It is a truth universally ...       <- every other non-empty line is one paragraph
    > An indented passage               <- consecutive "> " lines form a block quotation
    A _word_ in italics                 <- _..._ pairs become <i> (left as-is when a line has an odd count)

The output is a valid EPUB 3 (with an EPUB 2 NCX for older readers): the "mimetype" entry first and stored,
META-INF/container.xml, an OPF package with dc:language, dc:source and dc:rights, a navigation document, an
NCX, a text-only SVG cover, a small stylesheet and one XHTML file per chapter. The build is reproducible:
fixed ZIP timestamps and order, a fixed dcterms:modified and a name-based UUID identifier.

The app imports these files through its normal EPUB import pipeline (see iOSApp/Library/SampleBooks.swift);
docs/SAMPLE_BOOKS.md lists the sources and why each text is in the public domain.

Usage:
    python3 scripts/samples/build_samples.py            # write iOSApp/Resources/SampleBooks/*.epub
    python3 scripts/samples/build_samples.py --check    # exit 1 if a committed EPUB differs from a fresh build

--check compares the archive contents (entry names, order, compression method and bytes), not the compressed
bytes, so a different zlib build cannot make it fail. Standard library only.
"""

from __future__ import annotations

import argparse
import html
import io
import re
import sys
import uuid
import zipfile
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
SOURCE_DIR = ROOT / "docs" / "samples-src"
OUTPUT_DIR = ROOT / "iOSApp" / "Resources" / "SampleBooks"

# Keep in sync with SampleBooks.languages (iOSApp/Library/SampleBooks.swift) and the ReaderCore test
# SampleBooksTests. The app's 8 languages; English is the fallback.
LANGUAGES = ["en", "es", "fr", "de", "it", "pt-BR", "ja", "zh-Hans"]

# Fixed so that a rebuild is byte-for-byte reproducible. Bump it when the content changes.
MODIFIED = "2026-11-03T00:00:00Z"
ZIP_DATE = (1980, 1, 1, 0, 0, 0)
UUID_NAMESPACE = uuid.uuid5(uuid.NAMESPACE_URL, "https://folito.app/samples/")
REQUIRED_KEYS = ["title", "author", "language", "published", "source", "source-name", "excerpt", "rights"]
CJK_LANGUAGES = {"ja", "zh-Hans"}


@dataclass
class Chapter:
    title: str
    # ("p", text) or ("quote", [texts])
    blocks: list[tuple[str, object]] = field(default_factory=list)


@dataclass
class Book:
    lang: str
    meta: dict[str, str]
    chapters: list[Chapter]


class SourceError(Exception):
    pass


def parse_source(path: Path) -> Book:
    text = path.read_text(encoding="utf-8")
    head, sep, body = text.partition("\n---\n")
    if not sep:
        raise SourceError(f"{path}: missing '---' after the front matter")
    meta: dict[str, str] = {}
    for line in head.splitlines():
        key, colon, value = line.partition(":")
        if not colon:
            raise SourceError(f"{path}: front matter line without 'key: value': {line!r}")
        meta[key.strip()] = value.strip()
    missing = [k for k in REQUIRED_KEYS if not meta.get(k)]
    if missing:
        raise SourceError(f"{path}: missing front matter keys {missing}")
    lang = path.stem
    if meta["language"] != lang:
        raise SourceError(f"{path}: language {meta['language']!r} does not match the file name")

    chapters: list[Chapter] = []
    for line in body.splitlines():
        line = line.strip()
        if not line:
            continue
        if line == "##" or line.startswith("## "):
            chapters.append(Chapter(title=line[2:].strip()))
            continue
        if not chapters:
            raise SourceError(f"{path}: text before the first '## ' chapter heading")
        blocks = chapters[-1].blocks
        if line.startswith("> "):
            if blocks and blocks[-1][0] == "quote":
                blocks[-1][1].append(line[2:])
            else:
                blocks.append(("quote", [line[2:]]))
        else:
            blocks.append(("p", line))
    if not chapters or any(not c.blocks for c in chapters):
        raise SourceError(f"{path}: every chapter needs at least one paragraph")
    return Book(lang=lang, meta=meta, chapters=chapters)


# ---------------------------------------------------------------------------------------------------------
# Rendering


def esc(text: str) -> str:
    return html.escape(text, quote=True)


def inline(text: str) -> str:
    """Escapes a paragraph and turns _..._ pairs into <i>."""
    escaped = esc(text)
    if escaped.count("_") % 2:
        return escaped
    return re.sub(r"_([^_]+)_", r"<i>\1</i>", escaped)


def plain(text: str) -> str:
    """A paragraph as plain text (for metadata), without the italics markers."""
    return text.replace("_", "") if text.count("_") % 2 == 0 else text


def xhtml_page(lang: str, title: str, body: str) -> str:
    return (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        "<!DOCTYPE html>\n"
        f'<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="{lang}" xml:lang="{lang}">\n'
        "<head>\n"
        '<meta charset="utf-8"/>\n'
        f"<title>{esc(title)}</title>\n"
        '<link rel="stylesheet" type="text/css" href="style.css"/>\n'
        "</head>\n"
        f"{body}"
        "</html>\n"
    )


def chapter_xhtml(book: Book, index: int) -> str:
    chapter = book.chapters[index]
    parts = ['<body>\n<section epub:type="chapter">\n']
    if chapter.title:
        parts.append(f"<h2>{esc(chapter.title)}</h2>\n")
    for kind, content in chapter.blocks:
        if kind == "p":
            parts.append(f"<p>{inline(content)}</p>\n")
        else:
            parts.append("<blockquote>\n")
            parts.extend(f"<p>{inline(line)}</p>\n" for line in content)
            parts.append("</blockquote>\n")
    parts.append("</section>\n</body>\n")
    return xhtml_page(book.lang, chapter.title or book.meta["title"], "".join(parts))


def chapter_file(index: int) -> str:
    return f"chapter-{index + 1:02d}.xhtml"


def nav_label(book: Book, index: int) -> str:
    return book.chapters[index].title or book.meta["title"]


def nav_xhtml(book: Book) -> str:
    items = "".join(f'<li><a href="{chapter_file(i)}">{esc(nav_label(book, i))}</a></li>\n'
                    for i in range(len(book.chapters)))
    body = (f'<body>\n<nav epub:type="toc" id="toc">\n<h1>{esc(book.meta["title"])}</h1>\n<ol>\n{items}</ol>\n</nav>\n'
            "</body>\n")
    return xhtml_page(book.lang, book.meta["title"], body)


def ncx(book: Book, identifier: str) -> str:
    points = "".join(
        f'<navPoint id="nav-{i + 1}" playOrder="{i + 1}"><navLabel><text>{esc(nav_label(book, i))}</text></navLabel>'
        f'<content src="{chapter_file(i)}"/></navPoint>\n'
        for i in range(len(book.chapters)))
    return (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        f'<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1" xml:lang="{book.lang}">\n'
        f'<head><meta name="dtb:uid" content="{identifier}"/><meta name="dtb:depth" content="1"/>'
        '<meta name="dtb:totalPageCount" content="0"/><meta name="dtb:maxPageNumber" content="0"/></head>\n'
        f'<docTitle><text>{esc(book.meta["title"])}</text></docTitle>\n'
        f'<docAuthor><text>{esc(book.meta["author"])}</text></docAuthor>\n'
        f"<navMap>\n{points}</navMap>\n"
        "</ncx>\n"
    )


def wrap(text: str, width: int, cjk: bool) -> list[str]:
    if cjk:
        return [text[i:i + width] for i in range(0, len(text), width)] or [text]
    lines: list[str] = []
    for word in text.split():
        if lines and len(lines[-1]) + 1 + len(word) <= width:
            lines[-1] += " " + word
        else:
            lines.append(word)
    return lines


def cover_svg(book: Book) -> str:
    cjk = book.lang in CJK_LANGUAGES
    title_lines = wrap(book.meta["title"], 6 if cjk else 13, cjk)
    size = 104 if cjk else 92
    step = size * 1.2
    top = 560 - step * (len(title_lines) - 1) / 2
    title = "".join(f'<text x="600" y="{top + i * step:.0f}" font-size="{size}" font-weight="bold">{esc(line)}</text>'
                    for i, line in enumerate(title_lines))
    return (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<svg xmlns="http://www.w3.org/2000/svg" version="1.1" width="1200" height="1800" viewBox="0 0 1200 1800">\n'
        f'<title>{esc(book.meta["title"])} — {esc(book.meta["author"])}</title>\n'
        '<rect width="1200" height="1800" fill="#F4ECDC"/>\n'
        '<rect x="60" y="60" width="1080" height="1680" fill="none" stroke="#7A4E2D" stroke-width="6"/>\n'
        '<g font-family="Georgia, \'Times New Roman\', \'Hiragino Mincho ProN\', \'Songti SC\', serif" '
        'fill="#2B2118" text-anchor="middle">\n'
        f"{title}\n"
        '<line x1="450" y1="900" x2="750" y2="900" stroke="#7A4E2D" stroke-width="4"/>\n'
        f'<text x="600" y="1020" font-size="64">{esc(book.meta["author"])}</text>\n'
        f'<text x="600" y="1110" font-size="48" fill="#5C4A3A">{esc(book.meta["published"])}</text>\n'
        "</g>\n"
        "</svg>\n"
    )


STYLE = """body { margin: 0 5%; line-height: 1.5; }
h2 { font-size: 1.3em; margin: 1.5em 0 1em; text-align: center; }
p { margin: 0; text-indent: 1.2em; }
h2 + p { text-indent: 0; }
blockquote { margin: 0.8em 1.5em; }
blockquote p { text-indent: 0; }
"""


def opf(book: Book, identifier: str) -> str:
    m = book.meta
    description = f"{m['excerpt']}. {m['source-name']}. {m['rights']}"
    manifest = "".join(
        f'<item id="ch{i + 1:02d}" href="{chapter_file(i)}" media-type="application/xhtml+xml"/>\n'
        for i in range(len(book.chapters)))
    spine = "".join(f'<itemref idref="ch{i + 1:02d}"/>\n' for i in range(len(book.chapters)))
    return (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        f'<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="pub-id" xml:lang="{book.lang}">\n'
        '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">\n'
        f'<dc:identifier id="pub-id">{identifier}</dc:identifier>\n'
        f"<dc:title>{esc(m['title'])}</dc:title>\n"
        f'<dc:creator id="author">{esc(m["author"])}</dc:creator>\n'
        f"<dc:language>{book.lang}</dc:language>\n"
        f"<dc:date>{esc(m['published'])}</dc:date>\n"
        f"<dc:source>{esc(m['source'])}</dc:source>\n"
        f"<dc:rights>{esc(m['rights'])}</dc:rights>\n"
        f"<dc:description>{esc(description)}</dc:description>\n"
        "<dc:publisher>Folito (sample book)</dc:publisher>\n"
        f'<meta property="dcterms:modified">{MODIFIED}</meta>\n'
        '<meta name="cover" content="cover-image"/>\n'
        "</metadata>\n"
        "<manifest>\n"
        '<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>\n'
        '<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>\n'
        '<item id="cover-image" href="cover.svg" media-type="image/svg+xml" properties="cover-image"/>\n'
        '<item id="css" href="style.css" media-type="text/css"/>\n'
        f"{manifest}"
        "</manifest>\n"
        f'<spine toc="ncx">\n{spine}</spine>\n'
        "</package>\n"
    )


CONTAINER = (
    '<?xml version="1.0" encoding="utf-8"?>\n'
    '<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">\n'
    '<rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>\n'
    "</container>\n"
)


def entries(book: Book) -> list[tuple[str, bytes, int]]:
    """(name, bytes, compression) in archive order."""
    identifier = f"urn:uuid:{uuid.uuid5(UUID_NAMESPACE, book.lang)}"
    files: list[tuple[str, str]] = [
        ("META-INF/container.xml", CONTAINER),
        ("OEBPS/content.opf", opf(book, identifier)),
        ("OEBPS/nav.xhtml", nav_xhtml(book)),
        ("OEBPS/toc.ncx", ncx(book, identifier)),
        ("OEBPS/cover.svg", cover_svg(book)),
        ("OEBPS/style.css", STYLE),
    ]
    files += [(f"OEBPS/{chapter_file(i)}", chapter_xhtml(book, i)) for i in range(len(book.chapters))]
    return ([("mimetype", b"application/epub+zip", zipfile.ZIP_STORED)]
            + [(name, text.encode("utf-8"), zipfile.ZIP_DEFLATED) for name, text in files])


def build_epub(book: Book) -> bytes:
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive:
        for name, data, compression in entries(book):
            info = zipfile.ZipInfo(name, date_time=ZIP_DATE)
            info.compress_type = compression
            info.create_system = 3
            info.external_attr = 0o100644 << 16
            archive.writestr(info, data, compress_type=compression, compresslevel=9)
    return buffer.getvalue()


def validate(book: Book, data: bytes) -> None:
    """Structural checks on the archive just built (well-formed XML, mimetype first and stored)."""
    import xml.etree.ElementTree as ET

    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        infos = archive.infolist()
        assert infos[0].filename == "mimetype" and infos[0].compress_type == zipfile.ZIP_STORED, "mimetype must be first and stored"
        assert data[30:38] == b"mimetype" and data[38:58] == b"application/epub+zip", "mimetype must start at byte 30"
        for info in infos[1:]:
            if info.filename.endswith((".xml", ".opf", ".xhtml", ".ncx", ".svg")):
                try:
                    ET.fromstring(archive.read(info))
                except ET.ParseError as error:
                    raise SourceError(f"{book.lang}: {info.filename} is not well-formed: {error}") from error


def output_path(lang: str) -> Path:
    return OUTPUT_DIR / f"sample-{lang}.epub"


def archive_contents(data: bytes) -> list[tuple[str, int, bytes]]:
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        return [(i.filename, i.compress_type, archive.read(i)) for i in archive.infolist()]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--check", action="store_true", help="fail if a committed EPUB differs from a fresh build")
    args = parser.parse_args()

    sources = sorted(p.stem for p in SOURCE_DIR.glob("*.txt"))
    if sorted(LANGUAGES) != sources:
        print(f"error: docs/samples-src has {sources}, expected one source per language in {LANGUAGES}", file=sys.stderr)
        return 1
    stale: list[str] = []
    for lang in LANGUAGES:
        try:
            book = parse_source(SOURCE_DIR / f"{lang}.txt")
            data = build_epub(book)
            validate(book, data)
        except (SourceError, AssertionError) as error:
            print(f"error: {error}", file=sys.stderr)
            return 1
        path = output_path(lang)
        if args.check:
            if not path.exists() or archive_contents(path.read_bytes()) != archive_contents(data):
                stale.append(str(path.relative_to(ROOT)))
            continue
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        print(f"{path.relative_to(ROOT)}: {len(data) / 1024:.0f} KB, {len(book.chapters)} chapters")
    extra = sorted(p.name for p in OUTPUT_DIR.glob("*.epub") if p.stem.removeprefix("sample-") not in LANGUAGES)
    if extra:
        print(f"error: unexpected files in {OUTPUT_DIR.relative_to(ROOT)}: {extra}", file=sys.stderr)
        return 1
    if stale:
        print("error: these sample books are out of date; run python3 scripts/samples/build_samples.py and commit:",
              file=sys.stderr)
        for path in stale:
            print(f"  {path}", file=sys.stderr)
        return 1
    if args.check:
        print(f"Sample books OK: {len(LANGUAGES)} EPUBs match docs/samples-src.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
