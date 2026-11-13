#!/usr/bin/env python3
"""Compose the designed App Store iPhone screenshots from the raw CI captures.

Input: a root of language directories as the `app-store-screenshots-all`
artifact holds them (<lang>/{iphone-medium,iphone-large,watch,complications}/).
Output, per language and display size: five PNGs (no alpha) with the brand
gradient, a localized headline and drawn devices around the raw captures.

    python3 -I scripts/compose_appstore_screenshots.py RAW_ROOT [OUT_DIR] [--langs en,ja]

Needs Pillow and the fonts listed in FONTS (found with fc-list).
"""

import argparse
import os
import subprocess
import sys

from PIL import Image, ImageDraw, ImageFilter, ImageFont

LANGS = ["en", "es", "fr", "de", "it", "pt-BR", "ja", "zh-Hans"]
CJK = {"ja", "zh-Hans"}

# Display size name -> (canvas size, raw iPhone directory).
SIZES = {
    "6.9": ((1320, 2868), "iphone-large"),
    "6.3": ((1206, 2622), "iphone-medium"),
}

GRADIENT = [(0x06, 0x1E, 0x59), (0x07, 0x4F, 0x9D), (0x0A, 0x6C, 0xD8)]
CLOCK_TEXT = "10:09"
SEPIA_CLOCK = (96, 66, 40)

# Font candidates per role, first one installed wins (family names as fc-list prints them).
FONTS = {
    "head": [("Inter Display", "Bold"), ("Inter", "Bold"), ("Noto Sans", "Bold"), ("DejaVu Sans", "Bold")],
    "sub": [("Inter", "Medium"), ("Inter", "Regular"), ("Noto Sans", "Medium"), ("DejaVu Sans", "Book")],
    "clock": [("Inter", "SemiBold"), ("Inter", "Medium"), ("Noto Sans", "SemiBold"), ("DejaVu Sans", "Bold")],
    "head-ja": [("Noto Sans CJK JP", "Bold"), ("Noto Sans JP", "Bold"), ("IPAPGothic", None), ("IPAGothic", None)],
    "sub-ja": [("Noto Sans CJK JP", "Medium"), ("Noto Sans CJK JP", "Regular"), ("Noto Sans JP", "Medium"), ("IPAPGothic", None), ("IPAGothic", None)],
    "head-zh-Hans": [("Noto Sans CJK SC", "Bold"), ("Noto Sans SC", "Bold"), ("WenQuanYi Zen Hei", None)],
    "sub-zh-Hans": [("Noto Sans CJK SC", "Medium"), ("Noto Sans CJK SC", "Regular"), ("Noto Sans SC", "Medium"), ("WenQuanYi Zen Hei", None)],
}

