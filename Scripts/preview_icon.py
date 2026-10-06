#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""拾光 App 图标 — 本地版式预览 / 兜底生成器（与 Scripts/generate_icon.swift 同常数）。

交付路径的**权威**生成器是 `Scripts/generate_icon.swift`（CI 内用 Core Graphics 跑一次生成源图）。
本文件刻意与它保持**同一组几何/色彩常数**，用于：
  1. 在没有 Xcode / Swift 的机器上肉眼校验构图与小尺寸可读性（输出对照图）；
  2. 作为仓库内 committed PNG 的兜底生成方式（Swift 生成器失效时仍能出图）。

设计（方案 A「光圈」，视觉原创）：
  - 抽象**三段弧线**围成光圈，暗示镜头 / 对焦环；三处小缺口给足识别特征
  - 底色 深空黑 #0A0A0A；主色 暖金 #FFB347 → 橙 #FF7A45 径向渐变
  - 中心柔光呼应「拾光 = 拾取光影」
  - 无文字、无品牌标识；1024×1024 **不带圆角**（圆角由系统裁切）；输出不透明 PNG

用法：
  python3 Scripts/preview_icon.py [--out <png>] [--sheet <png>] [--no-sheet]
"""

from __future__ import annotations

import argparse
import math
import os

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

# ── 常数（必须与 Scripts/generate_icon.swift 完全一致）──────────────────────
SIZE = 1024
BG = (0x0A, 0x0A, 0x0A)          # 深空黑
GOLD = (0xFF, 0xB3, 0x47)        # 暖金
ORANGE = (0xFF, 0x7A, 0x45)      # 橙

RING_RADIUS = 300.0              # 光圈半径（弧线中心线）
RING_WIDTH = 56.0                # 弧线粗细
ARC_COUNT = 3                    # 三段弧
ARC_SWEEP_DEG = 101.0            # 每段弧张角 → 缺口张角 = 120 - 101 = 19°
ARC_START0_DEG = 279.5           # 首段弧起始角（数学约定：+x 轴起、逆时针、y 向上）
                                 # 缺口中心 = 279.5 - 19/2 + 120k → 270° / 30° / 150°（缺口居下）
CAP_ROUND = False                # 平端弧（与光圈刀口的"利落"感一致，且跨实现无歧义）

BLOOM_RADIUS = 600.0             # 中心柔光半径
BLOOM_ALPHA = 0.24               # 中心柔光峰值不透明度
BLOOM_POWER = 1.6                # 柔光衰减指数
GLOW_SIGMA = 24.0                # 弧线外发光模糊 sigma
GLOW_ALPHA = 0.62                # 弧线外发光强度
GRAD_CENTER = (400.0, 400.0)     # 渐变中心（屏幕坐标：左上原点、y 向下）
GRAD_RADIUS = 620.0              # 渐变半径（金 → 橙，smoothstep 过渡）


def _lerp(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))


def _smoothstep(t: float) -> float:
    t = min(max(t, 0.0), 1.0)
    return t * t * (3.0 - 2.0 * t)


def radial_gradient(size: int, center, radius: float) -> Image.Image:
    """金 → 橙 径向渐变（smoothstep 过渡，避免线性渐变的灰带）。"""
    y, x = np.mgrid[0:size, 0:size].astype(np.float32)
    d = np.hypot(x - center[0], y - center[1]) / max(radius, 1.0)
    t = np.clip(d, 0.0, 1.0)
    t = t * t * (3.0 - 2.0 * t)
    out = np.zeros((size, size, 3), dtype=np.float32)
    for c in range(3):
        out[..., c] = GOLD[c] + (ORANGE[c] - GOLD[c]) * t
    return Image.fromarray(out.astype(np.uint8), "RGB")


def arcs_mask(size: int, supersample: int = 2) -> Image.Image:
    """三段弧线的覆盖遮罩。超采样后降采样得到干净边缘。"""
    k = supersample
    s = size * k
    mask = Image.new("L", (s, s), 0)
    draw = ImageDraw.Draw(mask)
    cx = cy = s / 2.0
    r = RING_RADIUS * k
    w = RING_WIDTH * k
    box = (cx - r, cy - r, cx + r, cy + r)
    for i in range(ARC_COUNT):
        a0 = ARC_START0_DEG + i * 360.0 / ARC_COUNT
        a1 = a0 + ARC_SWEEP_DEG
        # 数学角 → PIL 角（PIL 以 y 向下、顺时针为正，故 φ = -θ，并交换起止）
        draw.arc(box, -a1, -a0, fill=255, width=int(round(w)))
        if CAP_ROUND:
            for deg in (a0, a1):
                px = cx + r * math.cos(math.radians(deg))
                py = cy - r * math.sin(math.radians(deg))
                draw.ellipse((px - w / 2, py - w / 2, px + w / 2, py + w / 2), fill=255)
    interp = Image.LANCZOS if not CAP_ROUND else Image.LANCZOS
    return mask.resize((size, size), interp)


def build_icon(size: int = SIZE) -> Image.Image:
    scale = size / SIZE

    def px(v: float) -> float:
        return v * scale

    base = Image.new("RGB", (size, size), BG)

    # 1) 中心柔光：让图标在深色壁纸上有存在感（拾取光影）
    y, x = np.mgrid[0:size, 0:size].astype(np.float32)
    d = np.hypot(x - size / 2.0, y - size / 2.0) / px(BLOOM_RADIUS)
    bloom = np.clip(1.0 - d, 0.0, 1.0) ** BLOOM_POWER * BLOOM_ALPHA
    layer = np.zeros((size, size, 4), dtype=np.uint8)
    layer[..., 0], layer[..., 1], layer[..., 2] = GOLD
    layer[..., 3] = (bloom * 255).astype(np.uint8)
    base = Image.alpha_composite(base.convert("RGBA"),
                                Image.fromarray(layer, "RGBA")).convert("RGB")

    mask = arcs_mask(size)

    # 2) 弧线外发光：同一形状做大半径模糊后按低不透明度叠加
    glow = mask.filter(ImageFilter.GaussianBlur(max(px(GLOW_SIGMA), 0.6)))
    glow = glow.point(lambda v: int(v * GLOW_ALPHA))
    glow_layer = Image.new("RGBA", (size, size), ORANGE + (0,))
    glow_layer.putalpha(glow)
    base = Image.alpha_composite(base.convert("RGBA"), glow_layer).convert("RGB")

    # 3) 弧线本体：金 → 橙 径向渐变，按弧线遮罩裁切
    grad = radial_gradient(size, (px(GRAD_CENTER[0]), px(GRAD_CENTER[1])), px(GRAD_RADIUS))
    arc_layer = grad.convert("RGBA")
    arc_layer.putalpha(mask)
    base = Image.alpha_composite(base.convert("RGBA"), arc_layer).convert("RGB")
    return base


def contact_sheet(icon: Image.Image, path: str) -> None:
    """小尺寸对照图：300 / 180(60pt@3x) / 120 / 60，用于校验小尺寸不糊。"""
    tiles = [icon.resize((side, side), Image.LANCZOS) for side in (300, 180, 120, 60)]
    pad = 24
    width = sum(t.width for t in tiles) + pad * (len(tiles) + 1)
    height = max(t.height for t in tiles) + pad * 2
    sheet = Image.new("RGB", (width, height), (34, 34, 36))
    x = pad
    for t in tiles:
        sheet.paste(t, (x, pad + (height - pad * 2 - t.height) // 2))
        x += t.width + pad
    sheet.save(path)


def main() -> None:
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.dirname(here)
    default_out = os.path.join(root, "App", "Assets.xcassets",
                               "AppIcon.appiconset", "AppIcon-1024.png")
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=default_out)
    ap.add_argument("--sheet", default=os.path.join(root, "Scripts", "icon_preview_sheet.png"))
    ap.add_argument("--no-sheet", action="store_true")
    args = ap.parse_args()

    icon = build_icon(SIZE)
    assert icon.size == (SIZE, SIZE)
    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    icon.save(args.out, format="PNG", optimize=True)
    print(f"icon  -> {args.out}  ({os.path.getsize(args.out)} bytes, "
          f"{icon.size[0]}x{icon.size[1]}, mode={icon.mode})")
    if not args.no_sheet:
        contact_sheet(icon, args.sheet)
        print(f"sheet -> {args.sheet}")


if __name__ == "__main__":
    main()
