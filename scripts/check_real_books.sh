#!/usr/bin/env bash
# End-to-end check of ReaderCore against REAL EPUBs (Project Gutenberg, public domain).
# Nothing is committed: books go to a scratch dir. Usage: scripts/check_real_books.sh [SCRATCH_DIR]
# Needs: curl, python3, swift (PATH), optional luajit (real KOReader partialMD5 semantics).
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
scratch="${1:-${TMPDIR:-/tmp}/wristreader-real-books}"
mkdir -p "$scratch/epubs" "$scratch/report"
# name:gutenberg-id  (simple EN, illustrated 24MB, long EN, DE, ES, RU-themed EN, FR-themed EN, JA)
books="alice:11 pride:1342 moby:2701 faust_de:2229 quixote_es:2000 crime:2554 lesmis:135 rashomon_ja:1982"
for b in $books; do
  n="${b%%:*}"; id="${b##*:}"
  [ -s "$scratch/epubs/$n.epub" ] || curl -fsSL -o "$scratch/epubs/$n.epub" "https://www.gutenberg.org/ebooks/$id.epub.images"
done
(cd "$here/Packages/ReaderCore" && WRISTREADER_EPUB_DIR="$scratch/epubs" WRISTREADER_REPORT_DIR="$scratch/report" swift test --filter RealWorldBooksTests)
echo "== partialMD5 cross-check =="
python3 -I "$here/scripts/partial_md5_reference.py" "$scratch"/epubs/*.epub | awk '{print $1"  "$2}' | sort -k2 > "$scratch/md5_python.txt"
tail -n +2 "$scratch/report/report.tsv" | awk -F'\t' -v d="$scratch/epubs/" '{print $8"  "d$1}' | sort -k2 > "$scratch/md5_swift.txt"
diff "$scratch/md5_python.txt" "$scratch/md5_swift.txt" && echo "Swift == python reference"
if command -v luajit >/dev/null; then
  luajit "$here/scripts/partial_md5_luajit.lua" "$scratch"/epubs/*.epub | sort -k2 | diff - "$scratch/md5_python.txt" && echo "LuaJIT (KOReader loop) == python reference"
fi
echo "== compressed size of ProcessedBook JSON =="
python3 -I - "$scratch/report" <<'PY'
import glob, os, sys, zlib, lzma
for f in sorted(glob.glob(os.path.join(sys.argv[1], "*.book.json"))):
    d = open(f, "rb").read()
    print(f"{os.path.basename(f)[:-10]:22s} raw {len(d)//1024:6d} KB  zlib {len(zlib.compress(d, 6))//1024:6d} KB  lzma {len(lzma.compress(d))//1024:6d} KB")
PY
cat "$scratch/report/report.tsv"
