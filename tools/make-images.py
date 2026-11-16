#!/usr/bin/env python3
"""Tạo biểu tượng + ảnh khởi động tạm cho app (Python thuần, không cần thư viện ảnh) → app/Resources/.
Biểu tượng: nền xanh, bong bóng chat trắng có đuôi, ba chấm xanh. Ảnh khởi động: nền một màu như nền màn danh sách chat.
    python3 tools/make-images.py
"""
import math
import os
import struct
import zlib

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "app", "Resources")


def png(path, w, h, pixel):
    rows = bytearray()
    for y in range(h):
        rows.append(0)
        for x in range(w):
            rows.extend(pixel(x, y))
    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    data = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
    data += chunk(b"IDAT", zlib.compress(bytes(rows), 9)) + chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(data)


def mix(a, b, t):
    return tuple(int(round(a[i] * (1 - t) + b[i] * t)) for i in range(3))


def icon(size):
    top, bottom = (64, 170, 240), (22, 120, 205)
    white, dot = (255, 255, 255), (30, 130, 215)
    s = size / 114.0
    cx, cy, rx, ry = 57 * s, 52 * s, 36 * s, 29 * s

    def cover(x, y):
        # Độ phủ của bong bóng (elip + đuôi tam giác) — lấy mẫu 4×4 để khử răng cưa
        hit = 0
        for i in range(4):
            for j in range(4):
                px, py = x + (i + 0.5) / 4, y + (j + 0.5) / 4
                e = ((px - cx) / rx) ** 2 + ((py - cy) / ry) ** 2 <= 1
                # đuôi: tam giác dưới-trái
                ax, ay, bx, by, qx, qy = 30 * s, 70 * s, 50 * s, 78 * s, 26 * s, 92 * s
                d1 = (px - bx) * (ay - by) - (ax - bx) * (py - by)
                d2 = (px - qx) * (by - qy) - (bx - qx) * (py - qy)
                d3 = (px - ax) * (qy - ay) - (qx - ax) * (py - ay)
                tail = (d1 < 0) == (d2 < 0) == (d3 < 0)
                hit += e or tail
        return hit / 16.0

    def dots(x, y):
        hit = 0
        for i in range(4):
            for j in range(4):
                px, py = x + (i + 0.5) / 4, y + (j + 0.5) / 4
                for k in (-1, 0, 1):
                    if math.hypot(px - (cx + k * 15 * s), py - cy) <= 5 * s:
                        hit += 1
                        break
        return hit / 16.0

    def pixel(x, y):
        c = mix(top, bottom, y / size)
        c = mix(c, white, cover(x, y))
        return bytes(mix(c, dot, dots(x, y)))

    return pixel


def solid(rgb):
    b = bytes(rgb)
    return lambda x, y: b


def main():
    if hasattr(__import__("sys").stdout, "reconfigure"):
        __import__("sys").stdout.reconfigure(encoding="utf-8")
    os.makedirs(OUT, exist_ok=True)
    for name, size in [("Icon.png", 57), ("Icon@2x.png", 114), ("Icon-72.png", 72), ("Icon-72@2x.png", 144),
                       ("Icon-Small.png", 29), ("Icon-Small@2x.png", 58), ("Icon-Small-50.png", 50),
                       ("Icon-Small-50@2x.png", 100)]:
        png(os.path.join(OUT, name), size, size, icon(size))
    bg = (226, 232, 238)
    for name, w, h in [("Default.png", 320, 480), ("Default@2x.png", 640, 960), ("Default-568h@2x.png", 640, 1136),
                       ("Default-Portrait~ipad.png", 768, 1004), ("Default-Landscape~ipad.png", 1024, 748)]:
        png(os.path.join(OUT, name), w, h, solid(bg))
    print("đã tạo ảnh trong", os.path.normpath(OUT))


if __name__ == "__main__":
    main()
