#!/usr/bin/env python3
"""Draw the iPaste app icon (gold hit-spark on a dark rounded square)."""
from __future__ import annotations

import math
import struct
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "iPaste" / "Assets.xcassets" / "AppIcon.appiconset"

SIZES = {
    "icon_16x16.png": 16,
    "icon_16x16@2x.png": 32,
    "icon_32x32.png": 32,
    "icon_32x32@2x.png": 64,
    "icon_128x128.png": 128,
    "icon_128x128@2x.png": 256,
    "icon_256x256.png": 256,
    "icon_256x256@2x.png": 512,
    "icon_512x512.png": 512,
    "icon_512x512@2x.png": 1024,
}


def chunk(tag: bytes, data: bytes) -> bytes:
    return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)


def write_png(path: Path, width: int, height: int, pixels: bytes) -> None:
    raw = bytearray()
    stride = width * 4
    for y in range(height):
        raw.append(0)
        raw.extend(pixels[y * stride : (y + 1) * stride])
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b"")
    path.write_bytes(png)


def clamp(v: float) -> int:
    return max(0, min(255, int(v + 0.5)))


def blend(dst: list[float], src: tuple[float, float, float, float]) -> None:
    sr, sg, sb, sa = src
    if sa <= 0:
        return
    da = dst[3]
    out_a = sa + da * (1 - sa)
    if out_a <= 0:
        return
    dst[0] = (sr * sa + dst[0] * da * (1 - sa)) / out_a
    dst[1] = (sg * sa + dst[1] * da * (1 - sa)) / out_a
    dst[2] = (sb * sa + dst[2] * da * (1 - sa)) / out_a
    dst[3] = out_a


def rounded_mask(nx: float, ny: float) -> float:
    # Squircle-ish rounded square in [-1, 1].
    ax = abs(nx)
    ay = abs(ny)
    limit = 0.92
    radius = 0.28
    qx = ax - (limit - radius)
    qy = ay - (limit - radius)
    ox = max(qx, 0)
    oy = max(qy, 0)
    outside = math.hypot(ox, oy)
    inside = min(max(qx, qy), 0)
    dist = outside + inside - radius
    return max(0.0, min(1.0, 0.5 - dist * 18))


def spark(nx: float, ny: float) -> tuple[float, float, float, float]:
    r = math.hypot(nx, ny)
    ang = math.atan2(ny, nx)
    # Eight tapered rays.
    rays = abs(math.cos(ang * 4))
    ray = max(0.0, rays - 0.55) / 0.45
    length = max(0.0, 1.0 - r / 0.72)
    alpha = (ray ** 1.6) * (length ** 1.2)
    # Hot core.
    core = max(0.0, 1.0 - r / 0.16)
    alpha = max(alpha, core)
    gold_r, gold_g, gold_b = 255, 196, 48
    white = core
    cr = gold_r * (1 - white) + 255 * white
    cg = gold_g * (1 - white) + 250 * white
    cb = gold_b * (1 - white) + 230 * white
    ring = max(0.0, 1.0 - abs(r - 0.34) / 0.035)
    if ring > 0:
        alpha = max(alpha, ring * 0.85)
        cr, cg, cb = 255, 228, 140
    return cr / 255, cg / 255, cb / 255, min(1.0, alpha)


def render(size: int) -> bytes:
    pixels = bytearray(size * size * 4)
    for y in range(size):
        ny = ((y + 0.5) / size) * 2 - 1
        for x in range(size):
            nx = ((x + 0.5) / size) * 2 - 1
            mask = rounded_mask(nx, ny)
            # Dark plate.
            plate = [0.08, 0.07, 0.06, mask]
            # Warm glow behind the spark.
            glow = max(0.0, 1.0 - math.hypot(nx, ny) / 0.85)
            blend(plate, (1.0, 0.45, 0.08, 0.55 * glow * mask))
            sr, sg, sb, sa = spark(nx * 1.05, ny * 1.05)
            blend(plate, (sr, sg, sb, sa * mask))
            i = (y * size + x) * 4
            pixels[i] = clamp(plate[0] * 255)
            pixels[i + 1] = clamp(plate[1] * 255)
            pixels[i + 2] = clamp(plate[2] * 255)
            pixels[i + 3] = clamp(plate[3] * 255)
    return bytes(pixels)


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    for name, size in SIZES.items():
        write_png(OUT / name, size, size, render(size))
        print(f"wrote {name} ({size}px)")


if __name__ == "__main__":
    main()
