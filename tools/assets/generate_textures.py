#!/usr/bin/env python3
"""Generates every texture and UI image of the game.

The project ships its own asset pipeline on purpose:

* the repository stays small and self contained (no third party asset packs),
* every surface has its own look instead of one grey material everywhere,
* the generated files are ordinary PNGs in ``assets/``, so they can be replaced one by one
  by hand painted textures later without touching a single line of GDScript (the game only
  ever refers to the material names in ``scripts/world/material_library.gd``).

Usage:
    python3 tools/assets/generate_textures.py [--out assets] [--seed 20240923]

Requires numpy and Pillow (see tools/assets/requirements.txt).
"""

from __future__ import annotations

import argparse
import math
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

SEED = 20240923


# --------------------------------------------------------------------------------------
# small helpers
# --------------------------------------------------------------------------------------
def rng(seed_offset: int = 0) -> np.random.Generator:
    return np.random.default_rng(SEED + seed_offset)


def value_noise(size: int, cells: int, seed_offset: int, smooth: int = 0) -> np.ndarray:
    """Seamless value noise in the range 0..1 (tiles perfectly thanks to np.roll)."""
    gen = rng(seed_offset)
    grid = gen.random((cells, cells)).astype(np.float32)
    img = Image.fromarray((grid * 255.0).astype(np.uint8), mode="L")
    img = img.resize((size, size), Image.BICUBIC)
    data = np.asarray(img, dtype=np.float32) / 255.0
    for _ in range(smooth):
        data = (
            data
            + np.roll(data, 1, axis=0)
            + np.roll(data, -1, axis=0)
            + np.roll(data, 1, axis=1)
            + np.roll(data, -1, axis=1)
        ) / 5.0
    return data


def fbm(size: int, cells: int, octaves: int, seed_offset: int) -> np.ndarray:
    """Fractal sum of seamless value noise, normalised to 0..1."""
    total = np.zeros((size, size), dtype=np.float32)
    amplitude = 1.0
    weight = 0.0
    current_cells = cells
    for octave in range(octaves):
        total += value_noise(size, current_cells, seed_offset + octave * 17) * amplitude
        weight += amplitude
        amplitude *= 0.5
        current_cells = min(current_cells * 2, size)
    return total / max(weight, 0.0001)


def colourise(height: np.ndarray, low: tuple[int, int, int], high: tuple[int, int, int]) -> np.ndarray:
    """Maps a 0..1 height field onto a two colour gradient. Returns HxWx3 float array."""
    low_arr = np.array(low, dtype=np.float32)
    high_arr = np.array(high, dtype=np.float32)
    t = np.clip(height, 0.0, 1.0)[:, :, None]
    return low_arr[None, None, :] * (1.0 - t) + high_arr[None, None, :] * t


def normal_from_height(height: np.ndarray, strength: float = 2.0) -> Image.Image:
    """Turns a height field into a tangent space normal map."""
    dx = (np.roll(height, -1, axis=1) - np.roll(height, 1, axis=1)) * strength
    dy = (np.roll(height, -1, axis=0) - np.roll(height, 1, axis=0)) * strength
    nz = np.ones_like(height)
    length = np.sqrt(dx * dx + dy * dy + nz * nz)
    normal = np.stack([-dx / length, -dy / length, nz / length], axis=2)
    return Image.fromarray(((normal * 0.5 + 0.5) * 255.0).astype(np.uint8), mode="RGB")


def to_image(rgb: np.ndarray) -> Image.Image:
    return Image.fromarray(np.clip(rgb, 0, 255).astype(np.uint8), mode="RGB")


def add_grain(rgb: np.ndarray, amount: float, seed_offset: int) -> np.ndarray:
    noise = rng(seed_offset).normal(0.0, amount, rgb.shape[:2])[:, :, None]
    return rgb + noise


def save(image: Image.Image, path: Path, normal: Image.Image | None = None) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.suffix.lower() == ".jpg":
        image.convert("RGB").save(path, quality=88, subsampling=1)
    else:
        image.save(path, optimize=True)
    print(f"  wrote {path} ({path.stat().st_size // 1024} KiB)")
    if normal is not None:
        normal_path = path.with_name(path.stem + "_normal.png")
        normal.save(normal_path, optimize=True)
        print(f"  wrote {normal_path} ({normal_path.stat().st_size // 1024} KiB)")


