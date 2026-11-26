#!/usr/bin/env python3
"""Start a clip: take a GIF, extract its frames, measure everything that can be measured without looking, and drop
in the shader scaffold.

  python tools/new.py <work folder> <path to a .gif | https:// URL of a .gif> [--name "Title"]

Writes into the work folder (created if missing):
  source.gif, ref/fNN.png, meta.json
  shader.glsl          the scaffold for the effect; it compiles as written
  scene/               the static scene, painted alone: shader.glsl (harness), env.glsl (stub), meta.json
  analysis/
    sheet.png          all frames, small                      -> what happens, in what order
    grid_a.png ...     frames at full size with pixel rulers  -> read positions off these
    change.png         per-pixel temporal range               -> what moves, what is static
    ANALYSIS.md        timing, per-frame exposure key, drift of static areas, loop seam, palette, block colours of
                       frame 1, vertical colour ramps, bounding box of the animated region

Existing shader files are never overwritten: running it again only refreshes frames, meta.json and analysis/.
Downloads are https only, capped at 64 MB, and must be GIF files. Frames are decoded by Pillow's GIF reader alone.
"""
import argparse
import json
import re
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageSequence

sys.path.insert(0, str(Path(__file__).parent))
from common import MAX_FRAMES, MAX_PIXELS, MAX_SIZE, ROOT, no_links, save_image, write_bytes, write_text  # noqa: E402

MAX_BYTES = 64 * 1024 * 1024
DOWNLOAD_SECONDS = 120
STUB = ("// Static scene. Returns linear colour before the light map. Stub until the scene is painted.\n"
        "vec3 environment(vec2 P, float px) {\n"
        "    return mix(rgb(40.0, 40.0, 60.0), rgb(90.0, 90.0, 120.0), ramp(0.0, REF, P.y));\n}\n")


