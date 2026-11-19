"""
The disc stage's generated sources (patch_sm64ex.py writes them into the sm64ex checkout):
- mosaic_c(png): the boxes laid out on the disc, one a pixel of a picture (unity_stage.inc.h includes it);
- pictures(): the disc's own pictures, for base.zip (install_mario64mr.py packs them). (The disc's mesh is made as
  the game runs, for it changes shape: unity_stage.inc.h.)

The art: your own goes in stage/local/ (ignored by git, so never pushed: like the ROM, it's yours to supply), and
where a file isn't there, the placeholder of the same name in stage/ (committed, ours) is used instead:
- mosaic.png: every pixel more than half opaque is a box of its colour, the picture's top row furthest from the
  stage's pipe;
- disc.png: the disc's top, the picture spanning it (its top row furthest from the pipe, as the mosaic's);
- pizza.png: the disc's top when it's a pizza, the same way;
- box_side.png: embossed on the boxes' sides, monochrome, as on a coin (its opaque part raised). It has no
  placeholder: without it, the game's own Mario head is used, from your ROM (box_side).
Python's own libraries only (no Pillow): 8-bit RGB or RGBA PNGs, or palette ones (1, 2, 4 or 8 bits, with
transparency).
"""
import math
import struct
import zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent
PLACEHOLDERS = HERE / "stage"
LOCAL_ART = PLACEHOLDERS / "local"


def art(name):
    """Your own art of that name if it's in stage/local/, else our placeholder"""
    local = LOCAL_ART / name
    return local if local.exists() else PLACEHOLDERS / name



# The disc's pictures (yours in stage/local/, else stage/'s placeholders: make_placeholders), packed into base.zip
# by install_mario64mr.py as the textures the game draws the disc with (unity_stage.inc.h names them the same). Any
# size, square: the picture spans the disc, its top row furthest from the stage's pipe.
PICTURES = {
    "disc.png": "levels/castle_grounds/stage_disc.rgba32",
    "pizza.png": "levels/castle_grounds/stage_pizza.rgba32",
}


def pictures(work=None):
    """[(the picture's file, its name in base.zip)]: the disc's, and with the extracted sm64ex checkout (work), the
    boxes' embossed side, made into it (box_side)"""
    files = [(art(name), "gfx/" + texture + ".png") for name, texture in PICTURES.items()]
    if work is not None:
        side = box_side(work, Path(work) / "build" / "stage_gen")
        if side is None:
            raise FileNotFoundError("no picture for the boxes' sides: stage/local/box_side.png, or the ROM's " + ROM_HEAD)
        files.append((side, "gfx/" + BOX_SIDE + ".png"))
    return files


def _mix(a, b, t):
    t = min(1.0, max(0.0, t))
    return tuple(round(x + (y - x) * t) for x, y in zip(a, b))


def _placeholder_disc(size):
    rows = []
    for py in range(size):
        row = []
        for px in range(size):
            x, z = (px + 0.5) / size * 2 - 1, (py + 0.5) / size * 2 - 1
            r = math.hypot(x, z)
            check = (int((x + 1) * 8) + int((z + 1) * 8)) % 2
            c = (0xF2, 0xE6, 0xC4) if check else (0xE4, 0xD4, 0xAC)
            c = _mix(c, (0xC8, 0xB0, 0x80), (r - 0.75) / 0.25)
            if abs(r - 0.93) < 0.012 or r < 0.04:
                c = (0x9C, 0x7A, 0x52)
            row.append(c + (255,))
        rows.append(row)
    return rows


def _placeholder_pizza(size):
    toppings = [(0.0, 0.0)] + [(0.42 * math.sin(a), 0.42 * math.cos(a)) for a in
                               (2 * math.pi * (i + 0.5) / 6 for i in range(6))] + \
               [(0.7 * math.sin(a), 0.7 * math.cos(a)) for a in (2 * math.pi * i / 9 for i in range(9))]
    rows = []
    for py in range(size):
        row = []
        for px in range(size):
            x, z = (px + 0.5) / size * 2 - 1, (py + 0.5) / size * 2 - 1
            r = math.hypot(x, z)
            if r > 0.88:  # the crust, browner to its outside
                c = _mix((0xE0, 0xA8, 0x58), (0xA8, 0x68, 0x2C), (r - 0.88) / 0.12)
            elif r > 0.84:  # sauce showing
                c = (0xC0, 0x30, 0x20)
            else:  # cheese, blotched, with pepperoni
                blotch = math.sin(x * 23) * math.sin(z * 19) + math.sin((x + z) * 31) * 0.5
                c = _mix((0xF8, 0xD8, 0x60), (0xF0, 0xB8, 0x40), blotch * 0.5 + 0.3)
                for tx, tz in toppings:
                    d = math.hypot(x - tx, z - tz)
                    if d < 0.1:
                        c = _mix((0xB8, 0x28, 0x20), (0x88, 0x18, 0x14), d / 0.1)
                        if math.sin(px * 1.7) * math.sin(py * 1.3) > 0.85:
                            c = (0x70, 0x10, 0x10)
            # Cut into eight slices
            if r < 0.9:
                a = math.atan2(x, z) % (math.pi / 4)
                if min(a, math.pi / 4 - a) * r < 0.006:
                    c = _mix(c, (0x90, 0x50, 0x20), 0.6)
            row.append(c + (255,))
        rows.append(row)
    return rows


