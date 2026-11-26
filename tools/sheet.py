#!/usr/bin/env python3
"""Reference row over render row for chosen frames.

  python tools/sheet.py <work folder> 1,4,6 <name> [x0,y0,x1,y1]     -> out/<name>.png
"""
import re
import sys
from pathlib import Path

from PIL import Image

sys.path.insert(0, str(Path(__file__).parent))
from common import box, frame_list, open_png, out_frame, ref_frame, refs, save_image, work  # noqa: E402


def sheet(d: Path, ids, name: str, crop=None) -> Path:
    if not re.fullmatch(r"[A-Za-z0-9_-]+", name):
        sys.exit(f"{name!r}: the sheet name may hold letters, digits, - and _ only")
    first = open_png(ref_frame(d, ids[0]))
    crop = crop or (0, 0, first.width, first.height)
    w, h = crop[2] - crop[0], crop[3] - crop[1]
    s = Image.new("RGB", (w * len(ids), h * 2))
    for k, i in enumerate(ids):
        ref = open_png(ref_frame(d, i))
        out = open_png(out_frame(d, i)).resize(ref.size, Image.LANCZOS)
        s.paste(ref.crop(crop), (w * k, 0))
        s.paste(out.crop(crop), (w * k, h))
    z = min(1.0, 1560 / s.width)
    p = d / "out" / f"{name}.png"
    save_image(s.resize((max(int(s.width * z), 1), max(int(s.height * z), 1)), Image.LANCZOS), p)
    return p


if __name__ == "__main__":
    if len(sys.argv) not in (4, 5):
        sys.exit(__doc__)
    d = work(sys.argv[1])
    print("wrote", sheet(d, frame_list(sys.argv[2], len(refs(d))), sys.argv[3], box(sys.argv[4]) if len(sys.argv) == 5 else None))
