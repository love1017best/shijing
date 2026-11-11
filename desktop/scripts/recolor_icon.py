# 把应用图标里的紫色系换成橙色系（v0.3.11 起强调色是橙色）：只动紫 / 蓝 / 品红这一段色相，
# 太阳的暖黄和白色取景框不动；明暗保持原样，所以山的层次、光晕都还在。
# 用法：python3 recolor_icon.py 输入.png 输出.png
# 注意：make_icon.py 是更早的画法，已经和现在的图标对不上，改图标以这个脚本 + 现有 PNG 为准。
import sys

import numpy as np
from PIL import Image

src = Image.open(sys.argv[1])
alpha = src.getchannel("A") if src.mode == "RGBA" else None
hsv = np.asarray(src.convert("RGB").convert("HSV")).astype(np.float32)
h, s, v = hsv[..., 0] * 360 / 255, hsv[..., 1] / 255, hsv[..., 2] / 255

# 紫色系：色相 110°–350°（含太阳光晕和紫色混出来的灰绿），有一定饱和度（白框、灰色不动）
w = np.clip((s - 0.06) / 0.10, 0, 1)
w *= np.clip((h - 100) / 20, 0, 1) * np.clip((355 - h) / 10, 0, 1)

# 天空偏蓝紫的部分换成深一点的红橙，偏品红（靠近地平线）的换成亮橙，保留原来的渐变走向
t = np.clip((h - 230) / 90, 0, 1)  # 0 = 蓝紫，1 = 品红
nh = 14 + 20 * t  # 14°（红橙）→ 34°（橙）
# 原图的紫偏灰，直接换色相会发闷成棕色：饱和度拉到 0.6 以上
ns = np.clip(0.58 + 0.45 * s, 0, 0.95)
# 暗部（夜空、近处的山）提亮一些，免得变成发黑的棕色
nv = np.clip(v * 1.18 + 0.07, 0, 1)

out = hsv.copy()
out[..., 0] = (h * (1 - w) + nh * w) * 255 / 360
out[..., 1] = (s * (1 - w) + ns * w) * 255
out[..., 2] = (v * (1 - w) + nv * w) * 255
img = Image.fromarray(out.round().clip(0, 255).astype(np.uint8), "HSV").convert("RGB")
if alpha is not None:
    img.putalpha(alpha)
img.save(sys.argv[2])
