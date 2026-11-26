#!/usr/bin/env python3
"""Capture the LIVE shader at 60 fps as a video, for judging motion. A GIF at reference rate aliases anything fast
(particle flow, flicker, shake), so it cannot be used to judge those.

  python tools/capture.py <work folder> [loops, default 3]     -> live.mp4 (reference held per frame | shader at 60 fps)

Needs ffmpeg on the PATH. The loop must be 20 s or shorter.
"""
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image

sys.path.insert(0, str(Path(__file__).parent))
from common import meta, open_png, refs, work  # noqa: E402
from render import render  # noqa: E402

if __name__ == "__main__":
    if len(sys.argv) not in (2, 3):
        sys.exit(__doc__)
    d = work(sys.argv[1])
    try:
        loops = int(sys.argv[2]) if len(sys.argv) == 3 else 3
    except ValueError:
        sys.exit(__doc__)
    if not 1 <= loops <= 20:
        sys.exit("loops: between 1 and 20")
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        sys.exit("ffmpeg not found on the PATH")
    m = meta(d)
    fps, size = 60, 544
    n = round(m["frames"] * m["dt"] * fps)
    if not 1 <= n <= 20 * fps:
        sys.exit(f"the loop is {m['frames'] * m['dt']:.1f} s; capture.py handles loops up to 20 s")
    bundled = d / "shader.out.glsl"
    if not bundled.is_file():
        sys.exit(f"{bundled}: not built; run tools/go.py {d}")
    imgs, _ = render(bundled.read_text(), size, [i / fps for i in range(n)])
    ref_imgs = [open_png(p).resize((size, size), Image.LANCZOS) for p in refs(d)]
    with tempfile.TemporaryDirectory() as tmp:
        k = 0
        for _ in range(loops):
            for i, im in enumerate(imgs):
                s = Image.new("RGB", (size * 2 + 8, size), (16, 12, 28))
                s.paste(ref_imgs[min(int(i / fps / m["dt"]), len(ref_imgs) - 1)], (0, 0))
                s.paste(im, (size + 8, 0))
                s.save(Path(tmp) / f"{k:04d}.png")
                k += 1
        # frames are our own PNGs: only the image2 demuxer and local files are allowed. The video is written in the
        # temporary folder and then moved into place, so a link at live.mp4 is replaced, never followed.
        video = Path(tmp) / "live.mp4"
        subprocess.run([ffmpeg, "-v", "error", "-nostdin", "-y", "-protocol_whitelist", "file", "-f", "image2",
                        "-framerate", str(fps), "-i", str(Path(tmp) / "%04d.png"), "-pix_fmt", "yuv420p", "-crf", "16",
                        str(video)], check=True)
        fd, staged = tempfile.mkstemp(dir=d, prefix=".tmp-", suffix=".mp4")
        os.close(fd)
        try:
            shutil.copyfile(video, staged)
            os.replace(staged, d / "live.mp4")
        finally:
            if os.path.exists(staged):
                os.unlink(staged)
    print("wrote", d / "live.mp4", f"({k} frames at {fps} fps)")
