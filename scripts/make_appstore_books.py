#!/usr/bin/env python3
"""Builds iOSApp/UITests/AppStoreBooks/*.deflate, the full texts the App Store screenshots seed the iPhone Library
with (`UITESTING_BOOK_TEXTS`, see iOSApp/Support/UITestingSupport.swift), so the Library shows real book sizes.

Input: a Project Gutenberg plain-text file (UTF-8). The Gutenberg header and licence are dropped (the works are in
the public domain), as is everything before the first chapter. Output: one paragraph per line, `# ` before chapter
and volume headings, compressed as raw DEFLATE (what NSData's `.zlib` algorithm reads).

Usage: scripts/make_appstore_books.py pg11.txt iOSApp/UITests/AppStoreBooks/alice.deflate
The committed files come from Gutenberg ebooks #11 (alice), #64 (mars) and #158 (emma).
"""
import re
import sys
import zlib

HEADING = re.compile(r"^(CHAPTER|VOLUME) [IVXLC]+\.?$|^CHAPTER [IVXLC]+\.? ")


def paragraphs(text):
    text = text.replace("\r\n", "\n")
    start = text.index("***", text.index("*** START OF") + 5) + 3
    text = text[start:text.index("*** END OF")]
    paras = [re.sub(r"\s+", " ", p).strip() for p in re.split(r"\n\s*\n", text)]
    paras = [p for p in paras if p]
    # The first "CHAPTER I" heading followed by prose (not the table of contents).
    first = next(i for i, p in enumerate(paras)
                 if re.match(r"^CHAPTER I\.?( |$)", p) and len(p) < 80 and any(len(q) > 150 for q in paras[i + 1:i + 3]))
    if first > 0 and paras[first - 1].startswith("VOLUME"):
        first -= 1
    out = []
    for p in paras[first:]:
        if HEADING.match(p) and len(p) < 80:
            out.append("# " + p)
        elif out and re.fullmatch(r"# CHAPTER [IVXLC]+\.?", out[-1]) and len(p) < 60:
            out[-1] += " " + p  # "CHAPTER I" then its title on its own line
        else:
            out.append(p)
    return out


def main():
    src, dst = sys.argv[1], sys.argv[2]
    lines = paragraphs(open(src, encoding="utf-8-sig").read())
    data = "\n".join(lines).encode()
    deflate = zlib.compressobj(9, zlib.DEFLATED, -15)
    packed = deflate.compress(data) + deflate.flush()
    with open(dst, "wb") as f:
        f.write(packed)
    print(f"{dst}: {len(lines)} paragraphs, {len(data)} bytes of text, {len(packed)} compressed")


if __name__ == "__main__":
    main()