# Slide order and text. Each entry: (headline, subline). "\n" in a headline forces the break.
SLIDES = ["hero", "lookup", "send", "typography", "progress"]
TEXT = {
    "en": [
        ("Read books on your wrist", "Your own EPUBs on Apple Watch, even offline"),
        ("Look up any word", "Offline dictionaries, right on your watch"),
        ("Send books from your iPhone", "Import EPUBs and read them on your watch"),
        ("Typography your way", "Typeface, size, spacing and themes"),
        ("Pick up where you left off", "Your progress on the watch face and iPhone"),
    ],
    "es": [
        ("Lee libros en tu muñeca", "Tus EPUB en el Apple Watch, incluso sin conexión"),
        ("Consulta cualquier palabra", "Diccionarios sin conexión, en el reloj"),
        ("Envía libros desde el iPhone", "Importa tus EPUB y léelos en el reloj"),
        ("Tipografía a tu gusto", "Tipo de letra, tamaño, espaciado y temas"),
        ("Sigue donde lo dejaste", "Tu progreso en la esfera y en el iPhone"),
    ],
    "fr": [
        ("Lisez vos livres au poignet", "Vos EPUB sur l’Apple Watch, même hors ligne"),
        ("Cherchez n’importe quel mot", "Des dictionnaires hors ligne, sur la montre"),
        ("Envoyez vos livres depuis l’iPhone", "Importez vos EPUB, lisez-les sur la montre"),
        ("Une typographie à votre goût", "Police, taille, espacement et thèmes"),
        ("Reprenez là où vous en étiez", "Votre progression sur le cadran et l’iPhone"),
    ],
    "de": [
        ("Bücher am Handgelenk lesen", "Deine EPUBs auf der Apple Watch, auch offline"),
        ("Jedes Wort nachschlagen", "Offline-Wörterbücher direkt auf der Uhr"),
        ("Bücher vom iPhone senden", "EPUBs importieren und auf der Uhr lesen"),
        ("Typografie nach deinem Geschmack", "Schrift, Größe, Abstand und Themen"),
        ("Weiterlesen, wo du aufgehört hast", "Dein Fortschritt auf dem Zifferblatt und dem iPhone"),
    ],
    "it": [
        ("Leggi libri al polso", "I tuoi EPUB su Apple Watch, anche offline"),
        ("Cerca qualsiasi parola", "Dizionari offline, direttamente sull’orologio"),
        ("Invia libri dall’iPhone", "Importa i tuoi EPUB e leggili sull’orologio"),
        ("La tipografia che preferisci", "Carattere, dimensione, spaziatura e temi"),
        ("Riprendi da dove eri rimasto", "I tuoi progressi sul quadrante e su iPhone"),
    ],
    "pt-BR": [
        ("Leia livros no seu pulso", "Seus EPUBs no Apple Watch, até offline"),
        ("Consulte qualquer palavra", "Dicionários offline, direto no relógio"),
        ("Envie livros do iPhone", "Importe seus EPUBs e leia no relógio"),
        ("Tipografia do seu jeito", "Fonte, tamanho, espaçamento e temas"),
        ("Continue de onde parou", "Seu progresso no mostrador e no iPhone"),
    ],
    "ja": [
        ("手首で、本を読もう", "自分のEPUBをApple Watchで。オフラインでも"),
        ("どんな単語も\nすぐに調べられる", "オフラインの辞書を、Apple Watchに"),
        ("iPhoneから本を送ろう", "EPUBを読み込んで、Apple Watchで読む"),
        ("読みやすさは\n思いのままに", "書体、サイズ、間隔、テーマを選べます"),
        ("続きから、すぐに", "進み具合を文字盤とiPhoneで確認"),
    ],
    "zh-Hans": [
        ("在手腕上读书", "在 Apple Watch 上离线阅读你的 EPUB 图书"),
        ("随手查词", "离线词典，就在手表上"),
        ("从 iPhone 发送图书", "导入 EPUB，在手表上阅读"),
        ("排版随心设定", "字体、字号、间距和主题任你选"),
        ("从上次读到的地方继续", "在表盘和 iPhone 上查看阅读进度"),
    ],
}

# Where the watch status clock sits in each capture: centred or top right.
CLOCK_ALIGN = {
    "watch-1-reader": "center",
    "watch-4-sepia": "center",
    "watch-3-library": "center",
    "watch-2-word-lookup": "right",
    "watch-2a-word-picker": "right",
    "watch-5-menu": "right",
}

NO_LINE_START = set("、。，．・：；！？）」』》〉”’ー々ぁぃぅぇぉっゃゅょァィゥェォッャュョ,.:;!?)")


# ---------------------------------------------------------------- fonts

_FONT_FILES = None


def _font_table():
    global _FONT_FILES
    if _FONT_FILES is None:
        _FONT_FILES = {}
        # Collections (.ttc, e.g. Noto Sans CJK) hold one face per language: keep the index.
        out = subprocess.run(["fc-list", "--format", "%{file}\t%{index}\t%{family}\t%{style}\n"],
                             capture_output=True, text=True, check=True).stdout
        for line in sorted(out.splitlines()):
            parts = line.split("\t")
            if len(parts) != 4:
                continue
            path, index, families, styles = parts
            face = (path, int(index or 0))
            for fam in families.split(","):
                for sty in styles.split(","):
                    _FONT_FILES.setdefault((fam.strip(), sty.strip()), face)
                _FONT_FILES.setdefault((fam.strip(), None), face)
    return _FONT_FILES


