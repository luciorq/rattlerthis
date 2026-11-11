"""Draft rattlerthis hex logos (4 concepts) in the condathis family.

Writes logo-1-rattle.svg ... logo-4-backend.svg into the directory given
as the first argument. With --png, also renders each one with rsvg-convert.
With --logo, writes the chosen concept (1, variant 1c: the plate inside the
hex) as logo.svg and a 240 px wide
logo.png instead, the size `usethis::use_logo()` uses.
Run through pixi (see pixi.toml): `pixi run png` or `pixi run logo`.
"""

import math
import shutil
import subprocess
import sys
from pathlib import Path

W, H = 518, 600
CX, CY = 259.0, 300.0
R_OUT = 290.0  # outer hex (rim)
R_IN = 248.0  # dark inner hex
R_BOX = 214.0  # box faces

COS30 = math.cos(math.radians(30))

# Palette
AMBER = "#F29B30"
AMBER_DK = "#B8641A"
AMBER_LT = "#FFC56B"
INK = "#141414"
WALL_L = "#2C2C2C"
WALL_R = "#383838"
FLOOR = "#212121"
RIBBON = "#E4E4E4"
RIBBON_DK = "#9A9A9A"
TEXT = "#F2F2F2"

# Text is written as glyph outlines from DejaVu Sans Mono Bold (the
# font-ttf-dejavu conda package), so the SVGs render the same everywhere.
_FONT = None


def font():
    global _FONT
    if _FONT is None:
        from fontTools.ttLib import TTFont

        prefix = Path(sys.prefix)
        for d in (prefix / "fonts", prefix / "Library" / "fonts", prefix / "Library" / "Fonts"):
            f = d / "DejaVuSansMono-Bold.ttf"
            if f.exists():
                _FONT = TTFont(f)
                break
        else:
            sys.exit("DejaVuSansMono-Bold.ttf not found: run this through pixi (see pixi.toml)")
    return _FONT


def text_path(txt, x, y, size, color, anchor="start"):
    """One <path> with the outlines of txt, baseline at y."""
    from fontTools.pens.svgPathPen import SVGPathPen
    from fontTools.pens.transformPen import TransformPen

    f = font()
    glyphs = f.getGlyphSet()
    cmap = f.getBestCmap()
    scale = size / f["head"].unitsPerEm
    names = [cmap[ord(ch)] for ch in txt]
    total = sum(f["hmtx"][n][0] for n in names) * scale
    cx = x - total / 2 if anchor == "middle" else x
    d = []
    for n in names:
        pen = SVGPathPen(glyphs, ntos=lambda v: f"{v:.1f}")
        glyphs[n].draw(TransformPen(pen, (scale, 0, 0, -scale, cx, y)))
        d.append(pen.getCommands())
        cx += f["hmtx"][n][0] * scale
    return f'<path d="{" ".join(c for c in d if c)}" fill="{color}"/>'



def hexpts(r, cx=CX, cy=CY):
    """Pointy-top hexagon vertices: T, UR, LR, B, LL, UL."""
    out = []
    for a in (-90, -30, 30, 90, 150, 210):
        t = math.radians(a)
        out.append((cx + r * math.cos(t), cy + r * math.sin(t)))
    return out


def poly(pts, **attrs):
    d = " ".join(f"{x:.1f},{y:.1f}" for x, y in pts)
    a = " ".join(f'{k.replace("_", "-")}="{v}"' for k, v in attrs.items())
    return f'<polygon points="{d}" {a}/>'


def svg_doc(body, title):
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" '
        f'viewBox="0 0 {W} {H}">\n<title>{title}</title>\n{body}\n</svg>\n'
    )


def rim(fill=AMBER, edge=AMBER_DK):
    o = hexpts(R_OUT)
    i = hexpts(R_IN)
    return poly(o, fill=fill, stroke=edge, stroke_width=8, stroke_linejoin="round") + poly(
        i, fill=INK
    )


def box_interior():
    """Open box seen from above: back corner on the C-T edge."""
    T, UR, LR, B, LL, UL = hexpts(R_BOX)
    C = (CX, CY)
    s = ""
    s += poly([C, LL, UL, T], fill=WALL_L)
    s += poly([C, T, UR, LR], fill=WALL_R)
    s += poly([C, LR, B, LL], fill=FLOOR)
    # inner edges
    for p in (T, LL, LR):
        s += f'<line x1="{CX}" y1="{CY}" x2="{p[0]:.1f}" y2="{p[1]:.1f}" stroke="#4a4a4a" stroke-width="3"/>'
    return s


