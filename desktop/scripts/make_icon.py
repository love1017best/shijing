# 拾景的应用图标：圆角方块里的黄昏山景，按 macOS 图标网格（1024 画布、824 主体）绘制
import sys
from PIL import Image, ImageDraw, ImageFilter

S = 4  # 超采样倍数，最后缩小抗锯齿
W = 1024 * S
body = 824 * S
off = (W - body) // 2
radius = 186 * S

def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))

def gradient(h, stops):
    img = Image.new("RGB", (1, h))
    px = img.load()
    for y in range(h):
        t = y / (h - 1)
        for (p0, c0), (p1, c1) in zip(stops, stops[1:]):
            if p0 <= t <= p1:
                px[0, y] = lerp(c0, c1, (t - p0) / (p1 - p0))
                break
    return img.resize((body, h))

sky = gradient(body, [(0, (38, 42, 112)), (0.45, (122, 82, 170)), (0.78, (240, 140, 120)), (1, (255, 196, 140))])
scene = sky.convert("RGBA")
d = ImageDraw.Draw(scene)

# 太阳（带柔光）
sun_c = (int(body * 0.63), int(body * 0.50))
glow = Image.new("RGBA", scene.size, (0, 0, 0, 0))
ImageDraw.Draw(glow).ellipse([sun_c[0] - 230 * S, sun_c[1] - 230 * S, sun_c[0] + 230 * S, sun_c[1] + 230 * S], fill=(255, 220, 170, 110))
glow = glow.filter(ImageFilter.GaussianBlur(60 * S))
scene = Image.alpha_composite(scene, glow)
d = ImageDraw.Draw(scene)
r = 118 * S
d.ellipse([sun_c[0] - r, sun_c[1] - r, sun_c[0] + r, sun_c[1] + r], fill=(255, 236, 200, 255))

def ridge(points, color):
    pts = [(int(x * body), int(y * body)) for x, y in points]
    pts = [(0, body)] + pts + [(body, body)]
    d.polygon(pts, fill=color)

ridge([(0, 0.62), (0.18, 0.52), (0.34, 0.60), (0.52, 0.46), (0.70, 0.58), (0.86, 0.50), (1, 0.57)], (150, 92, 160, 255))
ridge([(0, 0.72), (0.16, 0.64), (0.30, 0.70), (0.48, 0.60), (0.66, 0.71), (0.84, 0.63), (1, 0.70)], (96, 64, 138, 255))
ridge([(0, 0.82), (0.22, 0.74), (0.42, 0.80), (0.60, 0.73), (0.80, 0.81), (1, 0.76)], (50, 40, 96, 255))

# 取景框角标：「拾」取一帧
fc = (255, 255, 255, 235)
lw = 30 * S
m, L = 150 * S, 120 * S
for (x, y, dx, dy) in [(m, m, 1, 1), (body - m, m, -1, 1), (m, body - m, 1, -1), (body - m, body - m, -1, -1)]:
    d.line([(x, y), (x + dx * L, y)], fill=fc, width=lw)
    d.line([(x, y), (x, y + dy * L)], fill=fc, width=lw)
    d.ellipse([x - lw // 2, y - lw // 2, x + lw // 2, y + lw // 2], fill=fc)
    for ex, ey in [(x + dx * L, y), (x, y + dy * L)]:
        d.ellipse([ex - lw // 2, ey - lw // 2, ex + lw // 2, ey + lw // 2], fill=fc)

mask = Image.new("L", (body, body), 0)
ImageDraw.Draw(mask).rounded_rectangle([0, 0, body - 1, body - 1], radius=radius, fill=255)

canvas = Image.new("RGBA", (W, W), (0, 0, 0, 0))
shadow = Image.new("RGBA", (W, W), (0, 0, 0, 0))
ImageDraw.Draw(shadow).rounded_rectangle([off, off + 12 * S, off + body, off + body + 12 * S], radius=radius, fill=(0, 0, 0, 90))
shadow = shadow.filter(ImageFilter.GaussianBlur(18 * S))
canvas = Image.alpha_composite(canvas, shadow)
canvas.paste(scene, (off, off), mask)
canvas.resize((1024, 1024), Image.LANCZOS).save(sys.argv[1])
