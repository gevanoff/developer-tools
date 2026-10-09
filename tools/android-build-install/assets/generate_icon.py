"""Render the geometric DroidRun icon. Requires Pillow; runtime does not."""
from pathlib import Path

from PIL import Image, ImageDraw


def render(size):
    scale = 4
    image = Image.new("RGBA", (size * scale, size * scale))
    draw = ImageDraw.Draw(image)
    unit = size * scale / 256

    def box(coords):
        return tuple(round(value * unit) for value in coords)

    # A solid bright tile, dark phone, and a single large play mark.
    draw.rounded_rectangle(box((8, 8, 248, 248)), radius=round(52 * unit), fill="#B8F526")
    draw.rounded_rectangle(box((66, 36, 190, 220)), radius=round(22 * unit), fill="#142238")
    draw.polygon([box(point) for point in ((105, 85), (105, 164), (160, 125))], fill="#B8F526")
    draw.rounded_rectangle(box((109, 193, 147, 201)), radius=round(4 * unit), fill="#B8F526")
    return image.resize((size, size), Image.Resampling.LANCZOS)


if __name__ == "__main__":
    root = Path(__file__).resolve().parent
    render(512).save(root / "droidrun-icon.png")
    sizes = (16, 20, 24, 32, 40, 48, 64, 128, 256)
    render(256).save(root / "droidrun.ico", sizes=[(size, size) for size in sizes],
                     append_images=[render(size) for size in sizes[:-1]])