def wall_text(txt, x, y, plane, size=34, color=AMBER_LT):
    m = {
        # left wall: horizontal runs up-right toward the back corner
        "left": f"matrix({COS30:.4f},-0.5,0,1,{x},{y})",
        # right wall: horizontal runs down-right away from the corner
        "right": f"matrix({COS30:.4f},0.5,0,1,{x},{y})",
        # floor: x along C->LR, y along C->LL
        "floor": f"matrix({COS30:.4f},0.5,{-COS30:.4f},0.5,{x},{y})",
    }[plane]
    return f'<g transform="{m}">{text_path(txt, 0, 0, size, color)}</g>'


def prompts():
    return (
        # at the snake's head, where it reads as a forked tongue
        wall_text(">_", 112, 205, "left")
        + wall_text("$ rattler", 286, 150, "right", size=26, color=TEXT)
        + wall_text("$_", 140, 418, "floor", size=40)
    )


def name_tag(text="rattlerthis", y=500, plate="overhang"):
    """plate: "overhang" (over the bottom-right edge of the hex), "bottom"
    (centred at the bottom, inside the hex) or "rim" (along the bottom-right
    rim, slanted like it)."""
    if plate == "bottom":
        # Inside the dark inner hex: its bottom edges leave a 236-wide plate
        # about 13 px of black on each side at y = 472.
        w, h, size = 236, 48, 30
        x, y = CX - w / 2, 424
        return (
            f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="5" fill="{INK}" '
            f'stroke="{AMBER}" stroke-width="3.5"/>'
            + text_path(text, CX, y + 34, size, TEXT, anchor="middle")
        )
    if plate == "rim":
        # Centred on the rim band of the LR-B edge; local u runs along the
        # edge (up-right), local v stays vertical.
        w, h, size = 236, 40, 27
        r_mid = (R_OUT + R_IN) / 2 * COS30
        cx = CX + r_mid * math.cos(math.radians(60))
        cy = CY + r_mid * math.sin(math.radians(60))
        x0, y0 = cx - COS30 * w / 2, cy + 0.5 * w / 2
        return (
            f'<g transform="matrix({COS30:.4f},-0.5,0,1,{x0:.1f},{y0:.1f})">'
            f'<rect x="0" y="{-h / 2}" width="{w}" height="{h}" rx="4" fill="{INK}" '
            f'stroke="{AMBER_DK}" stroke-width="3"/>'
            + text_path(text, w / 2, size * 0.36, size, TEXT, anchor="middle")
            + "</g>"
        )
    w = 262
    x = 222
    return (
        f'<rect x="{x}" y="{y}" width="{w}" height="56" rx="5" fill="{INK}" '
        f'stroke="{AMBER}" stroke-width="3.5"/>'
        + text_path(text, x + w / 2, y + 39, 33, TEXT, anchor="middle")
    )


RIBBON_PATH = (
    "M 150,170 C 175,150 205,175 200,215 "
    "C 195,265 150,290 175,335 "
    "C 200,380 280,385 330,370 "
    "C 375,357 405,345 430,338"
)


def ribbon(path=RIBBON_PATH, width=30):
    return (
        f'<path d="{path}" fill="none" stroke="{RIBBON_DK}" stroke-width="{width + 8}" '
        f'stroke-linecap="round" stroke-linejoin="round"/>'
        f'<path d="{path}" fill="none" stroke="{RIBBON}" stroke-width="{width}" '
        f'stroke-linecap="round" stroke-linejoin="round"/>'
    )


def rattle_segments(x0, y0, angle_deg, n=5, w0=34, h0=26, gap=0.78):
    """Rounded rattle segments along a direction, shrinking toward the tip."""
    s = ""
    a = math.radians(angle_deg)
    dx, dy = math.cos(a), math.sin(a)
    x, y = x0, y0
    w, h = w0, h0
    for k in range(n):
        fill = AMBER_LT if k % 2 == 0 else AMBER
        s += (
            f'<ellipse cx="{x:.1f}" cy="{y:.1f}" rx="{w / 2:.1f}" ry="{h / 2:.1f}" '
            f'transform="rotate({angle_deg + 90:.1f} {x:.1f} {y:.1f})" '
            f'fill="{fill}" stroke="{AMBER_DK}" stroke-width="3.5"/>'
        )
        step = h * gap
        x += dx * step
        y += dy * step
        w *= 0.88
        h *= 0.9
    return s


