"""两个变体的应用图标：在 Strata 的图标上把中间那条横杠换成厂商的标志色，下方加厂商名，飞牛桌面上一眼能分清。

    python make_icon.py <source icon-512.png> <cuda|gfx906> <out-64.png> <out-256.png> [more outputs: <size>:<path> ...]

源图：深色底、三条横杠，中间一条是 Strata 的绿色。只替换那条横杠的颜色（按色相挑出绿色像素，保留抗锯齿边缘的明暗），
再在横杠下方居中写厂商名。用 Pillow（Strata 的 Control 里自带）。
"""
import colorsys
import sys

from PIL import Image, ImageDraw, ImageFont

VARIANTS = {
    "cuda": {"color": (118, 185, 0), "label": "NVIDIA"},     # NVIDIA 绿
    "gfx906": {"color": (237, 28, 36), "label": "AMD"},      # AMD 红
}


def make(src: str, variant: str) -> Image.Image:
    v = VARIANTS[variant]
    im = Image.open(src).convert("RGBA").resize((512, 512), Image.LANCZOS)
    px = im.load()
    tr, tg, tb = v["color"]
    th, tl, ts = colorsys.rgb_to_hls(tr / 255, tg / 255, tb / 255)
    for y in range(512):
        for x in range(512):
            r, g, b, a = px[x, y]
            h, l, s = colorsys.rgb_to_hls(r / 255, g / 255, b / 255)
            if s > 0.35 and 0.35 < h < 0.55:         # Strata 的绿（青绿）：换成厂商色，按原来的亮度比例保留边缘过渡
                k = min(1.0, l / 0.52)
                nr, ng, nb = colorsys.hls_to_rgb(th, tl * k, ts)
                px[x, y] = (round(nr * 255), round(ng * 255), round(nb * 255), a)
    # 三条横杠整体上移一点，给下面的厂商名腾地方
    shifted = Image.new("RGBA", im.size, px[5, 5])
    shifted.paste(im.crop((0, 40, 512, 512)), (0, 0))
    draw = ImageDraw.Draw(shifted)
    size = 92 if len(v["label"]) <= 3 else 74
    try:
        font = ImageFont.load_default(size=size)
    except TypeError:                                  # 很老的 Pillow：没有可缩放的默认字体
        font = ImageFont.load_default()
    box = draw.textbbox((0, 0), v["label"], font=font, stroke_width=1)
    w, h = box[2] - box[0], box[3] - box[1]
    draw.text(((512 - w) / 2 - box[0], 392 - box[1]), v["label"], font=font, fill=v["color"] + (255,),
              stroke_width=1, stroke_fill=v["color"] + (255,))
    return shifted


def main(argv):
    src, variant, *outs = argv
    big = make(src, variant)
    defaults = [(64, outs[0]), (256, outs[1])] if len(outs) >= 2 and ":" not in outs[0] else []
    extra = [(int(o.split(":", 1)[0]), o.split(":", 1)[1]) for o in outs if ":" in o]
    for size, path in defaults + extra:
        big.resize((size, size), Image.LANCZOS).save(path)


if __name__ == "__main__":
    main(sys.argv[1:])