# --------------------------------------------------------------------------------------
# ground surfaces
# --------------------------------------------------------------------------------------
def tex_asphalt(size: int = 512, worn: bool = False) -> tuple[Image.Image, Image.Image]:
    height = fbm(size, 96, 4, 1)
    coarse = fbm(size, 12, 3, 2)
    base = height * 0.35 + coarse * 0.65
    rgb = colourise(base, (44, 45, 49), (96, 98, 104))
    if worn:
        patches = (fbm(size, 5, 3, 3) > 0.62).astype(np.float32)
        patches = np.asarray(
            Image.fromarray((patches * 255).astype(np.uint8), "L").filter(ImageFilter.GaussianBlur(6)),
            dtype=np.float32,
        ) / 255.0
        rgb = rgb * (1.0 - patches[:, :, None] * 0.35) + np.array([104, 100, 94])[None, None, :] * (
            patches[:, :, None] * 0.35
        )
    # cracks: a handful of thin dark polylines
    crack_img = Image.new("L", (size, size), 0)
    draw = ImageDraw.Draw(crack_img)
    gen = rng(7)
    for _ in range(26):
        x = float(gen.integers(0, size))
        y = float(gen.integers(0, size))
        points = [(x, y)]
        for _step in range(gen.integers(3, 9)):
            x = (x + float(gen.normal(0, 22))) % size
            y = (y + float(gen.normal(0, 22))) % size
            points.append((x, y))
        draw.line(points, fill=int(gen.integers(90, 190)), width=1)
    crack = np.asarray(crack_img, dtype=np.float32) / 255.0
    rgb = rgb * (1.0 - crack[:, :, None] * 0.45)
    rgb = add_grain(rgb, 4.0, 11)
    height_map = np.clip(base * 0.7 + crack * 0.3, 0.0, 1.0)
    return to_image(rgb), normal_from_height(height_map, 1.6)


def tex_concrete(size: int = 512, joints: int = 2) -> tuple[Image.Image, Image.Image]:
    height = fbm(size, 64, 4, 21) * 0.5 + fbm(size, 8, 3, 22) * 0.5
    rgb = colourise(height, (128, 126, 120), (186, 184, 178))
    # expansion joints
    joint_img = Image.new("L", (size, size), 0)
    draw = ImageDraw.Draw(joint_img)
    step = size // max(joints, 1)
    for i in range(0, size + 1, step):
        draw.line([(i, 0), (i, size)], fill=255, width=3)
        draw.line([(0, i), (size, i)], fill=255, width=3)
    joint = np.asarray(joint_img.filter(ImageFilter.GaussianBlur(1.2)), dtype=np.float32) / 255.0
    rgb = rgb * (1.0 - joint[:, :, None] * 0.55)
    # stains
    stains = fbm(size, 6, 4, 25)
    stains = np.clip((stains - 0.55) * 2.2, 0.0, 1.0)
    rgb = rgb * (1.0 - stains[:, :, None] * 0.22) + np.array([120, 118, 108])[None, None, :] * (
        stains[:, :, None] * 0.22
    )
    rgb = add_grain(rgb, 5.0, 26)
    return to_image(rgb), normal_from_height(np.clip(height * 0.6 + joint * 0.6, 0, 1), 1.2)


def tex_sidewalk(size: int = 512, tiles: int = 8) -> tuple[Image.Image, Image.Image]:
    height = fbm(size, 128, 3, 31)
    rgb = colourise(height, (150, 148, 142), (196, 193, 186))
    tile_img = Image.new("L", (size, size), 0)
    draw = ImageDraw.Draw(tile_img)
    step = size // tiles
    for i in range(0, size + 1, step):
        draw.line([(i, 0), (i, size)], fill=255, width=2)
        draw.line([(0, i), (size, i)], fill=255, width=2)
    lines = np.asarray(tile_img.filter(ImageFilter.GaussianBlur(1.0)), dtype=np.float32) / 255.0
    rgb = rgb * (1.0 - lines[:, :, None] * 0.45)
    # per tile tint variation so a long pavement is not uniform
    tint = np.zeros((size, size), dtype=np.float32)
    gen = rng(33)
    for ty in range(tiles):
        for tx in range(tiles):
            value = float(gen.normal(0.0, 0.06))
            tint[ty * step : (ty + 1) * step, tx * step : (tx + 1) * step] = value
    rgb = rgb * (1.0 + tint[:, :, None])
    rgb = add_grain(rgb, 4.0, 34)
    return to_image(rgb), normal_from_height(np.clip(height * 0.5 + lines * 0.7, 0, 1), 1.4)


