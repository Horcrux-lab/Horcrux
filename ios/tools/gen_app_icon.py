"""
Generate Horcrux iOS app icon (1024x1024, opaque RGB).

Matches the in-app AnimatedShieldLogo vocabulary:
  - Deep purple / midnight gradient background (HorcruxTheme)
  - Soft purple radial glow
  - Classic heater-shield silhouette
  - Left half filled with purple→cyan vertical gradient
  - Right half filled white (mirrors `shield.lefthalf.filled`)
  - Thin white bezel around the shield
"""
from PIL import Image, ImageDraw, ImageFilter, ImageChops
import math

SIZE = 1024
cx = cy = SIZE / 2

# ---------- Background: diagonal gradient ----------
bg = Image.new("RGB", (SIZE, SIZE))
px = bg.load()
top_left = (92, 33, 182)      # #5C21B6 — brand purple
bot_right = (20, 10, 50)      # deep midnight
for y in range(SIZE):
    for x in range(SIZE):
        t = (x + y) / (2 * SIZE)
        r = int(top_left[0] * (1 - t) + bot_right[0] * t)
        g = int(top_left[1] * (1 - t) + bot_right[1] * t)
        b = int(top_left[2] * (1 - t) + bot_right[2] * t)
        px[x, y] = (r, g, b)
bg = bg.convert("RGBA")

# ---------- Soft radial purple glow behind shield ----------
glow = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
gd = ImageDraw.Draw(glow)
gr = 380
gd.ellipse([cx - gr, cy - gr, cx + gr, cy + gr], fill=(124, 58, 237, 200))
glow = glow.filter(ImageFilter.GaussianBlur(130))
bg = Image.alpha_composite(bg, glow)

# ---------- Shield silhouette ----------
def shield_polygon(cx, cy, w, h, steps=60):
    """Heater-shield: straight top, curved sides tapering to a rounded point."""
    half_w = w / 2
    top = cy - h / 2
    bot = cy + h / 2
    # Top edge (slight dip for visual weight)
    pts = [(cx - half_w, top), (cx + half_w, top)]
    # Right side: quadratic bezier from (cx+half_w, top) → (cx, bot), control at (cx+half_w, top + h*0.62)
    for i in range(1, steps + 1):
        t = i / steps
        ctrl = (cx + half_w, top + h * 0.62)
        p0 = (cx + half_w, top)
        p1 = ctrl
        p2 = (cx, bot)
        xx = (1 - t) ** 2 * p0[0] + 2 * (1 - t) * t * p1[0] + t ** 2 * p2[0]
        yy = (1 - t) ** 2 * p0[1] + 2 * (1 - t) * t * p1[1] + t ** 2 * p2[1]
        pts.append((xx, yy))
    # Left side: back up
    for i in range(1, steps + 1):
        t = i / steps
        p0 = (cx, bot)
        p1 = (cx - half_w, top + h * 0.62)
        p2 = (cx - half_w, top)
        xx = (1 - t) ** 2 * p0[0] + 2 * (1 - t) * t * p1[0] + t ** 2 * p2[0]
        yy = (1 - t) ** 2 * p0[1] + 2 * (1 - t) * t * p1[1] + t ** 2 * p2[1]
        pts.append((xx, yy))
    return pts

SW, SH = 560, 680
poly = shield_polygon(cx, cy, SW, SH)

# Shield mask (opaque where shield is)
shield_mask = Image.new("L", (SIZE, SIZE), 0)
ImageDraw.Draw(shield_mask).polygon(poly, fill=255)

# ---------- Fill shield: left half = purple→cyan gradient, right half = white ----------
shield_fill = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
sfp = shield_fill.load()
for y in range(SIZE):
    # Vertical gradient for the left half
    t = (y - (cy - SH / 2)) / SH
    t = max(0.0, min(1.0, t))
    # purple at top (#7C3AED) → cyan at bottom (#10D0E0)
    r = int(124 * (1 - t) + 16 * t)
    g = int(58 * (1 - t) + 208 * t)
    b = int(237 * (1 - t) + 224 * t)
    for x in range(SIZE):
        if x < cx:
            sfp[x, y] = (r, g, b, 255)
        else:
            # Right half: subtle white with a faint top→bottom dim
            w = int(245 - 20 * t)
            sfp[x, y] = (w, w, 255 if w > 240 else w + 5, 255)

# Clip fill to shield mask
shield_fill.putalpha(ImageChops.multiply(shield_fill.split()[3], shield_mask))

# Drop shadow under the shield for separation
shadow = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
ImageDraw.Draw(shadow).polygon(poly, fill=(0, 0, 0, 130))
shadow = shadow.filter(ImageFilter.GaussianBlur(28))
bg = Image.alpha_composite(bg, shadow)
bg = Image.alpha_composite(bg, shield_fill)

# ---------- Thin white bezel + subtle highlight stripe ----------
bezel = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
ImageDraw.Draw(bezel).polygon(poly, outline=(255, 255, 255, 220), width=6)
bg = Image.alpha_composite(bg, bezel)

# Soft top highlight arc on the shield
hl = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
hld = ImageDraw.Draw(hl)
hld.ellipse(
    [cx - SW * 0.45, cy - SH / 2 - 30, cx + SW * 0.45, cy - SH * 0.1],
    fill=(255, 255, 255, 55),
)
hl = hl.filter(ImageFilter.GaussianBlur(16))
# Clip highlight to shield
hl.putalpha(ImageChops.multiply(hl.split()[3], shield_mask))
bg = Image.alpha_composite(bg, hl)

# ---------- Center divider line (subtle) ----------
divider = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
ImageDraw.Draw(divider).line(
    [(cx, cy - SH / 2), (cx, cy + SH / 2)],
    fill=(255, 255, 255, 60),
    width=3,
)
divider.putalpha(ImageChops.multiply(divider.split()[3], shield_mask))
bg = Image.alpha_composite(bg, divider)

# ---------- Flatten to RGB (iOS app icons must be opaque) ----------
final = bg.convert("RGB")
out = "/tmp/horcrux_icon.png"
final.save(out, "PNG", optimize=True)
print("saved", out, final.size)
