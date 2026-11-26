#!/usr/bin/env python3
"""Print reference and render mean colours (7 x 7 px) at points. Type colours from this, never by eye.

  python tools/probe.py <work folder> <frame> "x,y x,y ..."
"""
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
from common import open_png, ref_frame, work  # noqa: E402

if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    try:
        d, f = work(sys.argv[1]), int(sys.argv[2])
    except ValueError:
        sys.exit(__doc__)
    a = np.asarray(open_png(ref_frame(d, f))).astype(float)
    rendered = d / "out" / f"f{f:02d}.png"
    b = (np.asarray(open_png(rendered).resize((a.shape[1], a.shape[0]))).astype(float)
         if rendered.is_file() else None)
    for p in sys.argv[3].split():
        try:
            x, y = (int(v) for v in p.split(","))
        except ValueError:
            sys.exit(f"{p!r}: expected x,y")
        if not (0 <= x < a.shape[1] and 0 <= y < a.shape[0]):
            sys.exit(f"({x},{y}) is outside the {a.shape[1]} x {a.shape[0]} frame")
        win = (slice(max(y - 3, 0), y + 4), slice(max(x - 3, 0), x + 4))
        ra = a[win].reshape(-1, 3).mean(0).round()
        rb = b[win].reshape(-1, 3).mean(0).round() if b is not None else "(not rendered)"
        print(f"({x:3d},{y:3d}) ref {ra} out {rb}")