def tex_grass(size: int = 512) -> tuple[Image.Image, Image.Image]:
    height = fbm(size, 48, 5, 41)
    clumps = fbm(size, 8, 3, 42)
    rgb = colourise(height * 0.6 + clumps * 0.4, (48, 78, 38), (128, 158, 84))
    blades = fbm(size, 256, 2, 43)
    rgb = rgb * (0.92 + blades[:, :, None] * 0.16)
    rgb = add_grain(rgb, 7.0, 44)
    return to_image(rgb), normal_from_height(np.clip(height * 0.8 + blades * 0.2, 0, 1), 2.2)


def tex_dirt(size: int = 512) -> tuple[Image.Image, Image.Image]:
    height = fbm(size, 40, 5, 51)
    rgb = colourise(height, (86, 68, 48), (146, 124, 92))
    pebbles = np.asarray(
        Image.fromarray(((fbm(size, 180, 2, 52) > 0.72) * 255).astype(np.uint8), "L").filter(ImageFilter.GaussianBlur(0.6)),
        dtype=np.float32,
    ) / 255.0
    rgb = rgb * (1.0 + pebbles[:, :, None] * 0.35)
    rgb = add_grain(rgb, 6.0, 53)
    return to_image(rgb), normal_from_height(np.clip(height * 0.8 + pebbles * 0.3, 0, 1), 2.0)


def tex_kerb(size: int = 256) -> tuple[Image.Image, Image.Image]:
    height = fbm(size, 64, 3, 61)
    rgb = colourise(height, (168, 164, 156), (214, 210, 202))
    stripes = np.zeros((size, size), dtype=np.float32)
    stripes[:, ::64] = 1.0
    rgb = rgb * (1.0 - stripes[:, :, None] * 0.3)
    rgb = add_grain(rgb, 4.0, 62)
    return to_image(rgb), normal_from_height(np.clip(height * 0.7 + stripes * 0.4, 0, 1), 1.2)


# --------------------------------------------------------------------------------------
# building facades
# --------------------------------------------------------------------------------------
def _window_grid(
    size: int,
    cols: int,
    rows: int,
    wall_low: tuple[int, int, int],
    wall_high: tuple[int, int, int],
    glass_low: tuple[int, int, int],
    glass_high: tuple[int, int, int],
    frame: tuple[int, int, int],
    seed_offset: int,
    lit_chance: float = 0.0,
    sill: bool = True,
) -> tuple[Image.Image, Image.Image]:
    wall = fbm(size, 64, 4, seed_offset)
    rgb = colourise(wall, wall_low, wall_high)
    height = wall * 0.4
    glass = np.zeros((size, size, 3), dtype=np.float32)
    mask = np.zeros((size, size), dtype=np.float32)
    frame_mask = np.zeros((size, size), dtype=np.float32)
    cell_w = size / cols
    cell_h = size / rows
    win_w = cell_w * 0.62
    win_h = cell_h * 0.56
    gen = rng(seed_offset + 5)
    for row in range(rows):
        for col in range(cols):
            x0 = int(col * cell_w + (cell_w - win_w) / 2)
            y0 = int(row * cell_h + (cell_h - win_h) / 2)
            x1 = int(x0 + win_w)
            y1 = int(y0 + win_h)
            shade = float(gen.random())
            tile = np.array(glass_low, dtype=np.float32) * (1.0 - shade) + np.array(glass_high, dtype=np.float32) * shade
            if float(gen.random()) < lit_chance:
                tile = np.array([250.0, 226.0, 168.0])
            glass[y0:y1, x0:x1] = tile
            mask[y0:y1, x0:x1] = 1.0
            fx0 = max(x0 - 3, 0)
            fy0 = max(y0 - 3, 0)
            frame_mask[fy0:y0, x0:x1] = 1.0
            frame_mask[y1 : y1 + 3, x0:x1] = 1.0
            frame_mask[y0:y1, fx0:x0] = 1.0
            frame_mask[y0:y1, x1 : x1 + 3] = 1.0
            if sill:
                frame_mask[y1 + 3 : y1 + 6, fx0 : min(x1 + 3, size)] = 1.0
    rgb = rgb * (1.0 - mask[:, :, None]) + glass * mask[:, :, None]
    rgb = rgb * (1.0 - frame_mask[:, :, None] * 0.85) + np.array(frame, dtype=np.float32)[None, None, :] * (
        frame_mask[:, :, None] * 0.85
    )
    # a subtle reflection gradient across the glass
    gradient = np.linspace(0.72, 1.08, size, dtype=np.float32)[None, :, None]
    rgb = rgb * (1.0 + (gradient - 1.0) * mask[:, :, None])
    rgb = add_grain(rgb, 3.5, seed_offset + 9)
    height_map = np.clip(height + frame_mask * 0.6 + mask * 0.15, 0.0, 1.0)
    return to_image(rgb), normal_from_height(height_map, 1.5)


