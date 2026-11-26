#!/usr/bin/env python3
"""Refit the painted light map after the layers under it changed, then rebuild and report the error.

  python tools/refit.py <work folder>/scene     the usual case: the static scene, painted alone
  python tools/refit.py <work folder>           a shader that keeps its light map beside it (examples 01-03)

Renders the calm frame named in meta.json ("lightmap": {"frame": N}, default 1) with LIGHTMAP=0, fits the gains,
writes lightmap.glsl in that folder and rebuilds. The shader needs a `#define LIGHTMAP 1` line.
"""
import shutil
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from build import build  # noqa: E402
from common import work  # noqa: E402
from fitmap import fit, spec_of  # noqa: E402
from render import run  # noqa: E402

if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    d = work(sys.argv[1])
    frame = spec_of(d)["frame"]
    build(d, quiet=True)
    run(d, str(frame), ["LIGHTMAP=0"], "_nolm")
    tmp = d / "out_nolm"
    try:
        fit(d, tmp / f"f{frame:02d}.png")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    build(d)
    run(d)
