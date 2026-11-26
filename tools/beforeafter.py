#!/usr/bin/env python3
"""Reference | before | after for one frame.

  python tools/beforeafter.py <work folder> <frame>     -> out/before_after_<frame>.png

'before' is that frame of baseline/shader.gif (made by tools/baseline.py); 'after' is that frame of shader.gif.
"""
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageSequence

sys.path.insert(0, str(Path(__file__).parent))
from common import MAX_FRAMES, open_png, ref_frame, save_image, work  # noqa: E402


def frame_of(gif: Path, f: int, size):
    if not gif.is_file():
        sys.exit(f"{gif}: missing; run tools/baseline.py before the rework and tools/finish.py after it")
    try:
        im = Image.open(gif, formats=["GIF"])
    except Exception as e:                                                # PIL raises several unrelated types here
        sys.exit(f"{gif}: not a readable GIF ({e.__class__.__name__})")
    n = getattr(im, "n_frames", 1)
    if not 1 <= f <= min(n, MAX_FRAMES):
        sys.exit(f"{gif}: has {n} frames, no frame {f}")
    return ImageSequence.Iterator(im)[f - 1].convert("RGB").resize(size)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    try:
        d, f = work(sys.argv[1]), int(sys.argv[2])
    except ValueError:
        sys.exit(__doc__)
    ref = open_png(ref_frame(d, f))
    ims = [("reference", ref), ("before", frame_of(d / "baseline" / "shader.gif", f, ref.size)),
           ("after", frame_of(d / "shader.gif", f, ref.size))]
    w = 520
    h = max(w * ref.height // ref.width, 1)
    s = Image.new("RGB", (w * 3 + 16, h), (16, 12, 28))
    for k, (name, im) in enumerate(ims):
        t = im.resize((w, h), Image.LANCZOS)
        ImageDraw.Draw(t).text((8, 6), name, fill=(255, 255, 255))
        s.paste(t, (k * (w + 8), 0))
    (d / "out").mkdir(exist_ok=True)
    p = d / "out" / f"before_after_{f}.png"
    save_image(s, p)
    print("wrote", p)
