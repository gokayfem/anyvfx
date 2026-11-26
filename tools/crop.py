#!/usr/bin/env python3
"""Reference | render crop, zoomed. The main instrument for painting a landmark.

  python tools/crop.py <work folder> <frame> x0,y0,x1,y1 [zoom]     -> out/crop.png

Crop coordinates are reference pixels; positions read off the crop map back linearly (divide by the zoom, add x0,y0).
"""
import sys
from pathlib import Path

from PIL import Image

sys.path.insert(0, str(Path(__file__).parent))
from common import box, open_png, out_frame, ref_frame, save_image, work  # noqa: E402

if __name__ == "__main__":
    if len(sys.argv) not in (4, 5):
        sys.exit(__doc__)
    try:
        d, f, b = work(sys.argv[1]), int(sys.argv[2]), box(sys.argv[3])
        z = float(sys.argv[4]) if len(sys.argv) == 5 else 2.0
    except ValueError:
        sys.exit(__doc__)
    if not 0.1 <= z <= 16:
        sys.exit("zoom: between 0.1 and 16")
    ref = open_png(ref_frame(d, f))
    out = open_png(out_frame(d, f)).resize(ref.size, Image.LANCZOS)
    w, h = max(int((b[2] - b[0]) * z), 1), max(int((b[3] - b[1]) * z), 1)
    if w > 8192 or h > 8192:
        sys.exit("the zoomed crop would be larger than 8192 px; use a smaller box or zoom")
    s = Image.new("RGB", (w * 2 + 6, h), (255, 0, 255))
    s.paste(ref.crop(b).resize((w, h), Image.LANCZOS), (0, 0))
    s.paste(out.crop(b).resize((w, h), Image.LANCZOS), (w + 6, 0))
    save_image(s, d / "out" / "crop.png")
    print("wrote", d / "out" / "crop.png")
