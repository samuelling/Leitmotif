"""Leitmotif's app icon: a periodic-table tile matching Aether (Ae 119) and Bellweathered (Bw 120).

Usage: python3 AppStore/make_icon.py Leitmotif/Assets.xcassets/AppIcon.appiconset/AppIcon.png \
       LeitmotifName/Assets.xcassets/AppIcon.appiconset/AppIcon.png
(tile() and the font path are copied from samuelling/Aether's AppStore/make_icons.py.)
"""
import numpy as np, colorsys, sys
from PIL import Image, ImageDraw, ImageFont, ImageFilter

S = 2048
FONT = "/usr/share/fonts/opentype/inter/InterDisplay-%s.otf"
yy, xx = np.mgrid[0:S, 0:S].astype(np.float32)

def screen(a, b): return 255 - (255 - a) * (255 - b) / 255

def motif_bg():
    """A dark plum field crossed by rows of tiny packets, a few of them lit."""
    cx, cy = S * 0.5, S * 0.40
    r = np.clip(np.sqrt((xx - cx) ** 2 + (yy - cy) ** 2) / (S * 0.8), 0, 1)[..., None]
    img = np.array([58, 18, 46], np.float32) * (1 - r) + np.array([10, 4, 10], np.float32) * r
    rng = np.random.default_rng(53)
    for yc in np.linspace(0.70, 0.88, 6):
        x = S * 0.06
        while x < S * 0.94:
            w = S * rng.choice([0.012, 0.02, 0.035, 0.06])
            lit = rng.random() < 0.22
            col = np.array([255, 92, 158] if rng.random() < 0.35 else [255, 184, 92], np.float32)
            a = (0.95 if lit else 0.18) * np.sin(np.pi * np.clip((x - S * 0.06) / (S * 0.88), 0, 1)) ** 0.6
            box = ((xx >= x) & (xx < x + w) & (np.abs(yy - yc * S) < S * 0.006)).astype(np.float32)
            glow = np.exp(-((np.maximum(np.abs(xx - (x + w / 2)) - w / 2, 0)) ** 2 + (yy - yc * S) ** 2) / (S * 0.012) ** 2)
            img = screen(img, col[None, None, :] * ((box * 0.9 + glow * 0.35 * lit) * a)[..., None])
            x += w + S * rng.choice([0.008, 0.014, 0.03])
    return img

def tile(bg, symbol, number, mass, name, glow_rgb, out):
    img = Image.fromarray(np.clip(bg, 0, 255).astype(np.uint8), "RGB").convert("RGBA")
    # Element-tile hairline frame
    frame = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    fd = ImageDraw.Draw(frame)
    m = int(S * 0.085)
    fd.rounded_rectangle([m, m, S - m, S - m], radius=int(S * 0.11), outline=(255, 255, 255, 70), width=int(S * 0.0045))
    img = Image.alpha_composite(img, frame)

    # Symbol with a tinted glow
    sym_font = ImageFont.truetype(FONT % "Light", int(S * 0.43))
    layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ld = ImageDraw.Draw(layer)
    cx, cy = S * 0.5, S * 0.40
    ld.text((cx, cy), symbol, font=sym_font, anchor="mm", fill=(250, 251, 255, 255))
    glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    gd.text((cx, cy), symbol, font=sym_font, anchor="mm", fill=glow_rgb + (230,))
    glow = glow.filter(ImageFilter.GaussianBlur(S * 0.03))
    img = Image.alpha_composite(img, glow)
    img = Image.alpha_composite(img, layer)

    # Periodic-table furniture: atomic number (top-left), atomic mass (top-right),
    # name under the symbol.
    small = ImageFont.truetype(FONT % "Regular", int(S * 0.078))
    tiny = ImageFont.truetype(FONT % "Medium", int(S * 0.050))
    td = ImageDraw.Draw(img)
    inset_x, inset_y = m + S * 0.055, m + S * 0.04
    td.text((inset_x, inset_y), number, font=small, fill=(255, 255, 255, 215))
    td.text((S - inset_x, inset_y), mass, font=small, anchor="ra", fill=(255, 255, 255, 150))
    # Name, letter-spaced, centred under the symbol
    label, track = name.upper(), S * 0.012
    widths = [td.textlength(ch, font=tiny) for ch in label]
    x = S * 0.5 - (sum(widths) + track * (len(label) - 1)) / 2
    for ch, w in zip(label, widths):
        td.text((x, S * 0.632), ch, font=tiny, anchor="lm", fill=(255, 255, 255, 175))
        x += w + track

    img.convert("RGB").resize((1024, 1024), Image.LANCZOS).save(out)

# 121, the next element after Bellweathered; mass [1500], the size of a full packet (the MTU).
tile(motif_bg(), "Lm", "121", "[1500]", "Leitmotif", (255, 110, 170), sys.argv[1])
# Leitmotif Name, the personal edition: 122, mass [53], the port every DNS lookup is asked on.
if len(sys.argv) > 2:
    tile(motif_bg(), "Ln", "122", "[53]", "Leitmotif Name", (255, 184, 92), sys.argv[2])
print("ok")
