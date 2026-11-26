#!/usr/bin/env python3
"""Publish a pass: full render with the error per frame, a sheet of the frames, the GIFs and the viewer page.

  python tools/finish.py <work folder> [--open]

Writes out/all.png, shader.gif, compare.gif and compare.html. --open shows the viewer in the default browser.
"""
import argparse
import sys
import webbrowser
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from build import build  # noqa: E402
from build_viewer import page  # noqa: E402
from common import meta, refs, work, write_text  # noqa: E402
from export import export  # noqa: E402
from render import run  # noqa: E402
from sheet import sheet  # noqa: E402

if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("folder")
    ap.add_argument("--open", action="store_true", help="open compare.html when done")
    a = ap.parse_args()
    d = work(a.folder)
    build(d)
    run(d)
    n = len(refs(d))
    sheet(d, list(range(1, n + 1, max((n + 3) // 4, 1))), "all")
    export(d)
    viewer = d / "compare.html"
    write_text(viewer, page(d.resolve().name, (d / "shader.out.glsl").read_text(), meta(d)))
    print("wrote", viewer)
    if a.open:
        webbrowser.open(viewer.resolve().as_uri())