def iso_cube(cx, cy, r, top, left, right, edge=INK, sw=2.5):
    """Solid cube seen from above, centred on its near vertical edge top."""
    T, UR, LR, B, LL, UL = hexpts(r, cx, cy)
    C = (cx, cy)
    return (
        poly([C, UL, T, UR], fill=top, stroke=edge, stroke_width=sw, stroke_linejoin="round")
        + poly([C, UR, LR, B], fill=right, stroke=edge, stroke_width=sw, stroke_linejoin="round")
        + poly([C, B, LL, UL], fill=left, stroke=edge, stroke_width=sw, stroke_linejoin="round")
    )


# ---------------------------------------------------------------- concept 1
# The chosen logo. The snake lies on the box's panels: it is laid out in box
# coordinates and projected isometrically, so each part follows the slant of
# its panel. Head on the left wall (the ">_" prompt is its forked tongue),
# down the wall, over the edge onto the floor, and out toward the name tag,
# where the rattle peeks out from behind it.

# Box axes on screen, from the back bottom corner C: x along the floor toward
# the right wall's front (C->LR), y along the floor toward the left wall's
# front (C->LL), z up the back edge (C->T).
AX = (COS30, 0.5)
AY = (-COS30, 0.5)


# The body's shape is the first draft's hand-drawn curve. Drawn flat on the
# screen, it crossed the wall-floor edge without bending. Here it is mapped
# onto the wall and the floor unfolded into one flat sheet, smoothed there,
# and folded back, so it bends exactly where the panels meet.
BODY_PATH_1 = (
    "M 150,170 C 175,150 205,175 200,215 "
    "C 195,265 150,290 175,335 "
    "C 200,380 280,370 330,395 "
    "C 360,410 380,430 395,450 "
    "C 410,470 425,480 438,488"
)


def iso(x, y, z):
    return (CX + x * AX[0] + y * AY[0], CY + x * AX[1] + y * AY[1] - z)


def sample_path(d, per_segment=80):
    """Points along an 'M x,y C x,y x,y x,y ...' path."""
    nums = [tuple(map(float, t.split(","))) for t in d.replace("M", " ").replace("C", " ").split()]
    p0, rest = nums[0], nums[1:]
    pts = [p0]
    for k in range(0, len(rest), 3):
        c1, c2, p3 = rest[k : k + 3]
        for n in range(1, per_segment + 1):
            t = n / per_segment
            a, b, c, e = (1 - t) ** 3, 3 * (1 - t) ** 2 * t, 3 * (1 - t) * t**2, t**3
            pts.append(
                (
                    a * p0[0] + b * c1[0] + c * c2[0] + e * p3[0],
                    a * p0[1] + b * c1[1] + c * c2[1] + e * p3[1],
                )
            )
        p0 = p3
    return pts


def to_sheet(sx, sy):
    """Screen point -> (u, v) on the unfolded sheet: u runs along the
    wall-floor edge (box y); v > 0 is height on the left wall (z), v < 0 is
    distance across the floor (-x)."""
    dx, dy = sx - CX, sy - CY
    y = -dx / COS30
    z = 0.5 * y - dy
    if z >= 0:  # on the left wall (x = 0)
        return (y, z)
    x = (dx / COS30 + 2 * dy) / 2  # on the floor (z = 0)
    y = (2 * dy - dx / COS30) / 2
    return (y, -x)


def from_sheet(u, v):
    return iso(0, u, v) if v >= 0 else iso(-v, u, 0)


def snake_centerline(path=BODY_PATH_1, window=13):
    sheet = [to_sheet(*p) for p in sample_path(path)]
    return [from_sheet(u, v) for u, v in smooth(sheet, window)]


def smooth(pts, window):
    """Moving average; the ends stay where they are."""
    h = window // 2
    out = []
    for k in range(len(pts)):
        if k < h or k >= len(pts) - h:
            out.append(pts[k])
            continue
        xs = [p[0] for p in pts[k - h : k + h + 1]]
        ys = [p[1] for p in pts[k - h : k + h + 1]]
        out.append((sum(xs) / len(xs), sum(ys) / len(ys)))
    return out


def tapered_body(pts, w_full=30, w_tip=13, taper_from=0.6, outline=4):
    """Filled outline of a body whose width narrows toward the tail."""
    seg = [math.dist(pts[k], pts[k + 1]) for k in range(len(pts) - 1)]
    total = sum(seg)
    acc = [0.0]
    for d in seg:
        acc.append(acc[-1] + d)

    def width(k):
        f = acc[k] / total
        if f <= taper_from:
            return w_full
        u = (f - taper_from) / (1 - taper_from)
        return w_full - (w_full - w_tip) * u**1.3

    def shape(extra, fill):
        left, right = [], []
        for k, (px, py) in enumerate(pts):
            a = pts[max(k - 1, 0)]
            b = pts[min(k + 1, len(pts) - 1)]
            dx, dy = b[0] - a[0], b[1] - a[1]
            norm = math.hypot(dx, dy) or 1.0
            nx, ny = -dy / norm, dx / norm
            h = width(k) / 2 + extra
            left.append((px + nx * h, py + ny * h))
            right.append((px - nx * h, py - ny * h))
        hx, hy = pts[0]
        return poly(left + right[::-1], fill=fill, stroke=fill, stroke_width=1,
                    stroke_linejoin="round") + (
            f'<circle cx="{hx:.1f}" cy="{hy:.1f}" r="{w_full / 2 + extra + 1:.1f}" fill="{fill}"/>'
        )

    return shape(outline, RIBBON_DK) + shape(0, RIBBON)