def tex_facade_office(size: int = 512) -> tuple[Image.Image, Image.Image]:
    return _window_grid(
        size, 4, 6, (118, 116, 112), (162, 160, 154), (36, 52, 66), (78, 108, 132), (196, 194, 188), 71, 0.06
    )


def tex_facade_glass(size: int = 512) -> tuple[Image.Image, Image.Image]:
    return _window_grid(
        size, 6, 8, (58, 62, 70), (92, 98, 108), (30, 46, 62), (96, 132, 158), (120, 124, 132), 76, 0.03, sill=False
    )


def tex_facade_panel(size: int = 512) -> tuple[Image.Image, Image.Image]:
    wall = fbm(size, 24, 4, 81)
    rgb = colourise(wall, (170, 166, 156), (208, 204, 194))
    panels = Image.new("L", (size, size), 0)
    draw = ImageDraw.Draw(panels)
    step = size // 4
    for i in range(0, size + 1, step):
        draw.line([(i, 0), (i, size)], fill=255, width=3)
        draw.line([(0, i), (size, i)], fill=255, width=3)
    lines = np.asarray(panels.filter(ImageFilter.GaussianBlur(1.0)), dtype=np.float32) / 255.0
    rgb = rgb * (1.0 - lines[:, :, None] * 0.4)
    mask = np.zeros((size, size), dtype=np.float32)
    gen = rng(83)
    for row in range(4):
        for col in range(4):
            x0 = col * step + step // 5
            y0 = row * step + step // 6
            w = int(step * 0.32)
            h = int(step * 0.34)
            shade = float(gen.random())
            tile = np.array([40, 56, 68], dtype=np.float32) * (1 - shade) + np.array([86, 116, 140], dtype=np.float32) * shade
            rgb[y0 : y0 + h, x0 : x0 + w] = tile
            mask[y0 : y0 + h, x0 : x0 + w] = 1.0
    rgb = add_grain(rgb, 4.0, 84)
    return to_image(rgb), normal_from_height(np.clip(wall * 0.6 + lines * 0.5 + mask * 0.2, 0, 1), 1.3)


