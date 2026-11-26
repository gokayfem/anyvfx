#!/usr/bin/env python3
"""The inner loop: build (assemble, bundle, lint, compile), render, print the error per frame.

  python tools/go.py <work folder>                         all frames
  python tools/go.py <work folder> --frames 1,6            just these (fast)
  python tools/go.py <work folder> --define DEBUG_MODE=2   override a #define for this render
  python tools/go.py <work folder> --tag _x                write to out_x/ instead of out/
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from build import build  # noqa: E402
from common import work  # noqa: E402
from render import parser, run  # noqa: E402

if __name__ == "__main__":
    a = parser(__doc__).parse_args()
    d = work(a.folder)
    build(d)
    run(d, a.frames, a.define, a.tag, a.size)
