# -*- coding: utf-8 -*-
"""画一张「磁贴是什么 / 怎么用」的示意图（一次性脚本，不参与打包）。"""
import os
from PIL import Image, ImageDraw, ImageFont

FONTS = [r"C:\Windows\Fonts\msyh.ttc", r"C:\Windows\Fonts\msyhbd.ttc", r"C:\Windows\Fonts\simhei.ttf"]


def font(size, bold=False):
    order = [FONTS[1], FONTS[0], FONTS[2]] if bold else [FONTS[0], FONTS[1], FONTS[2]]
    for p in order:
        if os.path.exists(p):
            try:
                return ImageFont.truetype(p, size)
            except Exception:
                continue
    return ImageFont.load_default()


W, H = 1080, 760
BG, CARD, TXT, MUTED, ACCENT = "#F2F2F5", "#1C1C1E", "#111111", "#6B6B70", "#E8402A"

img = Image.new("RGB", (W, H), BG)
d = ImageDraw.Draw(img)

f_title = font(38, True)
f_sub = font(22)
f_cap = font(19)
f_tile = font(20)
f_note = font(21)
f_ct = font(23, True)
f_cb = font(19)

d.text((60, 36), "「磁贴」= 控制中心里那一排开关按钮", font=f_title, fill=TXT)
d.text((60, 90), "我给「抖音下载器」也加了一个同款按钮，名字叫「抖音下载」", font=f_sub, fill=MUTED)

# ---------- 左：控制中心示意图 ----------
d.rounded_rectangle([60, 150, 600, 610], radius=32, fill=CARD)
d.text((96, 172), "控制中心（从屏幕右上角下拉两次）", font=f_cap, fill="#B8B8BD")

tiles = ["手电筒", "蓝牙", "移动数据", "飞行模式", "截屏", "热点", "勿扰", "抖音下载"]
cx0, cy0, dx, dy, r = 130, 270, 118, 150, 40
for i, name in enumerate(tiles):
    col, row = i % 4, i // 4
    cx, cy = cx0 + col * dx, cy0 + row * dy
    hl = name == "抖音下载"
    d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=ACCENT if hl else "#3A3A3E")
    d.rounded_rectangle([cx - 13, cy - 13, cx + 13, cy + 13], radius=6,
                        fill="#FFFFFF" if hl else "#9A9AA0")
    tw = d.textlength(name, font=f_tile)
    d.text((cx - tw / 2, cy + r + 8), name, font=f_tile, fill=ACCENT if hl else "#D8D8DD")

hx, hy = cx0 + 3 * dx, cy0 + dy          # 高亮的「抖音下载」
d.ellipse([hx - r - 9, hy - r - 9, hx + r + 9, hy + r + 9], outline=ACCENT, width=5)
d.line([hx, hy + r + 34, hx, hy + r + 58], fill=ACCENT, width=5)
d.polygon([(hx - 10, hy + r + 52), (hx + 10, hy + r + 52), (hx, hy + r + 72)], fill=ACCENT)
tip = "点这一个"
d.text((hx - d.textlength(tip, font=f_note) / 2, hy + r + 80), tip, font=f_note, fill=ACCENT)

d.text((96, 560), "和你手机里「手电筒」「截屏」是同一类东西", font=f_cap, fill="#8E8E93")

# ---------- 右：流程 ----------
rx, rw = 660, W - 50 - 660


def box(y, text, h, accent=False):
    d.rounded_rectangle([rx, y, rx + rw, y + h], radius=16,
                        fill="#FDECEA" if accent else "#FFFFFF",
                        outline=ACCENT if accent else "#D8D8DD", width=2)
    lines = text.split("\n")
    yy = y + (h - len(lines) * 28) / 2
    for ln in lines:
        tw = d.textlength(ln, font=f_note)
        d.text((rx + (rw - tw) / 2, yy), ln, font=f_note, fill=TXT)
        yy += 28


def arrow(y):
    x = rx + rw / 2
    d.line([x, y + 2, x, y + 16], fill="#9A9AA0", width=3)
    d.polygon([(x - 8, y + 14), (x + 8, y + 14), (x, y + 26)], fill="#9A9AA0")


heading = "点它之后发生的事（约 0.3 秒）"
d.text((rx + (rw - d.textlength(heading, font=f_sub)) / 2, 172), heading, font=f_sub, fill=TXT)

box(216, "在抖音里点\n分享 → 复制链接", 84)
arrow(304)
box(334, "下拉控制中心\n点「抖音下载」磁贴", 84, accent=True)
arrow(422)
box(452, "透明窗口冒头 0.3 秒\n读一次剪贴板就缩回", 84)
arrow(540)

# 通知卡片示意图
cy0c = 570
d.rounded_rectangle([rx, cy0c, rx + rw, cy0c + 104], radius=20, fill="#FFFFFF", outline="#D8D8DD", width=2)
d.rounded_rectangle([rx + 16, cy0c + 16, rx + 56, cy0c + 56], radius=10, fill="#7B61FF")
d.text((rx + 72, cy0c + 14), "检测到抖音链接", font=f_ct, fill=TXT)
d.text((rx + 72, cy0c + 44), "即将下载：v.douyin.com/xxx", font=f_cb, fill=MUTED)
d.rounded_rectangle([rx + 72, cy0c + 70, rx + 172, cy0c + 96], radius=13, fill="#EFEFF2")
d.text((rx + 86, cy0c + 73), "立即下载", font=f_cb, fill="#2A6BFF")

# ---------- 底部说明 ----------
d.text((60, 644), "※ 磁贴第一次要自己「拖」进控制中心，之后一直就在那儿：", font=f_sub, fill=MUTED)
d.text((60, 682), "下拉控制中心 → 点「编辑」→ 在图标列表里找「抖音下载」→ 拖到上面 → 完成",
       font=f_sub, fill=TXT)
d.text((60, 722), "找不到图标 / 点了没反应 → 告诉我，我加一个应用内的手动测试按钮来定位",
       font=f_cap, fill=MUTED)

out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "tile-guide.png")
img.save(out)
print("saved:", out)