def font_path(role):
    table = _font_table()
    for fam, sty in FONTS[role]:
        p = table.get((fam, sty))
        if p:
            # A font without a bold face (CJK fallbacks) gets a faux bold stroke.
            return p, sty is None and role.startswith("head")
    sys.exit(f"no font installed for {role}: {FONTS[role]}")


_FONT_CACHE = {}


def font(role, size):
    key = (role, size)
    if key not in _FONT_CACHE:
        (path, index), faux = font_path(role)
        _FONT_CACHE[key] = (ImageFont.truetype(path, size, index=index), faux)
    return _FONT_CACHE[key]


def role_for(kind, lang):
    return f"{kind}-{lang}" if lang in CJK else kind


# ---------------------------------------------------------------- drawing helpers

def gradient(size):
    w, h = size
    col = Image.new("RGB", (1, h))
    px = col.load()
    for y in range(h):
        t = y / (h - 1) * 2
        i = min(int(t), 1)
        f = t - i
        a, b = GRADIENT[i], GRADIENT[i + 1]
        px[0, y] = tuple(round(a[c] + (b[c] - a[c]) * f) for c in range(3))
    return col.resize((w, h))


def rr_mask(size, radius, ss=3):
    w, h = size
    m = Image.new("L", (w * ss, h * ss), 0)
    ImageDraw.Draw(m).rounded_rectangle((0, 0, w * ss - 1, h * ss - 1), radius=radius * ss, fill=255)
    return m.resize((w, h), Image.LANCZOS)


def shadow(canvas, mask, pos, blur, offset, opacity):
    pad = blur * 3
    sh = Image.new("L", (mask.width + 2 * pad, mask.height + 2 * pad), 0)
    sh.paste(mask, (pad, pad))
    sh = sh.filter(ImageFilter.GaussianBlur(blur)).point(lambda v: int(v * opacity))
    canvas.paste((2, 8, 28), (pos[0] - pad + offset[0], pos[1] - pad + offset[1]), sh)


def paste_rr(canvas, img, pos, radius):
    canvas.paste(img, pos, rr_mask(img.size, radius))


# ---------------------------------------------------------------- devices

