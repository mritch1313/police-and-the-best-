#!/usr/bin/env python3
"""Generates the main menu background of СИМУЛЯТОР УГОНА ОТ МУСОРОВ.

The design calls for a photograph-like city background ("фон.jpg"). No such file ships with
the repository, so this script generates a stand-in that fits the game: a dusk skyline with
hundreds of lit windows, haze between the layers and a wet road in the foreground.

Dropping the artist's own `фон.jpg` into `assets/menu/` replaces it without touching code
(the menu loads `res://assets/menu/fon.jpg` first).

Usage:
    python3 tools/assets/generate_menu_background.py --out assets [--width 1080 --height 1920]
"""

from __future__ import annotations

import argparse
import math
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

SEED = 20240923

# Palette: a warm dusk that reads well on a phone screen and keeps the menu text legible.
SKY_TOP = np.array([16, 24, 48], dtype=np.float32)
SKY_MID = np.array([54, 62, 96], dtype=np.float32)
SKY_LOW = np.array([168, 108, 96], dtype=np.float32)
SKY_HORIZON = np.array([236, 168, 112], dtype=np.float32)

LAYERS = [
    # (height fraction of image, colour, window colour, lit chance, haze blur, base y)
    (0.30, (86, 94, 122), (255, 214, 150), 0.20, 3.2, 0.63),
    (0.36, (62, 70, 96), (255, 206, 138), 0.26, 2.2, 0.67),
    (0.42, (42, 48, 68), (255, 198, 128), 0.30, 1.4, 0.72),
    (0.50, (24, 28, 42), (255, 190, 120), 0.34, 0.6, 0.78),
]


def sky_gradient(width: int, height: int) -> np.ndarray:
    """Vertical dusk gradient with a sun glow around the horizon."""
    y = np.linspace(0.0, 1.0, height, dtype=np.float32)[:, None]
    horizon = 0.78
    t = np.clip(y / horizon, 0.0, 1.0)
    sky = np.zeros((height, width, 3), dtype=np.float32)
    for channel in range(3):
        lower = np.where(
            t < 0.55,
            SKY_TOP[channel] + (SKY_MID[channel] - SKY_TOP[channel]) * (t / 0.55),
            SKY_MID[channel] + (SKY_LOW[channel] - SKY_MID[channel]) * ((t - 0.55) / 0.45),
        )
        near_horizon = SKY_LOW[channel] + (SKY_HORIZON[channel] - SKY_LOW[channel]) * np.clip(
            (t - 0.75) / 0.25, 0.0, 1.0
        )
        sky[:, :, channel] = np.where(t < 0.75, lower, near_horizon)[:, 0][:, None]
    # Sun glow: a soft radial falloff just above the horizon.
    xs = np.linspace(0.0, 1.0, width, dtype=np.float32)[None, :]
    sun_x, sun_y = 0.68, 0.74
    glow = np.exp(-(((xs - sun_x) ** 2) / 0.020 + ((y - sun_y) ** 2) / 0.010)).astype(np.float32)
    sun = np.exp(-(((xs - sun_x) ** 2) / 0.0012 + ((y - sun_y) ** 2) / 0.0006)).astype(np.float32)
    sky += glow[:, :, None] * np.array([90.0, 58.0, 26.0], dtype=np.float32)
    sky += sun[:, :, None] * np.array([120.0, 96.0, 48.0], dtype=np.float32)
    return np.clip(sky, 0, 255)