def concept1(tail="above", plate="bottom"):
    """tail: "behind" the name plate (the rattle peeks out), "front" (drawn
    over the plate), or "above" (the body ends earlier and flatter, so the
    rattle sits above the plate; drawn in front of it). plate: see
    name_tag()."""
    body = rim() + box_interior()
    body += wall_text(">_", 112, 205, "left")  # the forked tongue
    body += wall_text("$ run", 300, 158, "right", size=28, color=TEXT)
    if tail == "above":
        # the last two curves flatten out, so the rattle clears the plate
        path = BODY_PATH_1.rsplit(" C ", 2)[0] + " C 360,410 385,422 410,430"
    else:
        path = BODY_PATH_1
    pts = snake_centerline(path)
    (ax, ay), (bx, by) = pts[-4], pts[-1]
    angle = math.degrees(math.atan2(by - ay, bx - ax))
    a = math.radians(angle)
    snake = tapered_body(pts)
    snake += rattle_segments(bx + 7 * math.cos(a), by + 7 * math.sin(a), angle, n=5)
    if tail in ("front", "above"):
        body += name_tag(plate=plate) + snake
    else:
        body += snake + name_tag(plate=plate)
    return svg_doc(body, "rattlerthis logo: the snake grows a rattle")


# ---------------------------------------------------------------- concept 2
def concept2():
    body = rim() + box_interior() + prompts()
    body += ribbon(RIBBON_PATH)
    # rattle made of small conda-package cubes, shrinking along the tail
    x, y, r = 430, 336, 20.0
    shades = [(AMBER_LT, AMBER_DK, AMBER), (AMBER, AMBER_DK, AMBER_LT)]
    a = math.radians(-20)
    for k in range(3):
        top, left, right = shades[k % 2]
        body += iso_cube(x, y, r, top, left, right)
        step = r * 1.55
        r *= 0.82
        x += math.cos(a) * step
        y += math.sin(a) * step
    body += name_tag()
    return svg_doc(body, "rattlerthis concept 2: a rattle of packages")


# ---------------------------------------------------------------- concept 3
TAN = "#C99A5B"
TAN_DK = "#7A5530"
DIAMOND = "#3B2614"
CREAM = "#F3E3BF"


def diamond_rim():
    o = hexpts(R_OUT)
    i = hexpts(R_IN)
    s = poly(o, fill=TAN, stroke=TAN_DK, stroke_width=8, stroke_linejoin="round")
    rmid = (R_OUT + R_IN) / 2
    m = hexpts(rmid)
    band = R_OUT - R_IN
    for k in range(6):
        (x1, y1), (x2, y2) = m[k], m[(k + 1) % 6]
        ang = math.degrees(math.atan2(y2 - y1, x2 - x1))
        n = 5
        for j in range(n):
            t = (j + 0.5) / n
            x = x1 + (x2 - x1) * t
            y = y1 + (y2 - y1) * t
            L = math.dist((x1, y1), (x2, y2)) / n * 0.5
            hgt = band * 0.42
            pts = [(-L, 0), (0, -hgt), (L, 0), (0, hgt)]
            d = " ".join(f"{px:.1f},{py:.1f}" for px, py in pts)
            s += (
                f'<polygon points="{d}" transform="translate({x:.1f},{y:.1f}) rotate({ang:.1f})" '
                f'fill="{DIAMOND}" stroke="{CREAM}" stroke-width="3.5" stroke-linejoin="round"/>'
            )
    s += poly(i, fill=INK)
    return s


def concept3():
    body = diamond_rim() + box_interior() + prompts()
    body += ribbon(RIBBON_PATH)
    tag = name_tag().replace(AMBER, TAN)
    body += tag
    return svg_doc(body, "rattlerthis concept 3: diamondback border")


