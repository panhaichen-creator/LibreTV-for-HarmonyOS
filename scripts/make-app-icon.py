# -*- coding: utf-8 -*-
"""生成开源版应用图标（512x512 RGBA），替换掉带私有品牌字母的旧图标。

设计取向：
  - 只用一个「播放三角」＋ 品牌主色渐变，不含任何字母、罗马字、汉字，
    避免与任何品牌标识撞形；
  - 圆角半径、留白、投影方向沿用旧图标的比例，安装后视觉重心不变。

用法（在仓库根目录执行）：
  python scripts/make-app-icon.py           只出预览 dev/_icon_preview.png，不动工程
  python scripts/make-app-icon.py --write   预览 + 写入下面两个路径

输出：
  dev/_icon_preview.png                     预览（先看再替换）
  AppScope/resources/base/media/app_icon.png
  entry/src/main/resources/base/media/app_icon.png

想换成自己的图标？最省事的办法是直接拿一张 512×512 的 PNG 覆盖上面两个文件；
要改配色 / 比例就改本文件里的常量再跑一次。

为什么不用生成式出图：图标要求「无文字、几何精确、边缘锐利、可复现」，
程序化绘制比扩散模型更可控，也能在仓库里留一份可重跑的源码。
"""

import os
from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

SIZE = 512          # 最终尺寸（与旧图标一致）
SS = 4              # 超采样倍数
N = SIZE * SS

# 品牌主色（entry/.../base/element/color.json: color_primary / color_primary_dark）
C_TOP = (244, 105, 95)      # #F4695F 暖橙红
C_MID = (229, 72, 77)       # #E5484D color_primary
C_BOT = (194, 51, 56)       # #C23338 color_primary_dark

RADIUS_RATIO = 0.225        # 圆角占边长比例，与旧图标观感一致


def lerp(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))


def diagonal_gradient(size):
    """左上 → 右下的三段渐变（先暖再加饱和，避免中间发灰）。"""
    img = Image.new('RGB', (size, size))
    px = img.load()
    for y in range(size):
        for x in range(size):
            t = (x + y) / (2.0 * (size - 1))
            if t < 0.5:
                c = lerp(C_TOP, C_MID, t / 0.5)
            else:
                c = lerp(C_MID, C_BOT, (t - 0.5) / 0.5)
            px[x, y] = c
    return img


def radial(size, cx, cy, radius, rgb, alpha):
    """径向罩：同色相只把 alpha 压到 0，避免出现异色圆环。"""
    layer = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    px = layer.load()
    r2 = radius * radius
    for y in range(size):
        dy = y - cy
        for x in range(size):
            dx = x - cx
            d2 = dx * dx + dy * dy
            if d2 >= r2:
                continue
            # 1 - d^2 的高次曲线，中心实、边缘平顺
            k = 1.0 - d2 / r2
            k = k * k * k
            px[x, y] = (rgb[0], rgb[1], rgb[2], int(alpha * k))
    return layer


def rounded_triangle_mask(size, cx, cy, height, corner):
    """播放三角：先画尖角，再模糊+阈值，把三个角磨圆。"""
    half_h = height / 2.0
    # 等边三角，视觉重心右移一点点（光学居中）
    w = height * 0.866
    pts = [
        (cx - w * 0.42, cy - half_h),
        (cx - w * 0.42, cy + half_h),
        (cx + w * 0.58, cy),
    ]
    m = Image.new('L', (size, size), 0)
    ImageDraw.Draw(m).polygon(pts, fill=255)
    m = m.filter(ImageFilter.GaussianBlur(corner))
    m = m.point(lambda v: 255 if v >= 128 else 0)
    return m.filter(ImageFilter.GaussianBlur(corner * 0.12))  # 抗锯齿回一点


def main():
    grad = diagonal_gradient(N).convert('RGBA')

    # 高光（左上）与压暗（右下），让平面渐变有体积感
    grad.alpha_composite(radial(N, N * 0.28, N * 0.18, N * 0.62, (255, 255, 255), 46))
    grad.alpha_composite(radial(N, N * 0.86, N * 0.95, N * 0.55, (60, 8, 14), 40))

    # 播放三角 + 投影
    tri = rounded_triangle_mask(N, N * 0.525, N * 0.5, N * 0.44, N * 0.028)
    shadow = Image.new('RGBA', (N, N), (0, 0, 0, 0))
    shadow.putalpha(tri.point(lambda v: int(v * 0.22)))
    shadow = shadow.filter(ImageFilter.GaussianBlur(N * 0.012))
    grad.alpha_composite(shadow, (0, int(N * 0.012)))
    white = Image.new('RGBA', (N, N), (255, 255, 255, 255))
    white.putalpha(tri)
    grad.alpha_composite(white)

    # 圆角遮罩（外圈透明），外加一圈内描边模拟玻璃边
    mask = Image.new('L', (N, N), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [0, 0, N - 1, N - 1], radius=int(N * RADIUS_RATIO), fill=255)
    edge = Image.new('RGBA', (N, N), (0, 0, 0, 0))
    ImageDraw.Draw(edge).rounded_rectangle(
        [N * 0.008, N * 0.008, N * 0.992, N * 0.992],
        radius=int(N * (RADIUS_RATIO - 0.006)), outline=(255, 255, 255, 58),
        width=max(1, int(N * 0.006)))
    grad.alpha_composite(edge)

    out = Image.new('RGBA', (N, N), (0, 0, 0, 0))
    out.paste(grad, (0, 0), mask)
    out = out.resize((SIZE, SIZE), Image.LANCZOS)

    preview = os.path.join(ROOT, 'dev', '_icon_preview.png')
    out.save(preview)
    print('[icon] preview ->', preview)

    targets = [
        os.path.join(ROOT, 'AppScope', 'resources', 'base', 'media', 'app_icon.png'),
        os.path.join(ROOT, 'entry', 'src', 'main', 'resources', 'base', 'media', 'app_icon.png'),
    ]
    if '--write' in __import__('sys').argv:
        for t in targets:
            out.save(t)
            print('[icon] wrote %s (%.1f KB)' % (t, os.path.getsize(t) / 1024))
    else:
        print('[icon] 未写入，确认预览后加 --write')


if __name__ == '__main__':
    main()
