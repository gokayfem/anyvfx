"""Shared helpers: locating things inside a work folder, metadata, colour conversion.

A work folder holds one clip and its shader:

    shader.glsl        the source you edit            shader.out.glsl   bundled, paste-ready (generated)
    meta.json          size, frame count, timing      source.gif        the reference clip
    ref/fNN.png        its frames                     out/              renders and comparison sheets (generated)
    scene/             the static scene, painted alone: shader.glsl (harness), env.glsl, lightmap.glsl, meta.json

`scene/` is itself a work folder that borrows the parent's reference frames.
"""
import json
import math
import os
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TESTED_SHADER_SKILLS = "a936077"       # the shader-skills commit the examples were last built against

MAX_SIZE = 4096                        # px per side the tools will render or read
MAX_FRAMES = 240
MAX_PIXELS = 64_000_000                # frames x width x height a clip may hold in total


def no_links(d: Path) -> None:
    """Exit if the folder holds a symbolic link anywhere inside it.

    The tools write into a work folder by name (shader.out.glsl, out/f01.png, ...). A link planted under one of
    those names in a folder that came from someone else would redirect the write to wherever it points.
    """
    for base, dirs, files in os.walk(d, followlinks=False):
        for name in dirs + files:
            p = Path(base) / name
            if p.is_symlink():
                sys.exit(f"{p}: is a link. Work folders must not contain links; remove it and run again.")


def work(arg) -> Path:
    """The work folder named on the command line. Exits if it is not a folder, or if it contains links."""
    d = Path(arg)
    if not d.is_dir():
        sys.exit(f"{arg}: not a folder")
    no_links(d)
    return d


def ref_dir(d: Path) -> Path:
    """Reference frames: the folder's own ref/, or the parent's when the folder is a scene harness."""
    for c in (d / "ref", d.parent / "ref"):
        if c.is_dir():
            if c.is_symlink():
                sys.exit(f"{c}: is a link; the reference frames must be a real folder")
            no_links(c)
            return c
    sys.exit(f"{d}: no ref/ folder here or in the parent; run tools/new.py first")


def refs(d: Path):
    r = sorted(ref_dir(d).glob("f*.png"))
    if not r:
        sys.exit(f"{ref_dir(d)}: no fNN.png frames")
    if len(r) > MAX_FRAMES:
        sys.exit(f"{ref_dir(d)}: {len(r)} frames; the limit is {MAX_FRAMES}")
    return r


def ref_frame(d: Path, f: int) -> Path:
    p = ref_dir(d) / f"f{f:02d}.png"
    if not p.is_file():
        sys.exit(f"{p}: no such reference frame")
    return p


def out_frame(d: Path, f: int) -> Path:
    p = d / "out" / f"f{f:02d}.png"
    if not p.is_file():
        sys.exit(f"{p}: not rendered yet; run tools/go.py {d} --frames {f}")
    return p


def open_png(path):
    """Open a frame as RGB. Only the PNG decoder is offered the file, whatever it claims to be."""
    from PIL import Image
    try:
        return Image.open(path, formats=["PNG"]).convert("RGB")
    except Exception as e:                                             # PIL raises several unrelated types here
        sys.exit(f"{path}: not a readable PNG ({e.__class__.__name__})")


def _replace_into(path: Path, write) -> None:
    """Write through a temporary file in the same folder, then move it into place. A link at `path` is replaced,
    never followed, and a failed write leaves the old file untouched."""
    path = Path(path)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=".tmp-", suffix=path.suffix)
    try:
        with os.fdopen(fd, "wb") as f:
            write(f)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def write_text(path, text: str) -> None:
    _replace_into(path, lambda f: f.write(text.encode("utf-8")))


def write_bytes(path, data: bytes) -> None:
    _replace_into(path, lambda f: f.write(data))


def save_image(im, path, **kw) -> None:
    """PIL save through _replace_into. The format comes from the file name."""
    fmt = {".png": "PNG", ".gif": "GIF", ".jpg": "JPEG", ".jpeg": "JPEG"}[Path(path).suffix.lower()]
    _replace_into(path, lambda f: im.save(f, format=fmt, **kw))


def meta(d: Path) -> dict:
    """meta.json of a work folder: size, frames, dt, and the optional light-map spec. Values are range-checked,
    because they size the render canvas and the number of frames drawn."""
    p = d / "meta.json"
    try:
        m = json.loads(p.read_text()) if p.is_file() else {}
    except (ValueError, OSError) as e:
        sys.exit(f"{p}: cannot be read as JSON ({e})")
    if not isinstance(m, dict):
        sys.exit(f"{p}: expected a JSON object")
    m.setdefault("size", 816)
    m.setdefault("frames", len(refs(d)))
    m.setdefault("dt", 0.12)
    try:
        size, frames, dt = int(m["size"]), int(m["frames"]), float(m["dt"])
    except (TypeError, ValueError):
        sys.exit(f"{p}: size and frames must be whole numbers and dt a number")
    if not (16 <= size <= MAX_SIZE and 1 <= frames <= MAX_FRAMES and math.isfinite(dt) and 0.001 <= dt <= 10.0):
        sys.exit(f"{p}: size must be 16..{MAX_SIZE}, frames 1..{MAX_FRAMES}, dt 0.001..10 s")
    m.update(size=size, frames=frames, dt=dt)
    return m


def lin(a):
    """sRGB 0..255 -> linear 0..1."""
    import numpy as np
    a = np.asarray(a, dtype=float) / 255.0
    return np.where(a <= 0.04045, a / 12.92, ((a + 0.055) / 1.055) ** 2.4)


def glsl_tools() -> Path:
    """shader-skills' bundler and checker. SHADER_SKILLS names the checkout; default is a sibling folder."""
    base = Path(os.environ.get("SHADER_SKILLS") or ROOT.parent / "shader-skills").expanduser()
    p = base / "skills" / "shader-art-coding" / "scripts" / "glsl_tools.py"
    if not p.is_file():
        sys.exit(f"shader-skills not found at {base}.\n"
                 "Clone https://github.com/gokayfem/shader-skills next to this repository, or set SHADER_SKILLS to\n"
                 "the path of a checkout. See README.md, Quick start.")
    return p


def frame_list(text: str, n: int):
    """'1,6,12' -> [1, 6, 12], checked against the number of reference frames; '' -> all."""
    if not text:
        return list(range(1, n + 1))
    try:
        idx = [int(x) for x in text.split(",")]
    except ValueError:
        sys.exit(f"--frames {text!r}: expected numbers separated by commas")
    bad = [i for i in idx if not 1 <= i <= n]
    if bad:
        sys.exit(f"--frames: {bad} outside 1..{n}")
    return idx


def box(text: str):
    """'x0,y0,x1,y1' -> a 4-tuple of ints with x1 > x0 and y1 > y0."""
    try:
        b = tuple(int(v) for v in text.split(","))
    except ValueError:
        b = ()
    if len(b) != 4 or b[2] <= b[0] or b[3] <= b[1]:
        sys.exit(f"{text!r}: expected x0,y0,x1,y1 with x1 > x0 and y1 > y0")
    return b