# ---------------------------------------------------------------- concept 4
def concept4():
    body = rim()
    # coil behind the box: isometric rings on the "floor" around its base
    for k, (rx, ry, yy) in enumerate([(205, 92, 418), (180, 80, 392), (155, 68, 368)]):
        body += (
            f'<ellipse cx="{CX}" cy="{yy}" rx="{rx}" ry="{ry}" fill="none" '
            f'stroke="{RIBBON_DK}" stroke-width="40"/>'
            f'<ellipse cx="{CX}" cy="{yy}" rx="{rx}" ry="{ry}" fill="none" '
            f'stroke="{RIBBON}" stroke-width="32"/>'
        )
    # rattle raised behind the box, top right
    tail = "M 372,350 C 400,300 400,220 385,170"
    body += ribbon(tail, width=26)
    body += rattle_segments(383, 160, -95, n=5, w0=32, h0=24)
    # the box, seen from outside (its back)
    bx, by, br = CX - 10, 300, 128
    body += iso_cube(bx, by, br, "#3a3a3a", "#262626", "#303030", edge="#555", sw=3)
    T, UR, LR, B, LL, UL = hexpts(br, bx, by)
    # vent slats on the left back face: P = C + u (UL - C) + v (B - C)
    def on_face(p, q, u, v):
        return (bx + u * (p[0] - bx) + v * (q[0] - bx), by + u * (p[1] - by) + v * (q[1] - by))

    for k in range(5):
        v = 0.2 + k * 0.14
        x1, y1 = on_face(UL, B, 0.18, v)
        x2, y2 = on_face(UL, B, 0.82, v)
        body += (
            f'<line x1="{x1:.1f}" y1="{y1:.1f}" x2="{x2:.1f}" y2="{y2:.1f}" '
            f'stroke="{AMBER}" stroke-width="7" stroke-linecap="round"/>'
        )
    # back-panel label on the right face (its horizontal runs up-right)
    lx, ly = on_face(UR, B, 0.14, 0.6)
    body += wall_text("backend", round(lx, 1), round(ly, 1), "left", size=24, color=AMBER_LT)
    # snake head peeking out on the left
    hx, hy = 98, 300
    body += (
        f'<path d="M 150,360 C 120,350 95,335 {hx},{hy}" fill="none" stroke="{RIBBON_DK}" '
        f'stroke-width="40" stroke-linecap="round"/>'
        f'<path d="M 150,360 C 120,350 95,335 {hx},{hy}" fill="none" stroke="{RIBBON}" '
        f'stroke-width="32" stroke-linecap="round"/>'
        f'<ellipse cx="{hx}" cy="{hy - 12}" rx="30" ry="22" fill="{RIBBON}" '
        f'stroke="{RIBBON_DK}" stroke-width="4" transform="rotate(-20 {hx} {hy - 12})"/>'
        f'<circle cx="{hx + 10}" cy="{hy - 20}" r="5" fill="{INK}"/>'
        f'<path d="M {hx - 26},{hy - 4} l -16,6 m 16,-6 l -14,-8" stroke="{AMBER}" '
        f'stroke-width="4" fill="none" stroke-linecap="round"/>'
    )
    body += name_tag()
    return svg_doc(body, "rattlerthis concept 4: the backend, from behind")


def render(svg, png, width):
    exe = shutil.which("rsvg-convert")
    if exe is None:
        sys.exit("rsvg-convert not found: run this through pixi (see pixi.toml)")
    subprocess.run([exe, "--width", str(width), "--output", str(png), str(svg)], check=True)


def main():
    flags = {"--png", "--logo"}
    args = [a for a in sys.argv[1:] if a not in flags]
    png = "--png" in sys.argv[1:]
    out = Path(args[0])
    out.mkdir(parents=True, exist_ok=True)
    if "--logo" in sys.argv[1:]:
        svg = out / "logo.svg"
        svg.write_text(concept1())
        render(svg, svg.with_suffix(".png"), 240)
        print(svg, svg.with_suffix(".png"), sep="\n")
        return
    for name, fn in [
        ("logo-1-rattle", concept1),
        ("logo-1-tail-behind", lambda: concept1("behind", plate="overhang")),
        ("logo-1a-tail-front", lambda: concept1("front", plate="overhang")),
        ("logo-1b-tail-above", lambda: concept1("above", plate="overhang")),
        ("logo-1d-plate-rim", lambda: concept1("above", plate="rim")),
        ("logo-2-package-rattle", concept2),
        ("logo-3-diamondback", concept3),
        ("logo-4-backend", concept4),
    ]:
        svg = out / f"{name}.svg"
        svg.write_text(fn())
        print(svg)
        if png:
            render(svg, svg.with_suffix(".png"), W)
            print(svg.with_suffix(".png"))


if __name__ == "__main__":
    main()
