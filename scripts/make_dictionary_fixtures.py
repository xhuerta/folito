#!/usr/bin/env python3
"""Generate tiny, deterministic StarDict dictionaries for the ReaderCore dictionary tests.

The definitions are written for the tests (no third-party dictionary content). The markup imitates the
reader.dict StarDict files Folito downloads (pronunciation line, <p><b>part of speech</b></p>, <ol> of
senses, nested <ol> of sub-senses) and the .dict.dz is written like dictzip (gzip with an FEXTRA field
and a file name), so the converter's real code paths are exercised.

Usage: scripts/make_dictionary_fixtures.py [output_dir]
Default output: Packages/ReaderCore/Tests/Fixtures/Dictionary
Writes <name>/<name>.{ifo,idx,dict.dz,syn} and <name>.zip for each dictionary.
"""
import os
import struct
import sys
import zipfile
import zlib

DICTIONARIES = {
    "tiny-en": {
        "entries": [
            ("run", "/rʌn/\n<p><b>Verb</b></p><ol><li>To move fast on foot.</li>"
                    "<ol style=\"list-style-type:lower-alpha\"><li>(<i>sports</i>) To take part in a race.</li></ol>"
                    "<li>To operate &amp; work.</li></ol><p><b>Noun</b></p><ol><li>An act of running.</li></ol>"),
            ("Polish", "<p><b>Adjective</b></p><ol><li>Of or from Poland.</li></ol>"),
            ("polish", "<p><b>Verb</b></p><ol><li>To make smooth and shiny.</li></ol>"),
            ("cat", "<p><b>Noun</b></p><ol><li>A small furry animal that purrs.</li></ol>"),
            ("café", "<p><b>Noun</b></p><ol><li>A small coffee shop.</li></ol>"),
            ("real", "<p><b>Adjective</b></p><ol><li>Actually existing.</li></ol>"),
            ("empty", ""),
        ],
        "syn": [("ran", "run"), ("Ran", "run"), ("running", "run"), ("cats", "cat"), ("unreal-form", "empty")],
    },
    "tiny-es": {
        "entries": [
            ("casa", "[ˈkasa]\n<p><b>Sustantivo</b> <i>f.</i></p><ol><li>Edificio para vivir.</li>"
                     "<li>Familia.</li></ol>"),
            ("real", "<p><b>Adjetivo</b></p><ol><li>Que existe de verdad.</li><li>Del rey.</li></ol>"),
        ],
        "syn": [("casas", "casa")],
    },
}


def stardict_sort_key(word):
    # StarDict sorts by g_ascii_strcasecmp, then strcmp.
    b = word.encode("utf-8")
    return (b.lower(), b)


def dictzip(data, name):
    """gzip with an FEXTRA 'RA' field and FNAME, like dictzip writes (one deflate stream)."""
    comp = zlib.compressobj(9, zlib.DEFLATED, -15)
    body = comp.compress(data) + comp.flush()
    extra = b"RA" + struct.pack("<H", 6) + struct.pack("<HHH", 1, 58315, 1)
    header = bytes([0x1F, 0x8B, 8, 0x04 | 0x08]) + struct.pack("<I", 0) + bytes([2, 3])
    header += struct.pack("<H", len(extra)) + extra + name.encode() + b"\0"
    return header + body + struct.pack("<II", zlib.crc32(data) & 0xFFFFFFFF, len(data) & 0xFFFFFFFF)


def build(name, spec, out_dir):
    entries = sorted(spec["entries"], key=lambda e: stardict_sort_key(e[0]))
    index_of = {w: i for i, (w, _) in enumerate(entries)}
    dict_data = b""
    idx = b""
    for word, definition in entries:
        raw = definition.encode("utf-8")
        idx += word.encode("utf-8") + b"\0" + struct.pack(">II", len(dict_data), len(raw))
        dict_data += raw
    syn = b""
    for word, target in sorted(spec["syn"], key=lambda s: stardict_sort_key(s[0])):
        syn += word.encode("utf-8") + b"\0" + struct.pack(">I", index_of[target])
    ifo = ("StarDict's dict ifo file\nversion=3.0.0\nbookname=%s\nwordcount=%d\nsynwordcount=%d\n"
           "idxfilesize=%d\nauthor=Folito tests\ndescription=Test fixture.\ndate=2026-10-01\n"
           "sametypesequence=h\n" % (name, len(entries), len(spec["syn"]), len(idx)))
    files = {
        name + ".ifo": ifo.encode("utf-8"),
        name + ".idx": idx,
        name + ".dict.dz": dictzip(dict_data, name + ".dict"),
        name + ".syn": syn,
    }
    folder = os.path.join(out_dir, name)
    os.makedirs(folder, exist_ok=True)
    for fname, data in files.items():
        with open(os.path.join(folder, fname), "wb") as f:
            f.write(data)
    with zipfile.ZipFile(os.path.join(out_dir, name + ".zip"), "w", zipfile.ZIP_DEFLATED) as z:
        for fname, data in files.items():
            info = zipfile.ZipInfo("dict/" + fname, date_time=(2026, 10, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            z.writestr(info, data)


def main():
    out_dir = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "..", "Packages", "ReaderCore", "Tests", "Fixtures", "Dictionary")
    os.makedirs(out_dir, exist_ok=True)
    for name, spec in DICTIONARIES.items():
        build(name, spec, out_dir)
    print("wrote", ", ".join(DICTIONARIES), "to", os.path.normpath(out_dir))


if __name__ == "__main__":
    main()
