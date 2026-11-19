"""Biểu tượng GramMini (D35): khối kính vuông bo góc ánh cầu vồng, máy bay giấy trong suốt — lấy từ ảnh anh đưa
(tools/icon/GramMini-src.png, bản gốc ở Tai_Lieu/icon/GramMini.png). Ảnh gốc có nền đen bao quanh khối kính: cắt sát khối kính,
góc ngoài đường cong làm trong suốt (SpringBoard iOS 5 / 6 giữ kênh alpha, UIPrerenderedIcon = có), phóng lên 1024 làm bản cái
rồi thu nhỏ ra các cỡ iOS 5 / 6.

    python tools/icon/make_icon.py tools/icon/GramMini-src.png app/Resources
"""
import os
import sys
from PIL import Image, ImageDraw, ImageFilter

S = 1024
DARK = 40   # độ sáng tối đa của nền đen (nền ~0–18, mép khối kính > 50)

SIZES = {"Icon.png": 57, "Icon@2x.png": 114, "Icon-72.png": 72, "Icon-72@2x.png": 144, "Icon-Small.png": 29,
         "Icon-Small@2x.png": 58, "Icon-Small-50.png": 50, "Icon-Small-50@2x.png": 100}


def shape_mask(rgb):
    """Vùng khối kính: điểm sáng hơn nền đen, lấp lỗ bên trong (loang từ 4 góc ảnh = phần nền)."""
    m = rgb.convert("L").point(lambda v: 255 if v > DARK else 0)
    bg = m.copy()
    for xy in ((0, 0), (S - 1, 0), (0, S - 1), (S - 1, S - 1)):
        if bg.getpixel(xy) == 0:
            ImageDraw.floodfill(bg, xy, 128)
    m = bg.point(lambda v: 0 if v == 128 else 255)
    # gọt 1 điểm ảnh mép (viền tối lẫn nền đen) rồi làm mềm mép để thu nhỏ không răng cưa
    return m.filter(ImageFilter.MinFilter(3)).filter(ImageFilter.GaussianBlur(1.2))


def make(src):
    im = Image.open(src).convert("RGB")
    box = im.convert("L").point(lambda v: 255 if v > DARK else 0).getbbox()
    rgb = im.crop(box).resize((S, S), Image.LANCZOS)
    big = rgb.convert("RGBA")
    big.putalpha(shape_mask(rgb))
    return big


def small(big, px):
    """Thu nhỏ; cỡ nhỏ làm nét thêm một chút để máy bay giấy (nét kính mảnh) không nhoè."""
    out = big.resize((px, px), Image.LANCZOS)
    if px <= 72:
        a = out.getchannel("A")
        out = out.filter(ImageFilter.UnsharpMask(radius=1, percent=60 if px <= 32 else 40, threshold=2))
        out.putalpha(a)
    return out


if __name__ == "__main__":
    src, out = sys.argv[1], sys.argv[2]
    big = make(src)
    big.save(os.path.join(os.path.dirname(os.path.abspath(__file__)), "icon-1024.png"), optimize=True)
    for name, px in SIZES.items():
        small(big, px).save(os.path.join(out, name), optimize=True)
    print("ok")
