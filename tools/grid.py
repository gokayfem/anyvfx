#!/usr/bin/env python3
"""Signed error per block (render minus reference, mean of RGB): where the render is too bright or too dark.

  python tools/grid.py <work folder> <frame> [block px, default 48]
"""
import sys
from pathlib import Path

import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).parent))
from common import open_png, out_frame, ref_frame, work  # noqa: E402

if __name__ == "__main__":
    if len(sys.argv) not in (3, 4):
        sys.exit(__doc__)
    try:
        d, f = work(sys.argv[1]), int(sys.argv[2])
        blk = int(sys.argv[3]) if len(sys.argv) == 4 else 48
    except ValueError:
        sys.exit(__doc__)
    ref = open_png(ref_frame(d, f))
    if not 4 <= blk <= min(ref.size):
        sys.exit(f"block: between 4 and {min(ref.size)}")
    out = open_png(out_frame(d, f)).resize(ref.size, Image.LANCZOS)
    nx, ny = ref.width // blk, ref.height // blk
    a = np.asarray(ref.resize((nx, ny), Image.BOX)).astype(int)
    b = np.asarray(out.resize((nx, ny), Image.BOX)).astype(int)
    print("render - reference (mean of RGB), rows = y, cols = x, block", blk)
    print("      " + " ".join(f"{c * blk:4d}" for c in range(nx)))
    for r in range(ny):
        print(f"y{r * blk:4d} " + " ".join(f"{int((b[r, c] - a[r, c]).mean()):4d}" for c in range(nx)))