def tex_brick(size: int = 512) -> tuple[Image.Image, Image.Image]:
    brick_w, brick_h = 64, 26
    rows = size // brick_h
    rgb = np.zeros((size, size, 3), dtype=np.float32)
    mortar = np.array([168, 162, 152], dtype=np.float32)
    rgb[:, :] = mortar
    height = np.zeros((size, size), dtype=np.float32)
    gen = rng(91)
    for row in range(rows):
        offset = (brick_w // 2) if row % 2 else 0
        for col in range(-1, size // brick_w + 1):
            x0 = col * brick_w + offset
            y0 = row * brick_h
            shade = float(gen.random())
            brick = np.array([118, 62, 46], dtype=np.float32) * (1 - shade) + np.array([178, 104, 78], dtype=np.float32) * shade
            xs = max(x0, 0)
            xe = min(x0 + brick_w - 3, size)
            ys = max(y0, 0)
            ye = min(y0 + brick_h - 4, size)
            if xe <= xs or ye <= ys:
                continue
            rgb[ys:ye, xs:xe] = brick
            height[ys:ye, xs:xe] = 0.7
    noise = fbm(size, 128, 3, 92)
    rgb = rgb * (0.94 + noise[:, :, None] * 0.12)
    rgb = add_grain(rgb, 5.0, 93)
    return to_image(rgb), normal_from_height(np.clip(height + noise * 0.2, 0, 1), 2.4)


def tex_facade_brick(size: int = 512) -> tuple[Image.Image, Image.Image]:
    base, normal = tex_brick(size)
    brick_rgb = np.asarray(base, dtype=np.float32)
    cols, rows = 4, 6
    cell_w = size / cols
    cell_h = size / rows
    mask = np.zeros((size, size), dtype=np.float32)
    gen = rng(96)
    for row in range(rows):
        for col in range(cols):
            x0 = int(col * cell_w + cell_w * 0.22)
            y0 = int(row * cell_h + cell_h * 0.22)
            w = int(cell_w * 0.56)
            h = int(cell_h * 0.5)
            shade = float(gen.random())
            tile = np.array([38, 50, 60], dtype=np.float32) * (1 - shade) + np.array([80, 106, 124], dtype=np.float32) * shade
            brick_rgb[y0 : y0 + h, x0 : x0 + w] = tile
            mask[y0 : y0 + h, x0 : x0 + w] = 1.0
    brick_rgb = add_grain(brick_rgb, 3.5, 97)
    return to_image(brick_rgb), normal


def tex_roof(size: int = 512) -> tuple[Image.Image, Image.Image]:
    height = fbm(size, 160, 4, 101)
    rgb = colourise(height, (58, 56, 54), (108, 104, 100))
    gen = rng(102)
    stains = fbm(size, 6, 3, 103)
    stains = np.clip((stains - 0.5) * 1.8, 0, 1)
    rgb = rgb * (1.0 - stains[:, :, None] * 0.3) + np.array([86, 78, 64])[None, None, :] * (stains[:, :, None] * 0.3)
    rgb = add_grain(rgb, 6.0, 104)
    return to_image(rgb), normal_from_height(height, 2.6)


def tex_metal_panel(size: int = 512) -> tuple[Image.Image, Image.Image]:
    height = fbm(size, 128, 3, 111) * 0.3
    corrugation = (np.sin(np.arange(size) / size * math.pi * 2 * 48)[None, :] * 0.5 + 0.5).astype(np.float32)
    height = np.clip(height + corrugation * 0.7, 0, 1)
    rgb = colourise(height, (86, 96, 108), (168, 178, 190))
    gen = rng(112)
    rust = fbm(size, 10, 4, 113)
    rust_mask = np.clip((rust - 0.62) * 2.6, 0, 1)
    rust_rgb = colourise(rust, (96, 52, 30), (168, 96, 52))
    rgb = rgb * (1 - rust_mask[:, :, None]) + rust_rgb * rust_mask[:, :, None]
    rgb = add_grain(rgb, 4.0, 114)
    return to_image(rgb), normal_from_height(height, 3.0)


def tex_wood(size: int = 256) -> tuple[Image.Image, Image.Image]:
    height = fbm(size, 200, 3, 121)
    grain = (np.sin(np.arange(size)[:, None] / size * math.pi * 2 * 12 + height * 4.0) * 0.5 + 0.5).astype(np.float32)
    rgb = colourise(grain * 0.7 + height * 0.3, (108, 74, 44), (186, 148, 96))
    planks = np.zeros((size, size), dtype=np.float32)
    planks[:: size // 4, :] = 1.0
    rgb = rgb * (1 - planks[:, :, None] * 0.5)
    rgb = add_grain(rgb, 5.0, 122)
    return to_image(rgb), normal_from_height(np.clip(height * 0.6 + planks * 0.5, 0, 1), 1.8)


def tex_shopfront(size: int = 512) -> tuple[Image.Image, Image.Image]:
    rgb = np.zeros((size, size, 3), dtype=np.float32)
    rgb[:, :] = np.array([46, 44, 46], dtype=np.float32)
    height = np.zeros((size, size), dtype=np.float32)
    panes = 5
    pane_w = size // panes
    for i in range(panes):
        x0 = i * pane_w + 6
        x1 = (i + 1) * pane_w - 6
        rgb[40 : size - 40, x0:x1] = np.array([196, 176, 132], dtype=np.float32)
        rgb[40 : size - 40, x0:x1] *= np.linspace(0.85, 1.1, x1 - x0)[None, :, None]
        height[40 : size - 40, x0:x1] = 0.5
    rgb[0:40, :] = np.array([132, 36, 36], dtype=np.float32)
    rgb[size - 40 :, :] = np.array([58, 58, 62], dtype=np.float32)
    noise = fbm(size, 64, 3, 131)
    rgb = rgb * (0.95 + noise[:, :, None] * 0.1)
    rgb = add_grain(rgb, 4.0, 132)
    return to_image(rgb), normal_from_height(np.clip(height + noise * 0.2, 0, 1), 1.0)


def tex_shop_sign(size: int = 256, text: str = "24") -> tuple[Image.Image, Image.Image]:
    rgb = np.zeros((size, size, 3), dtype=np.float32)
    rgb[:, :] = np.array([176, 32, 40], dtype=np.float32)
    img = to_image(rgb)
    draw = ImageDraw.Draw(img)
    font = _load_font(size // 2)
    bbox = draw.textbbox((0, 0), text, font=font)
    draw.text(
        ((size - (bbox[2] - bbox[0])) / 2 - bbox[0], (size - (bbox[3] - bbox[1])) / 2 - bbox[1]),
        text,
        fill=(246, 240, 226),
        font=font,
    )
    draw.rectangle([4, 4, size - 5, size - 5], outline=(246, 240, 226), width=6)
    arr = np.asarray(img, dtype=np.float32)
    height = np.asarray(Image.fromarray(np.asarray(img.convert("L"))), dtype=np.float32) / 255.0
    return to_image(arr), normal_from_height(height, 0.6)


def _load_font(size: int):
    candidates = [
        "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/TTF/DejaVuSans-Bold.ttf",
    ]
    for candidate in candidates:
        if Path(candidate).exists():
            return ImageFont.truetype(candidate, size)
    return ImageFont.load_default()


# --------------------------------------------------------------------------------------
# UI images
# --------------------------------------------------------------------------------------
def ui_map(block_count: int = 8, block_pitch: int = 125, world: int = 1000, px: int = 1024) -> Image.Image:
    """Top down schematic map of the generated district, drawn with the same rules and the
    same deterministic hash the world generator uses, so the thumbnail matches the city."""
    image = Image.new("RGB", (px, px), (34, 36, 40))
    draw = ImageDraw.Draw(image)
    scale = px / float(world)
    road = int(round(13 * scale))
    half = world * 0.5
    # ground: concrete slab with grass patches
    for bx in range(block_count):
        for bz in range(block_count):
            kind = block_kind(bx, bz)
            x0 = (bx * block_pitch - half) * scale + px * 0.5
            z0 = (bz * block_pitch - half) * scale + px * 0.5
            x1 = x0 + block_pitch * scale
            z1 = z0 + block_pitch * scale
            inner = [x0 + road, z0 + road, x1 - road, z1 - road]
            if kind == "park":
                draw.rectangle(inner, fill=(58, 92, 54))
            elif kind == "yard":
                draw.rectangle(inner, fill=(78, 76, 70))
            else:
                draw.rectangle(inner, fill=(96, 94, 90))
            # roads around the block
            draw.rectangle([x0, z0, x1, z0 + road], fill=(60, 62, 66))
            draw.rectangle([x0, z0, x0 + road, z1], fill=(60, 62, 66))
            draw.rectangle([x0, z1 - road, x1, z1], fill=(60, 62, 66))
            draw.rectangle([x1 - road, z0, x1, z1], fill=(60, 62, 66))
            draw.line([x0 + road * 0.5, z0, x0 + road * 0.5, z1], fill=(120, 120, 118), width=2)
            if kind == "buildings":
                gen = rng(1000 + bx * 31 + bz * 17)
                for _ in range(4):
                    w = int(gen.integers(int(block_pitch * 0.18), int(block_pitch * 0.34)) * scale)
                    h = int(gen.integers(int(block_pitch * 0.18), int(block_pitch * 0.34)) * scale)
                    cx = int(inner[0] + gen.integers(0, max(1, inner[2] - inner[0] - w)))
                    cy = int(inner[1] + gen.integers(0, max(1, inner[3] - inner[1] - h)))
                    draw.rectangle([cx, cy, cx + w, cy + h], fill=(150, 148, 144), outline=(70, 70, 72))
    # spawn plaza marker
    centre = px // 2
    draw.ellipse([centre - 12, centre - 12, centre + 12, centre + 12], fill=(232, 72, 48))
    draw.ellipse([centre - 5, centre - 5, centre + 5, centre + 5], fill=(250, 236, 214))
    # frame
    draw.rectangle([0, 0, px - 1, px - 1], outline=(200, 200, 204), width=6)
    return image


def block_kind(bx: int, bz: int) -> str:
    """Deterministic block classification. The same hash exists in GDScript
    (scripts/world/district_layout.gd) so the map thumbnail matches the real city."""
    h = (bx * 73856093) ^ (bz * 19349663) ^ (SEED & 0xFFFF)
    h &= 0xFFFFFFFF
    h = (h ^ (h >> 13)) * 1274126177 & 0xFFFFFFFF
    h = h ^ (h >> 16)
    value = (h % 1000) / 1000.0
    if value < 0.12:
        return "park"
    if value < 0.22:
        return "yard"
    return "buildings"


def ui_logo(width: int = 1024, height: int = 256) -> Image.Image:
    image = Image.new("RGB", (width, height), (16, 18, 24))
    draw = ImageDraw.Draw(image)
    font_big = _load_font(96)
    font_small = _load_font(38)
    draw.text((32, 30), "УГОН", font=font_big, fill=(232, 68, 47))
    draw.text((300, 30), "ОТ МУСОРОВ", font=font_big, fill=(238, 236, 230))
    draw.text((34, 150), "ПОЛИЦЕЙСКАЯ ПОГОНЯ  •  ОТКРЫТЫЙ ГОРОД", font=font_small, fill=(150, 176, 200))
    draw.line([(32, 140), (width - 32, 140)], fill=(232, 68, 47), width=4)
    return image


# --------------------------------------------------------------------------------------
def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", default="assets")
    parser.add_argument("--seed", type=int, default=20240923)
    args = parser.parse_args()
    global SEED
    SEED = args.seed

    out = Path(args.out)
    tex = out / "textures"
    ui = out / "ui"
    print(f"generating textures into {tex} (seed {SEED})")

    surfaces = {
        "asphalt.png": tex_asphalt(),
        "asphalt_worn.png": tex_asphalt(worn=True),
        "concrete.png": tex_concrete(),
        "concrete_plaza.png": tex_concrete(size=1024, joints=2),
        "sidewalk.png": tex_sidewalk(),
        "grass.png": tex_grass(),
        "dirt.png": tex_dirt(),
        "kerb.png": tex_kerb(),
        "roof_gravel.png": tex_roof(),
        "metal_panel.png": tex_metal_panel(),
        "wood_planks.png": tex_wood(),
        "brick.png": tex_brick(),
    }
    facades = {
        "facade_office.png": tex_facade_office(),
        "facade_glass.png": tex_facade_glass(),
        "facade_panel.png": tex_facade_panel(),
        "facade_brick.png": tex_facade_brick(),
        "facade_shop.png": tex_shopfront(),
        "sign_shop.png": tex_shop_sign(256, "24"),
        "sign_cafe.png": tex_shop_sign(256, "CAFE"),
    }
    for name, (colour, normal) in {**surfaces, **facades}.items():
        save(colour, tex / name, normal)

    print("generating UI images")
    save(ui_logo(), ui / "logo.png")
    save(ui_map(px=1024), ui / "map_test_district.png")

    # small tileable variants used by the LOD/低 quality path
    small = ui_map(px=256).resize((256, 256), Image.LANCZOS)
    save(small, ui / "map_test_district_small.png")
    print("done")


if __name__ == "__main__":
    main()
