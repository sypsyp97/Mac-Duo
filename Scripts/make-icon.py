#!/usr/bin/env python3
"""Draws Resources/AppIcon.icns.

The mark is the effect itself: a MacBook seen from the front, its picture
lifted off the glass and leaning back, blurred and dimmed the way Mac Duo
draws it while the lid closes.

    ~/.manim-svg-venv/bin/python Scripts/make-icon.py

Needs Pillow and macOS's iconutil.
"""

import math
import pathlib
import shutil
import subprocess
import tempfile

from PIL import Image, ImageDraw, ImageFilter

ROOT = pathlib.Path(__file__).resolve().parent.parent
CANVAS = 1024
# macOS leaves the outer eighth of the tile empty and rounds with a squircle.
INSET = 100


def squircle(size, exponent=5.0, supersample=4):
    """A continuous-corner rounded square as an alpha mask.

    The exponent is the superellipse power: 2 is a circle, large values
    approach a square, and 5 is close to what macOS draws.
    """
    big = size * supersample
    mask = Image.new("L", (big, big), 0)
    draw = ImageDraw.Draw(mask)
    half = big / 2
    n = exponent
    points = []
    steps = 720
    for i in range(steps):
        theta = 2 * math.pi * i / steps
        c, s = math.cos(theta), math.sin(theta)
        x = half * math.copysign(abs(c) ** (2 / n), c)
        y = half * math.copysign(abs(s) ** (2 / n), s)
        points.append((half + x, half + y))
    draw.polygon(points, fill=255)
    return mask.resize((size, size), Image.LANCZOS)


def vertical_gradient(size, top, bottom):
    ramp = Image.new("RGB", (1, size))
    for y in range(size):
        t = y / max(size - 1, 1)
        ramp.putpixel((0, y), tuple(round(a + (b - a) * t) for a, b in zip(top, bottom)))
    return ramp.resize((size, size), Image.BICUBIC)


def draw_icon():
    body = CANVAS - 2 * INSET
    image = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))

    tile = vertical_gradient(body, (46, 52, 84), (18, 20, 34)).convert("RGBA")
    tile.putalpha(squircle(body))
    image.alpha_composite(tile, (INSET, INSET))

    # The picture, hinged at the bottom of the screen and turned back. Same
    # trapezoid the renderer produces part way through a close.
    layer = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    art = ImageDraw.Draw(layer)

    hinge_y = 660
    near_half, far_half = 300, 196
    top_y = 300
    art.polygon(
        [
            (CANVAS / 2 - near_half, hinge_y),
            (CANVAS / 2 + near_half, hinge_y),
            (CANVAS / 2 + far_half, top_y),
            (CANVAS / 2 - far_half, top_y),
        ],
        fill=(150, 196, 255, 255),
    )
    # Dimmed towards the far edge, like the shader's light falloff.
    shade = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    ImageDraw.Draw(shade).rectangle([0, 0, CANVAS, CANVAS], fill=(12, 14, 26, 0))
    for y in range(top_y, hinge_y):
        t = 1 - (y - top_y) / (hinge_y - top_y)
        ImageDraw.Draw(shade).line([(0, y), (CANVAS, y)], fill=(12, 14, 26, int(190 * t**1.4)))
    layer.alpha_composite(Image.composite(shade, Image.new("RGBA", shade.size), layer.getchannel("A")))
    # Out of focus towards the far edge as well.
    blurred = layer.filter(ImageFilter.GaussianBlur(14))
    keep = Image.new("L", (CANVAS, CANVAS), 0)
    for y in range(CANVAS):
        t = min(max((hinge_y - y) / (hinge_y - top_y), 0), 1)
        ImageDraw.Draw(keep).line([(0, y), (CANVAS, y)], fill=int(255 * t**1.3))
    image.alpha_composite(Image.composite(blurred, layer, keep))

    # The base the lid folds onto.
    base = ImageDraw.Draw(image)
    base.rounded_rectangle([CANVAS / 2 - 340, hinge_y, CANVAS / 2 + 340, hinge_y + 44],
                           radius=20, fill=(228, 233, 245, 255))
    base.rounded_rectangle([CANVAS / 2 - 92, hinge_y + 44, CANVAS / 2 + 92, hinge_y + 62],
                           radius=9, fill=(176, 184, 205, 255))
    return image


def main():
    icon = draw_icon()
    with tempfile.TemporaryDirectory() as workspace:
        iconset = pathlib.Path(workspace) / "AppIcon.iconset"
        iconset.mkdir()
        for points in (16, 32, 128, 256, 512):
            for scale in (1, 2):
                pixels = points * scale
                suffix = "" if scale == 1 else "@2x"
                icon.resize((pixels, pixels), Image.LANCZOS).save(
                    iconset / f"icon_{points}x{points}{suffix}.png"
                )
        destination = ROOT / "Resources" / "AppIcon.icns"
        subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(destination)], check=True)
    print(f"wrote {destination}")


if __name__ == "__main__":
    main()
