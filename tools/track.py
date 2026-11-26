#!/usr/bin/env python3
"""Track rigid parts across the frames by template matching and print their motion as GLSL key tables.

  python tools/track.py <work folder> top:268,192,542,314 mid:238,346,584,498

Each box is taken from frame 1. For every frame it reports the best match's offset and scale; a low score means the
part is occluded or deforming there, so smooth those keys by hand.
"""
import re
import sys
from pathlib import Path

import numpy as np
from PIL import Image
from skimage.feature import match_template
from skimage.transform import rescale

sys.path.insert(0, str(Path(__file__).parent))
from common import box, open_png, refs, work  # noqa: E402

if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    d = work(sys.argv[1])
    fs = [np.asarray(open_png(p).convert("L")).astype(float) / 255 for p in refs(d)]
    H, W = fs[0].shape
    for spec in sys.argv[2:]:
        name, _, coords = spec.partition(":")
        if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_]*", name):
            sys.exit(f"{spec!r}: expected name:x0,y0,x1,y1 with a name made of letters, digits and _")
        x0, y0, x1, y1 = box(coords)
        t = fs[0][y0:y1, x0:x1]
        mx, my = max(40, (x1 - x0) // 3), max(60, (y1 - y0))
        rows = []
        for f in fs:
            best = (-1.0, 1.0, 0.0, 0.0)
            for sc in (0.88, 0.92, 0.96, 1.0, 1.04, 1.08, 1.12):
                ts = rescale(t, sc, anti_aliasing=True) if sc != 1 else t
                sy0, sy1, sx0, sx1 = max(0, y0 - my), min(H, y1 + my), max(0, x0 - mx), min(W, x1 + mx)
                if ts.shape[0] > sy1 - sy0 or ts.shape[1] > sx1 - sx0:
                    continue
                r = match_template(f[sy0:sy1, sx0:sx1], ts)
                k = np.unravel_index(r.argmax(), r.shape)
                if r.max() > best[0]:
                    best = (float(r.max()), sc, sx0 + k[1] + ts.shape[1] / 2 - (x0 + x1) / 2, sy0 + k[0] + ts.shape[0] / 2 - (y0 + y1) / 2)
            rows.append(best)
        print(f"// {name}: score " + " ".join(f"{r[0]:.2f}" for r in rows))
        up = name.upper()
        print(f"const float K_{up}_DX[NF] = float[NF](" + ", ".join(f"{r[2]:.1f}" for r in rows) + ");")
        print(f"const float K_{up}_DY[NF] = float[NF](" + ", ".join(f"{r[3]:.1f}" for r in rows) + ");")
        print(f"const float K_{up}_SC[NF] = float[NF](" + ", ".join(f"{r[1]:.2f}" for r in rows) + ");")