class HttpsOnly(urllib.request.HTTPRedirectHandler):
    """Follow redirects only to other https URLs."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if not newurl.lower().startswith("https://"):
            raise urllib.error.HTTPError(newurl, code, "redirect to a non-https URL refused", headers, fp)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def check_gif(data: bytes, what: str) -> bytes:
    if len(data) > MAX_BYTES:
        sys.exit(f"{what}: larger than {MAX_BYTES // 2 ** 20} MB")
    if data[:6] not in (b"GIF87a", b"GIF89a"):
        sys.exit(f"{what}: not a GIF file (convert other formats to GIF first)")
    return data


def read_source(source: str) -> bytes:
    """The bytes of a local GIF, or of one downloaded over https. Refuses anything that is not a GIF."""
    if re.match(r"^[a-zA-Z][a-zA-Z0-9+.-]*://", source):
        if not source.lower().startswith("https://"):
            sys.exit("only https:// URLs are downloaded; save the file yourself and pass its path instead")
        opener = urllib.request.build_opener(HttpsOnly)
        deadline = time.monotonic() + DOWNLOAD_SECONDS
        chunks, size = [], 0
        try:
            with opener.open(urllib.request.Request(source, headers={"User-Agent": "anyvfx"}), timeout=30) as r:
                while True:
                    chunk = r.read(1 << 16)
                    if not chunk:
                        break
                    size += len(chunk)
                    if size > MAX_BYTES:
                        sys.exit(f"download refused: larger than {MAX_BYTES // 2 ** 20} MB")
                    if time.monotonic() > deadline:
                        sys.exit(f"download refused: took longer than {DOWNLOAD_SECONDS} s")
                    chunks.append(chunk)
        except (urllib.error.URLError, TimeoutError, ValueError, OSError) as e:
            sys.exit(f"download failed: {e}")
        return check_gif(b"".join(chunks), "the download")
    p = Path(source).expanduser()
    if not p.is_file():
        sys.exit(f"{source}: no such file")
    if p.stat().st_size > MAX_BYTES:
        sys.exit(f"{source}: larger than {MAX_BYTES // 2 ** 20} MB")
    return check_gif(p.read_bytes(), source)


def fetch(source: str, dest: Path) -> None:
    """Validate the clip, then write it. Nothing is written unless it is a GIF within the size limit."""
    write_bytes(dest, read_source(source))


def decode(gif: Path):
    """Frames of a GIF as RGB images, and its frame time in seconds. Only Pillow's GIF reader is offered the file,
    and the frame count, frame size and total pixel count are checked before anything is decoded."""
    if gif.stat().st_size > MAX_BYTES:
        sys.exit(f"{gif}: larger than {MAX_BYTES // 2 ** 20} MB")
    with open(gif, "rb") as fh:
        check_gif(fh.read(6), str(gif))
    try:
        im = Image.open(gif, formats=["GIF"])
        count, (W, H) = getattr(im, "n_frames", 1), im.size
    except Exception as e:                                                # PIL raises several unrelated types here
        sys.exit(f"{gif}: not a readable GIF ({e.__class__.__name__})")
    if not (1 <= count <= MAX_FRAMES and 16 <= W <= MAX_SIZE and 16 <= H <= MAX_SIZE and count * W * H <= MAX_PIXELS):
        sys.exit(f"{gif}: {count} frames at {W} x {H}. The limits are {MAX_FRAMES} frames, 16..{MAX_SIZE} px a side, "
                 f"and {MAX_PIXELS // 10 ** 6} million pixels in total (frames x width x height).")
    frames, durs = [], []
    try:
        for fr in ImageSequence.Iterator(im):
            durs.append(fr.info.get("duration", 0))
            frames.append(fr.convert("RGB"))
            if len(frames) > count:
                break
    except Exception as e:
        sys.exit(f"{gif}: could not be decoded ({e.__class__.__name__})")
    if len(frames) != count:
        sys.exit(f"{gif}: decoded {len(frames)} frames, expected {count}")
    ms = float(np.median([d for d in durs if isinstance(d, (int, float)) and d > 0] or [120]))
    return frames, min(max(round(ms / 1000.0, 4), 0.001), 10.0)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("folder", help="work folder to create or refresh")
    ap.add_argument("source", nargs="?", help="GIF path or https URL (omit to reuse <folder>/source.gif)")
    ap.add_argument("--name", default="", help="title for the shader header (default: the folder name)")
    a = ap.parse_args()

    d = Path(a.folder)
    title = re.sub(r"[^\w .,'()-]", "", a.name or d.resolve().name).strip() or "Clip"
    if d.exists():
        if not d.is_dir():
            sys.exit(f"{d}: exists and is not a folder")
        no_links(d)
    gif = d / "source.gif"
    data = read_source(a.source) if a.source else None            # validated before anything is created
    if data is None and not gif.is_file():
        sys.exit(f"{gif}: missing; pass a GIF path or an https URL")
    (d / "ref").mkdir(parents=True, exist_ok=True)
    (d / "analysis").mkdir(exist_ok=True)
    if data is not None:
        write_bytes(gif, data)

    # ---- frames and timing ----
    frames, dt = decode(gif)
    N, W, H = len(frames), frames[0].width, frames[0].height
    if W != H:
        print(f"warning: the clip is {W} x {H}. The tools render square frames and were only tested on square "
              "clips; crop it square first for a like-for-like comparison.")
    for p in (d / "ref").glob("f*.png"):
        p.unlink()
    for i, f in enumerate(frames):
        save_image(f, d / "ref" / f"f{i + 1:02d}.png")
    A = np.stack([np.asarray(f).astype(np.float32) for f in frames])     # N, H, W, 3

    mp = d / "meta.json"
    try:
        m = json.loads(mp.read_text()) if mp.is_file() else {}
    except ValueError:
        m = {}
    m = m if isinstance(m, dict) else {}
    m.update({"source": "source.gif", "size": H, "width": W, "frames": N, "dt": dt})
    write_text(mp, json.dumps(m, indent=2) + "\n")

    # ---- pictures ----
    cols = 4
    tw = 1560 // cols
    th = tw * H // W
    sheet = Image.new("RGB", (tw * cols, th * ((N + cols - 1) // cols)))
    for i, f in enumerate(frames):
        t = f.resize((tw, th), Image.LANCZOS)
        ImageDraw.Draw(t).text((6, 4), f"f{i + 1:02d}  {i * dt:.2f}s", fill=(0, 255, 0))
        sheet.paste(t, ((i % cols) * tw, (i // cols) * th))
    save_image(sheet, d / "analysis" / "sheet.png")

    for p in (d / "analysis").glob("grid_*.png"):
        p.unlink()
    for k in range(0, N, 4):                                              # 2x2 full-size sheets with rulers
        g = Image.new("RGB", (W * 2, H * 2))
        for j, i in enumerate(range(k, min(k + 4, N))):
            c = frames[i].copy()
            dr = ImageDraw.Draw(c)
            for v in range(100, max(W, H), 100):
                dr.line([(0, v), (10, v)], fill=(0, 255, 0))
                dr.text((12, v - 5), str(v), fill=(0, 255, 0))
                dr.line([(v, 0), (v, 10)], fill=(0, 255, 0))
                dr.text((v - 9, 12), str(v), fill=(0, 255, 0))
            dr.text((W - 40, 4), f"f{i + 1:02d}", fill=(0, 255, 0))
            g.paste(c, ((j % 2) * W, (j // 2) * H))
        save_image(g, d / "analysis" / f"grid_{k // 4 + 1:02d}.png")

    lum = A.mean(3)
    rng = lum.max(0) - lum.min(0)                                         # temporal range per pixel
    save_image(Image.fromarray(np.clip(rng * 2, 0, 255).astype(np.uint8)), d / "analysis" / "change.png")

    # ---- numbers ----
    out = [f"# {title}: analysis", "", f"- {W}x{H}, {N} frames, {dt} s per frame, loop {N * dt:.2f} s", ""]
    means = A.mean((1, 2))
    diff1 = np.abs(A - A[0]).mean((1, 2, 3))
    key = (means.mean(1) - means.mean(1).min()) / max(np.ptp(means.mean(1)), 1e-6)
    out += ["## Per frame", "", "| frame | t | mean RGB | MAE vs f01 | exposure key 0..1 |", "|---|---|---|---|---|"]
    for i in range(N):
        out.append(f"| {i + 1:02d} | {i * dt:.2f} | {means[i].round(0).astype(int).tolist()} | {diff1[i]:.1f} | {key[i]:.2f} |")
    out += ["", "Exposure key as GLSL (starting point for the ambient envelope):", "",
            "`const float K_AMB[NF] = float[NF](" + ", ".join(f"{v:.2f}" for v in key) + ");`", ""]

    static = rng < np.percentile(rng, 35)
    drift = np.abs(A - np.median(A, 0)).mean(3)[:, static].mean() if static.any() else 0.0
    ys, xs = np.where(rng > max(60.0, np.percentile(rng, 90)))
    out += ["## Motion", "",
            f"- Loop seam: MAE f{N:02d} vs f01 = {np.abs(A[-1] - A[0]).mean():.1f} (0 would be a seamless loop)",
            f"- Drift of the calmest 35% of pixels: {drift:.1f} levels. This is the floor a static background can reach.",
            f"- Strongly animated region: x {xs.min()}..{xs.max()}, y {ys.min()}..{ys.max()}" if len(xs) else "- No strongly animated region.",
            f"- Peak-activity frame: f{int(diff1.argmax()) + 1:02d}", ""]

    q = frames[0].quantize(8, method=Image.Quantize.MEDIANCUT)
    pal = np.array(q.getpalette()[:24]).reshape(8, 3)
    cnt = np.bincount(np.asarray(q).ravel(), minlength=8)
    out += ["## Palette of f01 (8 colours, by area)", ""]
    out += [f"- rgb({r}, {g}, {b})  {100 * c / cnt.sum():.0f}%" for (r, g, b), c in sorted(zip(pal.tolist(), cnt.tolist()), key=lambda t: -t[1])]

    out += ["", "## Vertical ramps of f01 (rgb at x = 12%, 50%, 88%)", "", "| y | left | centre | right |", "|---|---|---|---|"]
    B = np.asarray(frames[0]).astype(int)
    for y in range(0, H, max(H // 16, 1)):
        cells = []
        for fx in (0.12, 0.5, 0.88):
            x0 = max(int(W * fx) - 6, 0)
            cells.append(str(B[y:y + 6, x0:x0 + 12].reshape(-1, 3).mean(0).round().astype(int).tolist()))
        out.append(f"| {y} | " + " | ".join(cells) + " |")

    blk = 48
    if W >= blk and H >= blk:
        G = np.asarray(frames[0].resize((W // blk, H // blk), Image.BOX)).astype(int)
        out += ["", f"## Block means of f01 ({blk} px blocks, r,g,b)", "", "```", "       " + " ".join(f"{c * blk:11d}" for c in range(G.shape[1]))]
        out += [f"y{r * blk:4d}  " + " ".join("%3d,%3d,%3d" % tuple(G[r, c]) for c in range(G.shape[1])) for r in range(G.shape[0])]
        out += ["```", ""]
    write_text(d / "analysis" / "ANALYSIS.md", "\n".join(out))

    # ---- scaffold ----
    # shader.glsl holds the effect and includes the scene from scene/. scene/shader.glsl is the harness the scene is
    # painted in: the same template with the effect block cut out (locked camera, no effects). It borrows ../ref.
    t = (ROOT / "template" / "shader.glsl").read_text()
    t = t.replace("@NAME@", title).replace("@NF@", str(N)).replace("@DT@", f"{dt}").replace("@REF@", f"{float(H)}")
    t = t.replace("@K_AMB@", ", ".join(f"{v:.2f}" for v in key))
    sh = d / "shader.glsl"
    if not sh.exists():
        write_text(sh, re.sub(r"^//@effect-(begin|end)\n", "", t, flags=re.M).replace("@SCENE@", "scene/"))
    scene = d / "scene"
    scene.mkdir(exist_ok=True)
    if not (scene / "env.glsl").exists():
        write_text(scene / "env.glsl", STUB)
    if not (scene / "shader.glsl").exists():
        harness = re.sub(r"^//@effect-begin\n.*?^//@effect-end\n",
                         "    // HARNESS: locked camera, no effects. Only env.glsl is painted here.\n", t, flags=re.M | re.S)
        write_text(scene / "shader.glsl", harness.replace("@SCENE@", ""))
    if not (scene / "meta.json").exists():
        write_text(scene / "meta.json", json.dumps({"size": H, "width": W, "frames": N, "dt": dt}, indent=2) + "\n")
    print(f"{d}: {W}x{H}, {N} frames, dt {dt}. Read {d / 'analysis' / 'ANALYSIS.md'} and analysis/sheet.png first.")
    print(f"Effect: {sh}. Scene, painted alone: {scene}/env.glsl (python tools/go.py {scene}; python tools/refit.py {scene}).")


if __name__ == "__main__":
    main()