def make_placeholders(size=256):
    """stage/'s placeholder pictures (committed: run this to remake them)"""
    write_png(PLACEHOLDERS / "disc.png", _placeholder_disc(size))
    write_png(PLACEHOLDERS / "pizza.png", _placeholder_pizza(size))


def read_png(path):
    """(width, height, rows of (r, g, b, a))"""
    data = Path(path).read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError(f"{path}: not a PNG")
    pos, idat, palette, alpha = 8, b"", None, None
    while pos < len(data):
        length, kind = struct.unpack(">I4s", data[pos:pos + 8])
        chunk = data[pos + 8:pos + 8 + length]
        pos += 12 + length
        if kind == b"IHDR":
            width, height, depth, colour, _, _, interlace = struct.unpack(">IIBBBBB", chunk)
        elif kind == b"PLTE":
            palette = [tuple(chunk[i:i + 3]) for i in range(0, len(chunk), 3)]
        elif kind == b"tRNS":
            alpha = chunk
        elif kind == b"IDAT":
            idat += chunk
    if interlace:
        raise ValueError(f"{path}: interlaced PNGs aren't read; save it without interlacing")
    if colour == 3:
        if depth not in (1, 2, 4, 8):
            raise ValueError(f"{path}: palette depth {depth}")
        channels, bits = 1, depth
    elif colour in (2, 6) and depth == 8:
        channels, bits = (3 if colour == 2 else 4), 8
    else:
        raise ValueError(f"{path}: save it as 8-bit RGB, RGBA or a palette PNG")
    stride = (width * channels * bits + 7) // 8
    step = max(1, channels * bits // 8)
    raw = zlib.decompress(idat)
    rows, previous = [], bytearray(stride)
    for y in range(height):
        kind = raw[y * (stride + 1)]
        line = bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for i in range(stride):
            left = line[i - step] if i >= step else 0
            up = previous[i]
            corner = previous[i - step] if i >= step else 0
            if kind == 1:
                line[i] = (line[i] + left) & 0xFF
            elif kind == 2:
                line[i] = (line[i] + up) & 0xFF
            elif kind == 3:
                line[i] = (line[i] + (left + up) // 2) & 0xFF
            elif kind == 4:
                p = left + up - corner
                pa, pb, pc = abs(p - left), abs(p - up), abs(p - corner)
                line[i] = (line[i] + (left if pa <= pb and pa <= pc else up if pb <= pc else corner)) & 0xFF
        previous = line
        pixels = []
        for x in range(width):
            if colour == 3:
                bit = x * bits
                i = (line[bit // 8] >> (8 - bits - bit % 8)) & ((1 << bits) - 1)
                r, g, b = palette[i]
                a = alpha[i] if alpha and i < len(alpha) else 255
            else:
                r, g, b = line[x * channels:x * channels + 3]
                a = line[x * channels + 3] if channels == 4 else 255
            pixels.append((r, g, b, a))
        rows.append(pixels)
    return width, height, rows


def write_png(path, rows):
    """An 8-bit RGBA PNG of rows of (r, g, b, a) (for the placeholder picture)"""
    height, width = len(rows), len(rows[0])
    raw = b"".join(b"\0" + bytes(c for p in row for c in p) for row in rows)

    def chunk(kind, body):
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF)
    Path(path).write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
                           + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


def mosaic_c(path=None):
    path = path or art("mosaic.png")
    width, height, rows = read_png(path)
    boxes = [(x, y, p) for y, row in enumerate(rows) for x, p in enumerate(row) if p[3] >= 128]
    if not boxes:
        raise ValueError(f"{path}: no opaque pixels, so no boxes")
    out = ["/* Generated by stage_gen.py from %s: %dx%d, %d boxes */\n" % (Path(path).relative_to(HERE), width, height, len(boxes)),
           "#define STAGE_MOSAIC_WIDTH %d\n#define STAGE_MOSAIC_HEIGHT %d\n#define STAGE_MOSAIC_BOXES %d\n"
           % (width, height, len(boxes)),
           "static const struct { u8 column, row, r, g, b; } stage_mosaic[STAGE_MOSAIC_BOXES] = {\n"]
    for x, y, (r, g, b, _) in boxes:
        out.append("    { %d, %d, 0x%02x, 0x%02x, 0x%02x },\n" % (x, y, r, g, b))
    out.append("};\n")
    return "".join(out)


# ---- The boxes' sides: a picture embossed on them, monochrome, as on the side of a coin ----
# The picture: yours, box_side.png in stage/local/ (any size, its opaque part raised), else the game's own Mario head
# (the HUD's, from the ROM: extracted with the rest of its textures, so never committed). Made at build time into a
# grey relief the game multiplies the box's colour by (unity_stage.inc.h, geo_stage_box).
BOX_SIDE = "levels/castle_grounds/stage_box_side.rgba32"
BOX_SIDE_SIZE = 128
ROM_HEAD = "textures/segment2/segment2.05A00.rgba16.png"  # (texture_hud_char_mario_head)


def box_side_source(work=None):
    """The picture to emboss: yours, else the ROM's Mario head (in the extracted sm64ex checkout, work)"""
    local = LOCAL_ART / "box_side.png"
    if local.exists():
        return local
    if work is not None and (Path(work) / ROM_HEAD).exists():
        return Path(work) / ROM_HEAD
    return None


def _sample(rows, w, h, x, y):
    """Bilinear, of a grid of floats, (x, y) in its pixels' centres' frame, clamped at its edges"""
    x = min(max(x, 0.0), w - 1.0)
    y = min(max(y, 0.0), h - 1.0)
    x0, y0 = int(x), int(y)
    x1, y1 = min(x0 + 1, w - 1), min(y0 + 1, h - 1)
    fx, fy = x - x0, y - y0
    top = rows[y0][x0] * (1 - fx) + rows[y0][x1] * fx
    bottom = rows[y1][x0] * (1 - fx) + rows[y1][x1] * fx
    return top * (1 - fy) + bottom * fy


def _blur(grid, n):
    size = len(grid)
    for _ in range(n):
        grid = [[sum(grid[min(max(y + dy, 0), size - 1)][min(max(x + dx, 0), size - 1)]
                     for dy in (-1, 0, 1) for dx in (-1, 0, 1)) / 9 for x in range(size)] for y in range(size)]
    return grid


def emboss(src, size=BOX_SIDE_SIZE, detail=0.8, light=3.5):
    """Rows of grey (r, g, b, a): src's picture raised in the middle of a flat field, inside a raised rim, lit from the
    top left. Its opaque part stands up, the lighter parts of it higher"""
    w, h, rows = read_png(src)
    heights = [[(p[3] / 255) * (1 - detail + detail * (0.3 * p[0] + 0.59 * p[1] + 0.11 * p[2]) / 255) for p in row]
               for row in rows]
    figure = 0.72  # (of the side, the picture's width)
    scale = max(w, h) / (size * figure)
    grid = []
    for y in range(size):
        line = []
        for x in range(size):
            u = (x - size / 2) * scale + w / 2 - 0.5
            v = (y - size / 2) * scale + h / 2 - 0.5
            line.append(_sample(heights, w, h, u, v) if -0.5 <= u <= w - 0.5 and -0.5 <= v <= h - 0.5 else 0.0)
        grid.append(line)
    grid = _blur(grid, 2)
    rim = size * 0.07
    for y in range(size):
        for x in range(size):
            edge = min(x, y, size - 1 - x, size - 1 - y)
            if edge < rim:
                grid[y][x] = max(grid[y][x], 0.8 * min(1.0, (edge + 1) / 2))  # (a raised rim, bevelled outside)
    out = []
    for y in range(size):
        line = []
        for x in range(size):
            a = grid[max(y - 1, 0)][max(x - 1, 0)]
            b = grid[min(y + 1, size - 1)][min(x + 1, size - 1)]
            shade = 0.78 + light * (a - b) + 0.1 * grid[y][x]
            g = round(255 * min(1.0, max(0.4, shade)))
            line.append((g, g, g, 255))
        out.append(line)
    return out


def box_side(work, out_dir):
    """The embossed side, written into out_dir: its file (None if there's no picture to emboss)"""
    src = box_side_source(work)
    if src is None:
        return None
    path = Path(out_dir) / "stage_box_side.png"
    path.parent.mkdir(parents=True, exist_ok=True)
    write_png(path, emboss(src))
    return path
