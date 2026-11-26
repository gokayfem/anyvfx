#!/usr/bin/env python3
"""Keep the published state of a work folder before reworking it, so a real before/after can be shown afterwards.

  python tools/baseline.py <work folder>
  ... rework, then tools/finish.py ...
  python tools/beforeafter.py <work folder> <frame>

Copies compare.gif, shader.gif and every source the shader is built from into <folder>/baseline/. Refuses to
overwrite an existing baseline: remove it yourself if you mean to replace it.
"""
import shutil
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from common import work  # noqa: E402

FILES = ("compare.gif", "shader.gif", "shader.glsl", "lightmap.glsl", "meta.json",
         "scene/env.glsl", "scene/lightmap.glsl", "scene/meta.json")

if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    d = work(sys.argv[1])
    b = d / "baseline"
    if b.exists() or b.is_symlink():
        sys.exit(f"{b} exists; remove it first if you mean to replace it")
    if not (d / "shader.gif").is_file():
        sys.exit(f"{d / 'shader.gif'}: nothing published yet; run tools/finish.py {d} first")
    b.mkdir()
    for name in FILES:
        src = d / name
        if src.is_file():
            dst = b / name
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, dst)
            print("kept", dst)