def draw_phone(canvas, shot, x, y, screen_w):
    """A drawn iPhone with the screenshot inside; (x, y) is the body's top left."""
    k = screen_w / shot.width
    screen = shot.resize((screen_w, round(shot.height * k)), Image.LANCZOS)
    bezel = round(screen_w * 0.034)
    rim = max(3, round(screen_w * 0.006))
    bw, bh = screen.width + 2 * bezel, screen.height + 2 * bezel
    r_screen = round(screen_w * 0.135)
    r_body = r_screen + bezel
    body_mask = rr_mask((bw, bh), r_body)
    shadow(canvas, body_mask, (x, y), round(screen_w * 0.04), (0, round(screen_w * 0.03)), 0.55)
    canvas.paste((70, 76, 88), (x, y), body_mask)
    inner = rr_mask((bw - 2 * rim, bh - 2 * rim), r_body - rim)
    canvas.paste((10, 11, 14), (x + rim, y + rim), inner)
    paste_rr(canvas, screen, (x + bezel, y + bezel), r_screen)
    # Dynamic Island.
    iw, ih = round(screen_w * 0.31), round(screen_w * 0.091)
    ix, iy = x + bezel + (screen_w - iw) // 2, y + bezel + round(screen_w * 0.028)
    canvas.paste((0, 0, 0), (ix, iy), rr_mask((iw, ih), ih // 2))
    # Side buttons.
    d = ImageDraw.Draw(canvas)
    bt = max(4, round(screen_w * 0.008))
    d.rounded_rectangle((x + bw - 1, y + bh * 0.25, x + bw + bt, y + bh * 0.36), radius=bt, fill=(60, 66, 78))
    d.rounded_rectangle((x - bt, y + bh * 0.19, x + 1, y + bh * 0.24), radius=bt, fill=(60, 66, 78))
    d.rounded_rectangle((x - bt, y + bh * 0.27, x + 1, y + bh * 0.32), radius=bt, fill=(60, 66, 78))
    return bw, bh


def watch_geometry(screen_w, shot_size=(422, 514)):
    sh = round(screen_w * shot_size[1] / shot_size[0])
    pad = round(screen_w * 0.085)
    return sh, pad, screen_w + 2 * pad, sh + 2 * pad


def draw_watch(canvas, shot, cx, y, screen_w, strap_to=None, strap_top=0):
    """A drawn Apple Watch centred on cx; y is the case's top. Returns the case box."""
    sh, pad, cw, ch = watch_geometry(screen_w, shot.size)
    x = cx - cw // 2
    d = ImageDraw.Draw(canvas)
    # Straps behind the case.
    sw = round(cw * 0.74)
    strap_len = round(ch * 0.42)
    top = max(strap_top, y - strap_len)
    bottom = y + ch + strap_len if strap_to is None else strap_to
    strap = (14, 26, 56)
    d.rounded_rectangle((cx - sw // 2, top, cx + sw // 2, y + ch // 2), radius=round(sw * 0.12), fill=strap)
    d.rounded_rectangle((cx - sw // 2, y + ch // 2, cx + sw // 2, bottom), radius=round(sw * 0.12), fill=strap)
    case_mask = rr_mask((cw, ch), round(cw * 0.25))
    shadow(canvas, case_mask, (x, y), round(cw * 0.05), (0, round(cw * 0.035)), 0.6)
    # Crown and side button on the right.
    crw, crh = round(cw * 0.075), round(ch * 0.17)
    crx, cry = x + cw - round(crw * 0.35), y + round(ch * 0.2)
    d.rounded_rectangle((crx, cry, crx + crw, cry + crh), radius=round(crw * 0.3), fill=(96, 102, 114))
    for i in range(1, 8):
        yy = cry + i * crh / 8
        d.line((crx + crw * 0.45, yy, crx + crw - 2, yy), fill=(66, 71, 82), width=max(1, round(crw * 0.06)))
    bh = round(ch * 0.2)
    d.rounded_rectangle((x + cw - round(crw * 0.5), y + round(ch * 0.47), x + cw + round(crw * 0.25),
                         y + round(ch * 0.47) + bh), radius=round(crw * 0.3), fill=(78, 84, 96))
    # Case: titanium rim, black glass, screen.
    canvas.paste((112, 118, 130), (x, y), case_mask)
    rim = max(3, round(cw * 0.012))
    canvas.paste((36, 39, 46), (x + rim, y + rim), rr_mask((cw - 2 * rim, ch - 2 * rim), round(cw * 0.25) - rim))
    glass = round(pad * 0.55)
    canvas.paste((0, 0, 0), (x + glass, y + glass),
                 rr_mask((cw - 2 * glass, ch - 2 * glass), round(cw * 0.25) - glass))
    screen = shot.resize((screen_w, sh), Image.LANCZOS)
    paste_rr(canvas, screen, (x + pad, y + pad), round(screen_w * 0.17))
    return x, y, cw, ch


# ---------------------------------------------------------------- raw capture fixes

def fix_watch_clock(img, name):
    """Cover the CI runner's time in the watch status area with CLOCK_TEXT."""
    img = img.convert("RGB")
    align = CLOCK_ALIGN[name]
    w = img.width
    x0, x1 = (int(w * 0.28), int(w * 0.72)) if align == "center" else (int(w * 0.62), w - 4)
    y0, y1 = int(img.height * 0.06), int(img.height * 0.15)
    px = img.load()
    bg = px[x0, y0]
    sepia = sum(bg) > 500
    xs, ys = [], []
    for yy in range(y0, y1):
        for xx in range(x0, x1):
            p = px[xx, yy]
            if sepia:
                hit = sum(abs(p[c] - bg[c]) for c in range(3)) > 18
            else:
                hit = min(p) > 150
            if hit:
                xs.append(xx)
                ys.append(yy)
    if not xs:
        return img
    bx0, bx1, by0, by1 = min(xs), max(xs), min(ys), max(ys)
    color = SEPIA_CLOCK if sepia else max((px[a, b] for a, b in zip(xs, ys)), key=sum)
    d = ImageDraw.Draw(img)
    fill_bg = px[max(0, bx0 - 6), (by0 + by1) // 2]
    d.rectangle((bx0 - 3, by0 - 3, bx1 + 3, by1 + 3), fill=fill_bg)
    # Size the new time so its digits are as tall as the old ones.
    target = by1 - by0 + 1
    size = target
    for _ in range(6):
        f, _faux = font("clock", size)
        bb = f.getbbox("0123456789")
        size = max(8, round(size * target / (bb[3] - bb[1])))
    f, _faux = font("clock", size)
    bb = f.getbbox(CLOCK_TEXT)
    tw = bb[2] - bb[0]
    tx = (bx0 + bx1 + 1) / 2 - tw / 2 if align == "center" else bx1 + 1 - tw
    d.text((tx - bb[0], by0 - f.getbbox("0")[1]), CLOCK_TEXT, font=f, fill=color)
    if name in ("watch-1-reader", "watch-4-sepia"):
        hide_cut_line(img, by1 + 4, bg, sepia)
    return img


def hide_cut_line(img, y_start, bg, sepia):
    """Blank a text line cut in half under the clock band (shorter than the next full line)."""
    px = img.load()

    def ink(y):
        return any((sum(abs(px[x, y][c] - bg[c]) for c in range(3)) > 60) if sepia else max(px[x, y]) > 90
                   for x in range(8, img.width - 8, 2))

    runs, start = [], None
    for y in range(y_start, min(img.height, y_start + 140)):
        if ink(y):
            start = y if start is None else start
        elif start is not None:
            runs.append((start, y - 1))
            start = None
        if len(runs) == 2:
            break
    if len(runs) == 2 and runs[0][0] <= y_start + 6 and (runs[0][1] - runs[0][0]) < 0.75 * (runs[1][1] - runs[1][0]):
        ImageDraw.Draw(img).rectangle((0, y_start - 4, img.width, runs[0][1] + 1), fill=bg)


def watch_face(raw, lang, size=(422, 514)):
    """A black modular face: the time and the app's complications (3x snapshots shown at 2x)."""
    img = Image.new("RGB", size, (0, 0, 0))
    d = ImageDraw.Draw(img)
    f, _ = font("clock", 118)
    bb = f.getbbox(CLOCK_TEXT)
    d.text((size[0] - 22 - bb[2], 34 - bb[1]), CLOCK_TEXT, font=f, fill=(255, 255, 255))
    cdir = os.path.join(raw, lang, "complications")
    rect = os.path.join(cdir, "complication-rectangular.png")
    circ = os.path.join(cdir, "complication-circular.png")
    y = 34 + bb[3] - bb[1] + 40
    if os.path.exists(rect):
        r = Image.open(rect).convert("RGB")
        r = r.resize((round(r.width * 2 / 3), round(r.height * 2 / 3)), Image.LANCZOS)
        img.paste(r, ((size[0] - r.width) // 2, y))
        y += r.height + 26
    if os.path.exists(circ):
        c = Image.open(circ).convert("RGB")
        c = c.resize((round(c.width * 2 / 3), round(c.height * 2 / 3)), Image.LANCZOS)
        img.paste(c, (16, min(y, size[1] - c.height - 16)))
    if not os.path.exists(rect):
        return None
    return img


# ---------------------------------------------------------------- text

def tokens(text, lang):
    """Break opportunities: words for Latin scripts, characters for CJK (ASCII runs kept whole)."""
    if lang not in CJK:
        return [t + " " for t in text.split(" ")]
    out, buf = [], ""
    for ch in text:
        if ch.isascii() and ch != " ":
            buf += ch
            continue
        if buf:
            out.append(buf)
            buf = ""
        if ch == " ":
            if out:
                out[-1] += " "
        elif ch in NO_LINE_START and out:
            out[-1] += ch
        else:
            out.append(ch)
    if buf:
        out.append(buf)
    return out


def text_w(f, s):
    s = s.rstrip()
    return f.getlength(s) if s else 0


def wrap(text, lang, f, max_w, max_lines):
    """Best wrapping in at most max_lines lines (balanced), or None if it cannot fit."""
    lines_out = []
    for part in text.split("\n"):
        toks = tokens(part, lang)
        best = None
        n = len(toks)
        budget = max_lines - len(lines_out)
        if budget <= 0:
            return None
        # Try 1 line, then balanced 2- and 3-line splits.
        cands = [[toks]]
        if budget >= 2:
            cands += [[toks[:i], toks[i:]] for i in range(1, n)]
        if budget >= 3:
            cands += [[toks[:i], toks[i:j], toks[j:]] for i in range(1, n) for j in range(i + 1, n)]
        for c in cands:
            ls = ["".join(t).strip() for t in c]
            widths = [text_w(f, s) for s in ls]
            if max(widths) > max_w:
                continue
            score = (len(ls), max(widths))
            if best is None or score < best[0]:
                best = (score, ls)
        if best is None:
            return None
        lines_out += best[1]
    return lines_out


def draw_text_block(canvas, text, lang, kind, size, max_w, max_lines, top, fill, line_gap):
    """Draw centred lines, shrinking until it fits. Returns the bottom y."""
    role = role_for(kind, lang)
    while True:
        f, faux = font(role, size)
        lines = wrap(text, lang, f, max_w, max_lines)
        if lines or size < 20:
            break
        size = round(size * 0.94)
    lines = lines or [text]
    d = ImageDraw.Draw(canvas)
    stroke = max(1, round(size * 0.014)) if faux else 0
    asc, desc = f.getmetrics()
    lh = round(size * line_gap)
    y = top
    for line in lines:
        w = text_w(f, line)
        d.text(((canvas.width - w) / 2, y), line, font=f, fill=fill, stroke_width=stroke, stroke_fill=fill)
        y += lh
    return y - lh + asc + desc


def header(canvas, lang, idx):
    k = canvas.width / 1320
    head, sub = TEXT[lang][idx]
    margin = round(96 * k)
    max_w = canvas.width - 2 * margin
    hs = round((112 if lang in CJK else 116) * k)
    y = draw_text_block(canvas, head, lang, "head", hs, max_w, 2, round(170 * k), (255, 255, 255), 1.14)
    y = draw_text_block(canvas, sub, lang, "sub", round(50 * k), max_w, 2, y + round(34 * k),
                        (214, 230, 255), 1.3)
    return y


# ---------------------------------------------------------------- slides

def load_watch(raw, lang, name):
    return fix_watch_clock(Image.open(os.path.join(raw, lang, "watch", name + ".png")), name)


def load_phone(raw, lang, phone_dir, name):
    return Image.open(os.path.join(raw, lang, phone_dir, name + ".png")).convert("RGB")


def compose(raw, lang, size_name, out_dir):
    (W, H), phone_dir = SIZES[size_name]
    k = W / 1320
    os.makedirs(out_dir, exist_ok=True)
    paths = []
    for idx, slide in enumerate(SLIDES):
        c = gradient((W, H))
        text_bottom = header(c, lang, idx)
        top = text_bottom + round(110 * k)
        st = text_bottom + round(70 * k)
        if slide == "hero":
            shot = load_watch(raw, lang, "watch-1-reader")
            sw = round(900 * k)
            _, _, cw, ch = watch_geometry(sw)
            y = max(top + round(60 * k), (top + H - ch) // 2 - round(60 * k))
            draw_watch(c, shot, W // 2, y, sw, strap_to=H + 40, strap_top=st)
        elif slide == "lookup":
            pick = load_watch(raw, lang, "watch-2a-word-picker")
            look = load_watch(raw, lang, "watch-2-word-lookup")
            sw1, sw2 = round(560 * k), round(640 * k)
            _, _, cw1, ch1 = watch_geometry(sw1)
            _, _, cw2, ch2 = watch_geometry(sw2)
            draw_watch(c, pick, round(W * 0.33), top + round(90 * k), sw1, strap_top=st)
            draw_watch(c, look, round(W * 0.64), H - ch2 - round(260 * k), sw2, strap_to=H + 40)
        elif slide in ("send", "typography", "progress"):
            phone_name = {"send": "iphone-1-library", "typography": "iphone-3-reading",
                          "progress": "iphone-2-book-details"}[slide]
            phone = load_phone(raw, lang, phone_dir, phone_name)
            if slide == "send":
                wshot = load_watch(raw, lang, "watch-3-library")
            elif slide == "typography":
                wshot = load_watch(raw, lang, "watch-4-sepia")
            else:
                wshot = watch_face(raw, lang) or load_watch(raw, lang, "watch-5-menu")
            # Phone and watch side by side: the watch case overlaps only the phone's bezel
            # (and its crown the screen's side margin), so neither device hides the other.
            left = slide != "typography"
            psw = round(730 * k)
            bezel = round(psw * 0.034)
            pbw = psw + 2 * bezel
            pbh = round(psw * phone.height / phone.width) + 2 * bezel
            edge = round(56 * k)
            py = top + max(0, round((H - round(90 * k) - top - pbh) * 0.3))
            px = edge if left else W - edge - pbw
            draw_phone(c, phone, px, py, psw)
            overlap = round(bezel * 0.7)
            room = W - pbw - edge - round(44 * k) + overlap
            wsw = round(room / (1 + 2 * 0.085))
            _, _, cw, ch = watch_geometry(wsw)
            wcx = px + pbw - overlap + cw // 2 if left else px + overlap - cw // 2
            wy = py + round(pbh * 0.62) - ch // 2
            draw_watch(c, wshot, wcx, wy, wsw, strap_to=H + 40, strap_top=st)
        p = os.path.join(out_dir, f"{idx + 1:02d}-{slide}.png")
        c.convert("RGB").save(p, optimize=True)
        paths.append(p)
    return paths


def contact_sheet(rows, path, thumb_w=240):
    first = Image.open(rows[0][1][0])
    th = round(first.height * thumb_w / first.width)
    gap = 16
    label = 120
    cols = max(len(r[1]) for r in rows)
    sheet = Image.new("RGB", (label + cols * (thumb_w + gap) + gap, len(rows) * (th + gap) + gap), (30, 30, 34))
    d = ImageDraw.Draw(sheet)
    f, _ = font("sub", 28)
    for r, (lang, paths) in enumerate(rows):
        y = gap + r * (th + gap)
        d.text((14, y + th // 2 - 14), lang, font=f, fill=(255, 255, 255))
        for i, p in enumerate(paths):
            sheet.paste(Image.open(p).convert("RGB").resize((thumb_w, th), Image.LANCZOS),
                        (label + gap + i * (thumb_w + gap), y))
    sheet.save(path)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("raw", help="root of <lang>/{iphone-medium,iphone-large,watch,complications}/")
    ap.add_argument("out", nargs="?", default="composed", help="output root (default: ./composed)")
    ap.add_argument("--langs", default=",".join(LANGS))
    ap.add_argument("--no-contact", action="store_true", help="skip the contact sheets")
    a = ap.parse_args()
    langs = [l for l in a.langs.split(",") if l]
    for size_name in SIZES:
        rows = []
        for lang in langs:
            paths = compose(a.raw, lang, size_name, os.path.join(a.out, lang, size_name))
            rows.append((lang, paths))
            print(f"{lang} {size_name}: {len(paths)} images")
        if not a.no_contact:
            p = os.path.join(a.out, f"contact_{size_name}.png")
            contact_sheet(rows, p)
            print("contact sheet:", p)


if __name__ == "__main__":
    main()
