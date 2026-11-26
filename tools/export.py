#!/usr/bin/env python3
"""Export a shader's loop as a GIF at the reference timing, plus a reference | shader comparison GIF.

  python tools/export.py <work folder>     -> shader.gif, compare.gif
"""
import sys
from pathlib import Path

from PIL import Image

sys.path.insert(0, str(Path(__file__).parent))
from common import meta, open_png, refs, save_image, work  # noqa: E402
from render import render  # noqa: E402


def export(d: Path) -> None:
    m = meta(d)
    ms = round(m["dt"] * 1000)
    bundled = d / "shader.out.glsl"
    if not bundled.is_file():
        sys.exit(f"{bundled}: not built; run tools/go.py {d}")
    ref_imgs = [open_png(p) for p in refs(d)]
    imgs, _ = render(bundled.read_text(), m["size"], [i * m["dt"] for i in range(len(ref_imgs))])
    save_image(imgs[0], d / "shader.gif", save_all=True, append_images=imgs[1:], duration=ms, loop=0)
    pairs = []
    for r, o in zip(ref_imgs, imgs):
        s = Image.new("RGB", (r.width * 2 + 8, r.height), (16, 12, 28))
        s.paste(r, (0, 0))
        s.paste(o.resize(r.size), (r.width + 8, 0))
        pairs.append(s)
    save_image(pairs[0], d / "compare.gif", save_all=True, append_images=pairs[1:], duration=ms, loop=0)
    print("wrote", d / "shader.gif", d / "compare.gif")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    export(work(sys.argv[1]))
