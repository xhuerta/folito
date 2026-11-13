#!/usr/bin/env python3
"""Build the per-language App Store screenshot seeds (AppStoreSeeds/<lang>.json) from docs/samples-src/.

The localized screenshot suites (docs/appstore/SCREENSHOTS.md) seed the iPhone and watch apps from these files,
in Debug builds only: the UI test bundles carry the folder and pass one file to the app in UITESTING_APPSTORE_SEED.
Each file holds:

* the sample book of that language (the text the iPhone app bundles as sample-<lang>.epub, read from
  docs/samples-src/<lang>.txt, without the closing "about this sample" chapter and without a chapter that has
  no heading before the first one, so the reader opens at chapter 1);
* three more public-domain titles for the Library (metadata only: their text is the sample text repeated, so
  the iPhone Library shows plausible sizes; the English set uses the full texts of iOSApp/UITests/AppStoreBooks);
* the word the word-lookup screenshot looks up, where it is, and a four-word sample dictionary written for the
  screenshots (its source line reads "Sample dictionary");
* where the sepia reader screenshot opens, and the short title the complication snapshot shows.

Usage:
    python3 scripts/make_appstore_seeds.py           # write AppStoreSeeds/*.json
    python3 scripts/make_appstore_seeds.py --check   # exit 1 if a committed file differs from a fresh build
Standard library only.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE_DIR = ROOT / "docs" / "samples-src"
OUTPUT_DIR = ROOT / "AppStoreSeeds"

# Same order and set as scripts/samples/build_samples.py.
LANGUAGES = ["en", "es", "fr", "de", "it", "pt-BR", "ja", "zh-Hans"]


def entry(word, pronunciation, pos, senses, forms=()):
    return {"word": word, "pronunciation": pronunciation, "partOfSpeech": pos,
            "senses": [{"definition": s} if isinstance(s, str) else {"definition": s[0], "examples": [s[1]]}
                       for s in senses],
            "forms": list(forms)}


# Per language: the app's launch locale, the short title (spec 3.1), the other Library titles
# (title, author, cover colour), the word to look up with a phrase of its definition the test waits for,
# whether the sepia capture opens mid chapter 2 (else a later page of chapter 1), and the dictionary.
LOCALES = {
    "en": {
        "appleLanguage": "en", "appleLocale": "en_US", "shortTitle": "Emma",
        "library": [("Emma", "Jane Austen", 0x30B0C7, "emma"),
                    ("Alice’s Adventures in Wonderland", "Lewis Carroll", 0x5856D6, "alice"),
                    ("The Gods of Mars", "Edgar Rice Burroughs", 0xE8833A, "mars")],
        "word": "acknowledged", "probe": "accept or admit", "sepiaChapter2": True,
        "dictionary": [
            entry("acknowledge", "/əkˈnɒl.ɪdʒ/", "Verb", [
                ("To accept or admit that something is true or exists.", "She acknowledged her mistake."),
                "To recognise the standing, rights or importance of someone or something.",
                "To let someone know that a letter or message has arrived."],
                ["acknowledged", "acknowledges", "acknowledging"]),
            entry("truth", "/truːθ/", "Noun", [
                "What is really the case; the facts, as opposed to what is imagined or invented.",
                "A statement or principle that is generally accepted as true."], ["truths"]),
            entry("universally", "/ˌjuː.nɪˈvɜː.səl.i/", "Adverb", ["By everyone, or in every case; without exception."]),
            entry("fortune", "/ˈfɔː.tʃuːn/", "Noun", [
                "A large amount of money or property; wealth.",
                "Chance or luck, seen as a force that shapes what happens to people."], ["fortunes"]),
        ],
    },
    "es": {
        "appleLanguage": "es", "appleLocale": "es_ES", "shortTitle": "Don Quijote",
        "library": [("La Regenta", "Leopoldo Alas «Clarín»", 0x8E3B46, None),
                    ("Marianela", "Benito Pérez Galdós", 0x2E7D6B, None),
                    ("Lazarillo de Tormes", "Anónimo", 0xC9822B, None)],
        "word": "hidalgo", "probe": "noble de linaje", "sepiaChapter2": True,
        "dictionary": [
            entry("hidalgo", "/iˈðal.ɣo/", "Sustantivo", [
                ("Persona que por su sangre es de una clase noble de linaje, sin título.", "Vivía un hidalgo de los de lanza en astillero."),
                "Persona de ánimo generoso y noble."], ["hidalgos", "hidalga", "hidalgas"]),
            entry("lugar", "/luˈɣaɾ/", "Sustantivo", [
                "Porción de espacio que ocupa o puede ocupar algo.",
                "Población pequeña, menor que una villa."], ["lugares"]),
            entry("lanza", "/ˈlan.θa/", "Sustantivo", ["Arma de asta larga con una punta de hierro aguda y cortante."], ["lanzas"]),
            entry("rocín", "/roˈθin/", "Sustantivo", ["Caballo de mala traza, flaco y de poca alzada."], ["rocines"]),
        ],
    },
    "fr": {
        "appleLanguage": "fr", "appleLocale": "fr_FR", "shortTitle": "Germinal",
        "library": [("Madame Bovary", "Gustave Flaubert", 0x6A4C93, None),
                    ("Le Comte de Monte-Cristo", "Alexandre Dumas", 0x1F5F8B, None),
                    ("Germinal", "Émile Zola", 0x7A5C2E, None)],
        "word": "évêque", "probe": "diocèse", "sepiaChapter2": True,
        "dictionary": [
            entry("évêque", "/e.vɛk/", "Nom", [
                ("Membre du clergé qui a la charge d’un diocèse.", "Il était évêque de Digne."),
                "Dignitaire placé à la tête d’une Église chrétienne locale."], ["évêques"]),
            entry("vieillard", "/vjɛ.jaʁ/", "Nom", ["Homme très âgé."], ["vieillards"]),
            entry("siège", "/sjɛʒ/", "Nom", [
                "Meuble fait pour s’asseoir.",
                "Lieu où réside une autorité, une administration ; diocèse d’un évêque."], ["sièges"]),
            entry("détail", "/de.taj/", "Nom", ["Élément secondaire d’un ensemble ; petite circonstance."], ["détails"]),
        ],
    },
    "de": {
        "appleLanguage": "de", "appleLocale": "de_DE", "shortTitle": "Faust",
        "library": [("Effi Briest", "Theodor Fontane", 0x3E7CB1, None),
                    ("Der Process", "Franz Kafka", 0x4A4A4A, None),
                    ("Faust", "Johann Wolfgang von Goethe", 0x9C2F2F, None)],
        "word": "Ungeziefer", "probe": "Schädliche", "sepiaChapter2": False,
        "dictionary": [
            entry("Ungeziefer", "/ˈʊnɡəˌt͡siːfɐ/", "Substantiv", [
                ("Schädliche oder lästige Kleintiere, etwa Insekten oder Ratten.", "Er war zu einem ungeheueren Ungeziefer verwandelt."),
                "Abwertend für einen verachteten Menschen."]),
            entry("Traum", "/tʁaʊ̯m/", "Substantiv", [
                "Bilder und Erlebnisse, die man im Schlaf hat.",
                "Sehnlicher Wunsch."], ["Träume", "Träumen", "Traumes"]),
            entry("Zimmer", "/ˈt͡sɪmɐ/", "Substantiv", ["Raum in einer Wohnung oder einem Haus."], ["Zimmern", "Zimmers"]),
            entry("Morgen", "/ˈmɔʁɡn̩/", "Substantiv", ["Die Zeit des Tages vom Sonnenaufgang bis zum Vormittag."], ["Morgens"]),
        ],
    },
    "it": {
        "appleLanguage": "it", "appleLocale": "it_IT", "shortTitle": "Cuore",
        "library": [("Le avventure di Pinocchio", "Carlo Collodi", 0xC0392B, None),
                    ("I Malavoglia", "Giovanni Verga", 0x2C6E91, None),
                    ("Cuore", "Edmondo De Amicis", 0xB5651D, None)],
        "word": "lago", "probe": "acqua dolce", "sepiaChapter2": False,
        "dictionary": [
            entry("lago", "/ˈla.ɡo/", "Sostantivo", [
                ("Grande massa d’acqua dolce raccolta in una cavità del terreno.", "Quel ramo del lago di Como."),
                "Grande quantità di liquido sparso."], ["laghi"]),
            entry("ramo", "/ˈra.mo/", "Sostantivo", [
                "Parte dell’albero che nasce dal tronco.",
                "Diramazione di un corso d’acqua, di un lago o di una strada."], ["rami"]),
            entry("monte", "/ˈmon.te/", "Sostantivo", ["Rilievo del terreno molto elevato."], ["monti"]),
            entry("golfo", "/ˈɡol.fo/", "Sostantivo", ["Ampia insenatura di mare o di lago."], ["golfi"]),
        ],
    },
    "pt-BR": {
        "appleLanguage": "pt-BR", "appleLocale": "pt_BR", "shortTitle": "Iracema",
        "library": [("Memórias Póstumas de Brás Cubas", "Machado de Assis", 0x5D4E8C, None),
                    ("O Cortiço", "Aluísio Azevedo", 0x2E8B57, None),
                    ("Iracema", "José de Alencar", 0xD35400, None)],
        "word": "trem", "probe": "locomotiva", "sepiaChapter2": True,
        "dictionary": [
            entry("casmurro", "/kazˈmu.ʁu/", "Adjetivo", [
                ("Que é calado, fechado e metido consigo; teimoso.", "Acabou alcunhando-me Dom Casmurro."),
                "Que é triste ou tem mau humor."], ["casmurros", "casmurra", "casmurras"]),
            entry("trem", "/tɾẽj̃/", "Substantivo", ["Comboio de vagões puxado por uma locomotiva."], ["trens"]),
            entry("verso", "/ˈvɛʁ.su/", "Substantivo", ["Cada uma das linhas de um poema."], ["versos"]),
            entry("alcunha", "/awˈku.ɲɐ/", "Substantivo", ["Apelido, em geral tirado de algum traço da pessoa."], ["alcunhas"]),
        ],
    },
    "ja": {
        "appleLanguage": "ja", "appleLocale": "ja_JP", "shortTitle": "こころ",
        "library": [("坊っちゃん", "夏目漱石", 0x2F6F9F, None),
                    ("こころ", "夏目漱石", 0x8B3A3A, None),
                    ("羅生門", "芥川龍之介", 0x4B5D3A, None)],
        "word": "猫", "probe": "ペット", "sepiaChapter2": False,
        "dictionary": [
            entry("猫", "ねこ", "名詞", [
                ("ネコ科の哺乳類。古くからペットとして飼われる。", "吾輩は猫である。"),
                "三味線の別称。"]),
            entry("名前", "なまえ", "名詞", ["人や物を他と区別して呼ぶための語。"]),
            entry("吾輩", "わがはい", "代名詞", ["一人称の代名詞。尊大な言い方。"]),
            entry("記憶", "きおく", "名詞", ["過去の物事を忘れずに覚えていること。また、その内容。"]),
        ],
    },
    "zh-Hans": {
        "appleLanguage": "zh-Hans", "appleLocale": "zh_CN", "shortTitle": "阿Q正传",
        "library": [("阿Q正传", "鲁迅", 0x8C2D2D, None),
                    ("红楼梦", "曹雪芹", 0xA0522D, None),
                    ("西游记", "吴承恩", 0x2D6A8C, None)],
        "word": "月光", "probe": "月亮", "sepiaChapter2": True,
        "dictionary": [
            entry("月光", "yuèguāng", "名词", [("月亮的光。", "今天晚上，很好的月光。")]),
            entry("晚上", "wǎnshang", "名词", ["太阳落山以后到深夜以前的时间；泛指夜里。"]),
            entry("精神", "jīngshen", "名词", ["表现出来的活力。", "人的意识、思维和一般心理状态。"]),
            entry("今天", "jīntiān", "名词", ["说话时的这一天。"]),
        ],
    },
}

SAMPLE_COLOR = 0x7A2E3A
READ = [0.43, 0.78, 0.12]
REPEAT = [3, 6, 2]


def parse(lang: str) -> dict:
    text = (SOURCE_DIR / f"{lang}.txt").read_text(encoding="utf-8")
    head, body = text.split("\n---\n", 1)
    meta = dict(line.split(": ", 1) for line in head.splitlines() if ": " in line)
    chapters: list[dict] = []
    for line in body.splitlines():
        line = line.strip()
        if not line:
            continue
        if line.startswith("##"):
            chapters.append({"title": line[2:].strip() or None, "paragraphs": []})
            continue
        if line.startswith("> "):
            line = line[2:]
        if not chapters:
            chapters.append({"title": None, "paragraphs": []})
        chapters[-1]["paragraphs"].append(line.replace("_", ""))
    chapters = chapters[:-1]  # the closing "about this sample" chapter
    while chapters and chapters[0]["title"] is None:
        chapters = chapters[1:]  # a preface before chapter 1
    return {"meta": meta, "chapters": chapters}


def block_index(chapter: dict, paragraph: int) -> int:
    return paragraph + (1 if chapter["title"] else 0)


def build(lang: str) -> dict:
    loc = LOCALES[lang]
    src = parse(lang)
    chapters = src["chapters"]
    i = LANGUAGES.index(lang)
    word = loc["word"]
    found = next(((c, p) for c, ch in enumerate(chapters) for p, text in enumerate(ch["paragraphs"])
                  if word.lower() in text.lower()), None)
    if found is None:
        raise SystemExit(f"{lang}: '{word}' is not in the sample text")
    c, p = found
    if loc["sepiaChapter2"] and len(chapters) > 1:
        sepia = {"chapter": 1, "block": block_index(chapters[1], len(chapters[1]["paragraphs"]) // 2)}
    else:
        sepia = {"chapter": 0, "block": block_index(chapters[0], len(chapters[0]["paragraphs"]) // 3)}
    library = []
    for n, (title, author, color, text) in enumerate(loc["library"]):
        book = {"title": title, "author": author, "color": color, "read": READ[n], "repeats": REPEAT[n],
                "hash": f"00000000000000000000000{i:02d}0e00a0{n + 1}"[-32:]}
        if text:
            book["text"] = text
        library.append(book)
    meta = src["meta"]
    return {
        "language": lang,
        "appleLanguage": loc["appleLanguage"],
        "appleLocale": loc["appleLocale"],
        "shortTitle": loc["shortTitle"],
        "sample": {"title": meta["title"], "author": meta["author"], "year": int(meta["published"]),
                   "language": meta["language"], "color": SAMPLE_COLOR,
                   "hash": f"0000000000000000000000{i:02d}000a0571"[-32:], "chapters": chapters},
        "library": library,
        "lookup": {"word": word, "chapter": c, "block": block_index(chapters[c], p), "probe": loc["probe"]},
        "dictionary": {"id": f"sample-{lang}", "language": lang.split("-")[0], "entries": loc["dictionary"]},
        "sepia": sepia,
        "complication": {"chapterTitle": chapters[0]["title"] or ""},
    }


def render(lang: str) -> str:
    return json.dumps(build(lang), ensure_ascii=False, indent=1, sort_keys=True) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--check", action="store_true", help="fail if a committed seed differs from a fresh build")
    args = parser.parse_args()
    stale = []
    OUTPUT_DIR.mkdir(exist_ok=True)
    for lang in LANGUAGES:
        path = OUTPUT_DIR / f"{lang}.json"
        fresh = render(lang)
        if args.check:
            if not path.exists() or path.read_text(encoding="utf-8") != fresh:
                stale.append(path.name)
        else:
            path.write_text(fresh, encoding="utf-8")
    if stale:
        print("Stale App Store seeds (run python3 scripts/make_appstore_seeds.py):", ", ".join(stale))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
