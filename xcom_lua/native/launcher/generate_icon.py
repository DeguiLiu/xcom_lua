from pathlib import Path

from PIL import Image, ImageDraw


def draw_icon(size: int) -> Image.Image:
    scale = size / 256.0
    image = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)

    def box(values):
        return tuple(round(value * scale) for value in values)

    draw.rounded_rectangle(box((18, 18, 238, 238)), radius=round(46 * scale), fill="#152936")
    draw.rounded_rectangle(box((27, 27, 229, 229)), radius=round(38 * scale), outline="#0078B8", width=max(1, round(5 * scale)))
    draw.rounded_rectangle(box((55, 67, 201, 184)), radius=round(16 * scale), fill="#0078B8")
    draw.rounded_rectangle(box((73, 84, 183, 167)), radius=round(8 * scale), fill="#EAF4F8")
    draw.line((round(84 * scale), round(126 * scale), round(111 * scale), round(126 * scale)), fill="#152936", width=max(1, round(8 * scale)))
    draw.line((round(111 * scale), round(126 * scale), round(127 * scale), round(105 * scale)), fill="#152936", width=max(1, round(8 * scale)))
    draw.line((round(127 * scale), round(105 * scale), round(145 * scale), round(147 * scale)), fill="#152936", width=max(1, round(8 * scale)))
    draw.line((round(145 * scale), round(147 * scale), round(172 * scale), round(147 * scale)), fill="#152936", width=max(1, round(8 * scale)))
    draw.line((round(92 * scale), round(196 * scale), round(164 * scale), round(196 * scale)), fill="#EAF4F8", width=max(1, round(7 * scale)))
    draw.line((round(128 * scale), round(184 * scale), round(128 * scale), round(216 * scale)), fill="#EAF4F8", width=max(1, round(7 * scale)))
    return image


if __name__ == "__main__":
    output = Path(__file__).with_name("xcom.ico")
    draw_icon(256).save(output, format="ICO", sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])