def skyline_layer(
    width: int,
    height: int,
    rng: np.random.Generator,
    colour: tuple[int, int, int],
    window_colour: tuple[int, int, int],
    lit_chance: float,
    base_y: float,
    max_height: float,
) -> Image.Image:
    """One silhouette layer with lit windows."""
    layer = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    base_px = int(height * base_y)
    x = -int(width * 0.06)
    while x < width:
        building_width = int(rng.integers(int(width * 0.035), int(width * 0.13)))
        building_height = int(height * max_height * rng.uniform(0.35, 1.0))
        top = base_px - building_height
        tint = np.array(colour, dtype=np.float32) * rng.uniform(0.85, 1.15)
        tint = np.clip(tint, 0, 255).astype(int)
        draw.rectangle([x, top, x + building_width, base_px], fill=(int(tint[0]), int(tint[1]), int(tint[2]), 255))
        # Roof structures.
        if rng.random() < 0.35:
            roof_w = int(building_width * rng.uniform(0.2, 0.5))
            roof_h = int(building_height * rng.uniform(0.03, 0.12))
            draw.rectangle(
                [x + int(building_width * 0.2), top - roof_h, x + int(building_width * 0.2) + roof_w, top],
                fill=(int(tint[0]), int(tint[1]), int(tint[2]), 255),
            )
        if rng.random() < 0.18:
            mast_x = x + building_width // 2
            mast_h = int(building_height * rng.uniform(0.08, 0.2))
            draw.line([mast_x, top - mast_h, mast_x, top], fill=(int(tint[0]), int(tint[1]), int(tint[2]), 255), width=2)
        # Windows: a grid that is slightly irregular, like a real façade at night.
        win_w = max(3, int(building_width / 9))
        win_h = max(4, int(win_w * 1.5))
        gap_x = max(2, win_w // 2)
        gap_y = max(3, win_h // 2)
        y = top + gap_y
        while y + win_h < base_px - gap_y:
            wx = x + gap_x
            while wx + win_w < x + building_width - gap_x:
                if rng.random() < lit_chance:
                    strength = rng.uniform(0.55, 1.0)
                    wc = np.array(window_colour, dtype=np.float32) * strength
                    draw.rectangle(
                        [wx, y, wx + win_w, y + win_h],
                        fill=(int(wc[0]), int(wc[1]), int(wc[2]), 255),
                    )
                wx += win_w + gap_x
            y += win_h + gap_y
        x += building_width + int(rng.integers(int(width * 0.004), int(width * 0.02) + 1))
    return layer


def add_street_level(image: Image.Image, rng: np.random.Generator) -> Image.Image:
    """The solid street level under the skyline.

    Without this the warm sky gradient shows through the gaps between the buildings and the
    bottom of the city looks like a bright band instead of a street. A dark base band with lit
    shop windows fixes it and gives the foreground something to sit on.
    """
    width, height = image.size
    top = int(height * 0.726)
    bottom = int(height * 0.805)
    layer = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    draw.rectangle([0, top, width, bottom], fill=(17, 19, 27, 255))
    # A thin warm strip where the shop lights bleed onto the pavement.
    draw.rectangle([0, top, width, top + max(2, height // 320)], fill=(96, 74, 52, 220))
    # Shop windows: wide, warm and irregular, the way a lit ground floor looks from a car.
    x = 0
    while x < width:
        if rng.random() < 0.62:
            shop_width = int(rng.integers(int(width * 0.03), int(width * 0.10)))
            shop_height = int((bottom - top) * rng.uniform(0.35, 0.7))
            warmth = rng.uniform(0.5, 1.0)
            colour = (
                int(255 * warmth),
                int(206 * warmth),
                int(150 * warmth),
                255,
            )
            draw.rectangle(
                [x, bottom - shop_height, x + shop_width, bottom - int((bottom - top) * 0.12)],
                fill=colour,
            )
            x += shop_width + int(rng.integers(6, 40))
        else:
            x += int(rng.integers(20, 90))
    # Darken the very bottom of the band so it meets the asphalt smoothly.
    gradient = np.asarray(layer).astype(np.float32)
    band = gradient[top:bottom, :, :]
    fade = np.linspace(1.0, 0.55, band.shape[0], dtype=np.float32)[:, None, None]
    band[:, :, 3] *= fade[:, :, 0]
    gradient[top:bottom, :, :] = band
    layer = Image.fromarray(np.clip(gradient, 0, 255).astype(np.uint8))
    return Image.alpha_composite(image, layer.filter(ImageFilter.GaussianBlur(1.1)))


def add_stars(image: np.ndarray, rng: np.random.Generator) -> np.ndarray:
    """A few faint stars in the upper sky: enough to give the gradient some texture."""
    height, width = image.shape[0], image.shape[1]
    result = image.copy()
    for _ in range(180):
        x = int(rng.integers(0, width))
        y = int(rng.integers(0, int(height * 0.45)))
        brightness = rng.uniform(30.0, 110.0)
        radius = 1 if rng.random() < 0.85 else 2
        patch = Image.new("L", (radius * 6, radius * 6), 0)
        draw = ImageDraw.Draw(patch)
        draw.ellipse(
            [radius * 2, radius * 2, radius * 4, radius * 4], fill=int(brightness)
        )
        patch = patch.filter(ImageFilter.GaussianBlur(radius))
        layer = np.zeros((height, width), dtype=np.float32)
        y0 = max(0, y - radius * 3)
        x0 = max(0, x - radius * 3)
        patch_array = np.asarray(patch).astype(np.float32) / 255.0
        y1 = min(height, y0 + patch_array.shape[0])
        x1 = min(width, x0 + patch_array.shape[1])
        layer[y0:y1, x0:x1] = patch_array[: y1 - y0, : x1 - x0] * brightness
        result += layer[:, :, None]
    return np.clip(result, 0, 255)


def add_road(image: np.ndarray, rng: np.random.Generator) -> np.ndarray:
    """A wet road in the foreground: asphalt, reflected window light and lane markings.

    The reflection is made from the real skyline instead of random streaks: the strip of the
    image just above the horizon is flipped, dimmed and blurred onto the asphalt, which is what
    a wet street actually does to a city's lights.
    """
    height, width = image.shape[0], image.shape[1]
    road_top = int(height * 0.80)
    road_height = height - road_top
    result = image.copy()

    # 1. Asphalt: a warm haze at the horizon fading into near black at the bottom.
    ramp = np.linspace(0.0, 1.0, road_height, dtype=np.float32)[:, None, None]
    asphalt = np.array([58.0, 54.0, 52.0], dtype=np.float32) * (1.0 - ramp) + np.array(
        [12.0, 12.0, 14.0], dtype=np.float32
    ) * ramp
    result[road_top:, :, :] = result[road_top:, :, :] * 0.25 + asphalt

    # 2. Reflection of the skyline.
    strip_top = max(0, road_top - road_height)
    strip = image[strip_top:road_top, :, :][::-1, :, :]
    strip_image = Image.fromarray(np.clip(strip, 0, 255).astype(np.uint8)).filter(
        ImageFilter.GaussianBlur(max(2.0, road_height * 0.012))
    )
    reflection = np.asarray(strip_image).astype(np.float32)
    fade = np.linspace(0.42, 0.02, road_height, dtype=np.float32)[:, None, None]
    result[road_top:, :, :] = result[road_top:, :, :] + reflection * fade

    # 3. Lane markings in perspective, drawn as quads so they converge correctly.
    overlay = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)
    centre = width * 0.5
    for lane_offset in (-0.16, 0.16):
        for index in range(8):
            t0 = index / 8.0
            t1 = t0 + 0.055
            y0 = int(road_top + road_height * t0**1.7)
            y1 = int(road_top + road_height * t1**1.7)
            x0 = centre + width * lane_offset * (0.22 + t0 * 1.05)
            x1 = centre + width * lane_offset * (0.22 + t1 * 1.05)
            w0 = max(1.5, width * 0.0012 * (1.0 + t0 * 7.0))
            w1 = max(2.0, width * 0.0012 * (1.0 + t1 * 7.0))
            alpha = int(120 + 90 * t0)
            draw.polygon(
                [(x0 - w0, y0), (x0 + w0, y0), (x1 + w1, y1), (x1 - w1, y1)],
                fill=(228, 220, 198, alpha),
            )
    # Kerb lines and a faint sidewalk edge keep the road readable.
    draw.polygon(
        [
            (centre - width * 0.52, int(road_top + road_height * 0.04)),
            (centre + width * 0.52, int(road_top + road_height * 0.04)),
            (width, height),
            (0, height),
        ],
        outline=(190, 180, 160, 40),
    )
    result = np.asarray(
        Image.alpha_composite(
            Image.fromarray(np.clip(result, 0, 255).astype(np.uint8)).convert("RGBA"), overlay
        )
    ).astype(np.float32)[:, :, :3]

    # 4. Wet patches: soft, wide glows of warm light, never hard shapes.
    for _ in range(14):
        cx = float(rng.uniform(0.0, float(width)))
        cy = float(rng.uniform(road_top, float(height)))
        radius = float(rng.uniform(width * 0.05, width * 0.22))
        warm = rng.random() < 0.6
        colour = np.array([255.0, 205.0, 150.0]) if warm else np.array([170.0, 200.0, 255.0])
        strength = float(rng.uniform(6.0, 20.0))
        ys = np.arange(height, dtype=np.float32)[:, None]
        xs = np.arange(width, dtype=np.float32)[None, :]
        glow = np.exp(-(((xs - cx) ** 2) + ((ys - cy) ** 2) * 6.0) / (radius * radius)).astype(np.float32)
        result += glow[:, :, None] * colour * (strength / 255.0)

    # 5. Mist where the road meets the city, so the transition is not a hard line.
    mist_height = max(8, road_height // 5)
    mist = np.linspace(0.30, 0.0, mist_height, dtype=np.float32)[:, None, None]
    result[road_top : road_top + mist_height, :, :] = (
        result[road_top : road_top + mist_height, :, :] * (1.0 - mist)
        + np.array([150.0, 150.0, 158.0], dtype=np.float32) * mist
    )
    return np.clip(result, 0, 255)


def vignette(image: np.ndarray, strength: float = 0.45) -> np.ndarray:
    height, width = image.shape[0], image.shape[1]
    ys = np.linspace(-1.0, 1.0, height, dtype=np.float32)[:, None]
    xs = np.linspace(-1.0, 1.0, width, dtype=np.float32)[None, :]
    radius = np.sqrt(xs**2 + ys**2) / math.sqrt(2.0)
    mask = 1.0 - strength * np.clip(radius, 0.0, 1.0) ** 2.2
    return np.clip(image * mask[:, :, None], 0, 255)


def generate(width: int, height: int) -> Image.Image:
    rng = np.random.default_rng(SEED)
    canvas = sky_gradient(width, height)
    image = Image.fromarray(canvas.astype(np.uint8)).convert("RGBA")
    for index, (max_height, colour, window_colour, lit_chance, blur, base_y) in enumerate(LAYERS):
        layer = skyline_layer(width, height, rng, colour, window_colour, lit_chance, base_y, max_height)
        if blur > 0.0:
            layer = layer.filter(ImageFilter.GaussianBlur(blur))
        # The further back a layer is, the more the haze eats into its contrast.
        alpha = layer.split()[3].point(lambda value: int(value * (1.0 - 0.06 * index)))
        layer.putalpha(alpha)
        image = Image.alpha_composite(image, layer)
    image = add_street_level(image, rng)
    array = np.asarray(image.convert("RGB")).astype(np.float32)
    array = add_stars(array, rng)
    array = add_road(array, rng)
    array = vignette(array)
    # A touch of grain keeps the flat gradients from banding on a phone screen.
    grain = rng.normal(0.0, 2.4, size=(height, width, 1)).astype(np.float32)
    array = np.clip(array + grain, 0, 255)
    return Image.fromarray(array.astype(np.uint8))


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate the menu background")
    parser.add_argument("--out", type=Path, default=Path("assets"))
    parser.add_argument("--width", type=int, default=1080)
    parser.add_argument("--height", type=int, default=1920)
    args = parser.parse_args()
    target_dir = args.out / "menu"
    target_dir.mkdir(parents=True, exist_ok=True)
    image = generate(args.width, args.height)
    path = target_dir / "background.png"
    image.save(path, optimize=True)
    # A smaller copy for the low-end preset / fast loading.
    small = image.resize((max(360, args.width // 2), max(640, args.height // 2)), Image.LANCZOS)
    small_path = target_dir / "background_small.png"
    small.save(small_path, optimize=True)
    print(f"wrote {path} ({path.stat().st_size // 1024} KiB) and {small_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
