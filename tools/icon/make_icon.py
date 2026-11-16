"""Biểu tượng GramMini (D23): đĩa tròn bóng kiểu iOS 6, nền loang màu như hình nền app, chữ G trắng cách điệu thành bong bóng
chat (đuôi ở góc dưới trái), vòng kính trong suốt bao ngoài. Vẽ ở 1024 rồi thu nhỏ (khử răng cưa)."""
import math
import sys
from PIL import Image, ImageChops, ImageDraw, ImageFilter

S = 1024
C = S / 2
R_OUT = S * 0.49          # mép ngoài vòng kính
R_DISC = S * 0.415        # đĩa màu bên trong
RG = R_DISC * 0.5         # bán kính tâm nét chữ G
W = R_DISC * 0.19         # bề dày nét


def circle_mask(r, blur=0):
    m = Image.new("L", (S, S), 0)
    ImageDraw.Draw(m).ellipse((C - r, C - r, C + r, C + r), fill=255)
    return m.filter(ImageFilter.GaussianBlur(blur)) if blur else m


def vgrad(top, bottom):
    """Ảnh RGBA dải màu dọc."""
    g = Image.linear_gradient("L").resize((S, S))
    a = Image.new("RGBA", (S, S), top)
    b = Image.new("RGBA", (S, S), bottom)
    return Image.composite(b, a, g)


def scale_mask(m, k):
    return m.point(lambda v: int(v * k))


def blob(img, cx, cy, rad, color, alpha):
    """Vùng màu loang tròn (đậm ở tâm, nhạt dần)."""
    g = Image.radial_gradient("L").resize((int(rad * 2), int(rad * 2)))
    # radial_gradient: 0 ở tâm, 181 ở mép vòng tròn nội tiếp (255 ở góc) → về 0 đúng ở mép, mượt dần (bình phương)
    g = g.point(lambda v: int(255 * alpha * max(0.0, 1 - v / 181.0) ** 1.6))
    layer = Image.new("RGBA", g.size, color)
    tmp = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    tmp.paste(layer, (int(cx - rad), int(cy - rad)), g)
    return Image.alpha_composite(img, tmp)


def glyph_mask():
    """Chữ G: cung ~310° hở góc trên phải, thanh ngang vào giữa, đầu tròn, đuôi bong bóng ở góc dưới trái."""
    m = Image.new("L", (S, S), 0)
    d = ImageDraw.Draw(m)
    box = (C - RG - W / 2, C - RG - W / 2, C + RG + W / 2, C + RG + W / 2)
    d.arc(box, 0, 312, fill=255, width=int(W))
    # Đầu tròn ở mút trên phải
    a = math.radians(312)
    x, y = C + RG * math.cos(a), C + RG * math.sin(a)
    d.ellipse((x - W / 2, y - W / 2, x + W / 2, y + W / 2), fill=255)
    # Thanh ngang: từ mép phải vào gần tâm
    d.rectangle((C + RG * 0.08, C - W / 2, C + RG + W / 2, C + W / 2), fill=255)
    # Đuôi bong bóng
    def pt(deg, r):
        t = math.radians(deg)
        return (C + r * math.cos(t), C + r * math.sin(t))
    d.polygon([pt(112, RG), pt(150, RG), pt(138, RG + W * 2.1)], fill=255)
    return m


def make():
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))

    # Vòng kính trong suốt: trắng mờ, sáng ở trên, nhạt dần xuống dưới
    ring = scale_mask(ImageChops.subtract(circle_mask(R_OUT), circle_mask(R_DISC)), 1)
    glass = vgrad((255, 255, 255, 150), (210, 230, 250, 60))
    img.paste(glass, (0, 0), ImageChops.multiply(ring, glass.getchannel("A")))
    # viền sáng mép ngoài (nửa trên đậm hơn)
    edge = ImageChops.subtract(circle_mask(R_OUT), circle_mask(R_OUT - S * 0.006))
    edge_col = vgrad((255, 255, 255, 230), (255, 255, 255, 40))
    img = Image.alpha_composite(img, Image.composite(edge_col, Image.new("RGBA", (S, S), (0, 0, 0, 0)), edge))
    # viền tối mảnh quanh đĩa (tách đĩa khỏi kính)
    rim = ImageChops.subtract(circle_mask(R_DISC + S * 0.007), circle_mask(R_DISC))
    img = Image.alpha_composite(img, Image.composite(Image.new("RGBA", (S, S), (20, 50, 90, 120)),
                                                     Image.new("RGBA", (S, S), (0, 0, 0, 0)), rim))

    # Đĩa: xanh bóng + vùng màu loang như hình nền app
    disc = vgrad((112, 190, 255, 255), (22, 88, 176, 255))
    disc = blob(disc, C - R_DISC * 0.55, C - R_DISC * 0.6, R_DISC * 0.9, (255, 196, 120, 255), 0.8)
    disc = blob(disc, C + R_DISC * 0.7, C - R_DISC * 0.5, R_DISC * 0.8, (196, 170, 255, 255), 0.6)
    disc = blob(disc, C - R_DISC * 0.6, C + R_DISC * 0.65, R_DISC * 0.9, (80, 225, 185, 255), 0.75)
    # tối dần ở đáy đĩa
    shade = vgrad((0, 0, 0, 0), (0, 20, 60, 110))
    disc = Image.alpha_composite(disc, shade)
    dmask = circle_mask(R_DISC)
    img.paste(disc, (0, 0), dmask)

    # Chữ G: bóng đổ mờ + mặt trắng hơi xanh ở đáy
    g = glyph_mask()
    shadow = g.filter(ImageFilter.GaussianBlur(S * 0.012)).point(lambda v: int(v * 0.45))
    sh = Image.new("RGBA", (S, S), (0, 25, 70, 255))
    tmp = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    tmp.paste(sh, (0, int(S * 0.012)), shadow)
    img = Image.alpha_composite(img, Image.composite(tmp, Image.new("RGBA", (S, S), (0, 0, 0, 0)), dmask))
    face = vgrad((255, 255, 255, 255), (222, 236, 252, 255))
    img.paste(face, (0, 0), g)

    # Vệt bóng iOS 6: elip sáng nửa trên đĩa
    gl = Image.new("L", (S, S), 0)
    ImageDraw.Draw(gl).ellipse((C - R_DISC * 0.92, C - R_DISC * 1.02, C + R_DISC * 0.92, C + R_DISC * 0.05), fill=255)
    gl = ImageChops.multiply(gl.filter(ImageFilter.GaussianBlur(S * 0.004)), dmask)
    gloss = vgrad((255, 255, 255, 140), (255, 255, 255, 8))
    img = Image.alpha_composite(img, Image.composite(gloss, Image.new("RGBA", (S, S), (0, 0, 0, 0)), gl))
    return img


if __name__ == "__main__":
    out = sys.argv[1]
    big = make()
    big.save(out + "/icon-1024.png")
    sizes = {"Icon.png": 57, "Icon@2x.png": 114, "Icon-72.png": 72, "Icon-72@2x.png": 144, "Icon-Small.png": 29,
             "Icon-Small@2x.png": 58, "Icon-Small-50.png": 50, "Icon-Small-50@2x.png": 100}
    for name, px in sizes.items():
        big.resize((px, px), Image.LANCZOS).save(out + "/" + name)
    print("ok")
