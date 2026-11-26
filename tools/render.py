#!/usr/bin/env python3
"""Render a bundled shader headless (WebGL2) at the reference frame times and compare it with the reference.

  python tools/render.py <work folder> [--frames 1,6] [--define DEBUG_MODE=2] [--tag _x] [--size 816]

Reads <folder>/shader.out.glsl (build it first, or use tools/go.py which does both). Writes <folder>/out/fNN.png and
out/sbs_NN.png (reference | render | abs diff x3) and prints the mean absolute error per frame, 0..255, at full
resolution and after an 8x box downsample.

The page is set from a string and the browser context is offline: nothing is fetched.
"""
import argparse
import base64
import io
import re
import sys
from pathlib import Path

import numpy as np
from PIL import Image
from playwright.sync_api import sync_playwright

sys.path.insert(0, str(Path(__file__).parent))
from common import MAX_SIZE, frame_list, meta, open_png, refs, save_image, work  # noqa: E402

PAGE = """<!doctype html><canvas id=c></canvas><script>
window.run = (src, w, h, times) => {
  const c = document.getElementById('c'); c.width = w; c.height = h;
  const gl = c.getContext('webgl2', {preserveDrawingBuffer: true, antialias: false, alpha: false});
  if (!gl) return {error: 'WebGL2 is not available in this browser'};
  const vs = gl.createShader(gl.VERTEX_SHADER);
  gl.shaderSource(vs, '#version 300 es\\nin vec2 p;void main(){gl_Position=vec4(p,0,1);}'); gl.compileShader(vs);
  const fs = gl.createShader(gl.FRAGMENT_SHADER);
  gl.shaderSource(fs, '#version 300 es\\nprecision highp float;precision highp int;uniform vec3 iResolution;uniform float iTime;uniform int iFrame;uniform vec4 iMouse;out vec4 _o;\\n#line 1\\n' + src + '\\nvoid main(){vec4 c=vec4(0);mainImage(c,gl_FragCoord.xy);_o=vec4(c.rgb,1.0);}');
  gl.compileShader(fs);
  if (!gl.getShaderParameter(fs, gl.COMPILE_STATUS)) return {error: gl.getShaderInfoLog(fs)};
  const pr = gl.createProgram(); gl.attachShader(pr, vs); gl.attachShader(pr, fs); gl.linkProgram(pr);
  if (!gl.getProgramParameter(pr, gl.LINK_STATUS)) return {error: gl.getProgramInfoLog(pr)};
  gl.useProgram(pr);
  const b = gl.createBuffer(); gl.bindBuffer(gl.ARRAY_BUFFER, b);
  gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1,-1,3,-1,-1,3]), gl.STATIC_DRAW);
  const loc = gl.getAttribLocation(pr, 'p'); gl.enableVertexAttribArray(loc); gl.vertexAttribPointer(loc, 2, gl.FLOAT, false, 0, 0);
  gl.viewport(0, 0, w, h);
  gl.uniform3f(gl.getUniformLocation(pr, 'iResolution'), w, h, 1);
  const out = [], ms = [];
  times.forEach((t, i) => {
    gl.uniform1f(gl.getUniformLocation(pr, 'iTime'), t);
    gl.uniform1i(gl.getUniformLocation(pr, 'iFrame'), i);
    const t0 = performance.now();
    gl.drawArrays(gl.TRIANGLES, 0, 3); gl.finish();
    const px = new Uint8Array(4); gl.readPixels(0, 0, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, px);
    ms.push(performance.now() - t0);
    out.push(c.toDataURL('image/png'));
  });
  const dbg = gl.getExtension('WEBGL_debug_renderer_info');
  return {frames: out, ms, renderer: dbg ? gl.getParameter(dbg.UNMASKED_RENDERER_WEBGL) : ''};
};
</script>"""

# macOS uses the GPU through ANGLE/Metal (this is what the examples were measured on). Elsewhere Chromium's software
# renderer is requested; that path is untested.
CHROMIUM_ARGS = (["--use-angle=metal", "--ignore-gpu-blocklist", "--enable-gpu"] if sys.platform == "darwin"
                 else ["--ignore-gpu-blocklist", "--enable-unsafe-swiftshader"])
DEFINE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*=-?[A-Za-z0-9_.]+")


def apply_defines(src: str, defines):
    """Override `#define NAME value` lines: each item is NAME=VALUE."""
    for item in defines:
        if not DEFINE.fullmatch(item):
            sys.exit(f"--define {item!r}: expected NAME=VALUE (a number or an identifier)")
        k, v = item.split("=", 1)
        src, n = re.subn(rf"(?m)^(#define[ \t]+{re.escape(k)})[ \t]+\S+", lambda mo: f"{mo.group(1)} {v}", src, count=1)
        if not n:
            sys.exit(f"--define {k}: the shader has no `#define {k} ...` line")
    return src


def render(src: str, size: int, times):
    """Images of the shader at the given times, plus the page's result record (ms per frame, renderer name)."""
    with sync_playwright() as pw:
        browser = pw.chromium.launch(args=CHROMIUM_ARGS)
        try:
            page = browser.new_context(offline=True).new_page()
            page.set_content(PAGE)
            res = page.evaluate("([s,w,h,t]) => window.run(s,w,h,t)", [src, size, size, list(times)])
        finally:
            browser.close()
    if "error" in res:
        sys.exit("COMPILE ERROR\n" + str(res["error"]))
    imgs = [Image.open(io.BytesIO(base64.b64decode(u.split(",", 1)[1])), formats=["PNG"]).convert("RGB") for u in res["frames"]]
    return imgs, res


def run(d: Path, frames: str = "", defines=(), tag: str = "", size: int = 0):
    """Render the chosen frames of a work folder and print the error table. Returns (MAE, MAE at 1/8)."""
    if not re.fullmatch(r"[A-Za-z0-9_]*", tag):
        sys.exit(f"--tag {tag!r}: letters, digits and underscores only")
    m = meta(d)
    size = size or m["size"]
    if not 16 <= size <= MAX_SIZE:
        sys.exit(f"--size: between 16 and {MAX_SIZE}")
    ref_paths = refs(d)
    idx = frame_list(frames, len(ref_paths))
    bundled = d / "shader.out.glsl"
    if not bundled.is_file():
        sys.exit(f"{bundled}: not built; run tools/build.py {d}")
    imgs, res = render(apply_defines(bundled.read_text(), defines), size, [(i - 1) * m["dt"] for i in idx])
    out = d / ("out" + tag)
    if out.is_symlink():
        sys.exit(f"{out}: is a link; remove it")
    out.mkdir(exist_ok=True)
    print("renderer:", res["renderer"], "| ms/frame:", " ".join(f"{t:.0f}" for t in res["ms"]))
    tot = []
    for i, im in zip(idx, imgs):
        save_image(im, out / f"f{i:02d}.png")
        ref = open_png(ref_paths[i - 1]).resize(im.size, Image.LANCZOS)
        a, b = np.asarray(ref).astype(np.float32), np.asarray(im).astype(np.float32)
        diff = np.abs(a - b)
        # the blurred error is the useful one: fine painted texture can never line up pixel for pixel
        small = (max(im.width // 8, 1), max(im.height // 8, 1))
        a8 = np.asarray(ref.resize(small, Image.BOX)).astype(np.float32)
        b8 = np.asarray(im.resize(small, Image.BOX)).astype(np.float32)
        e, e8 = float(diff.mean()), float(np.abs(a8 - b8).mean())
        tot.append((e, e8))
        print(f"f{i:02d} MAE {e:6.2f}  MAE@1/8 {e8:6.2f}  meanRGB ref {a.mean((0, 1)).round(0)} out {b.mean((0, 1)).round(0)}")
        sbs = Image.new("RGB", (im.width * 3, im.height))
        sbs.paste(ref, (0, 0))
        sbs.paste(im, (im.width, 0))
        sbs.paste(Image.fromarray(np.clip(diff * 3, 0, 255).astype(np.uint8)), (im.width * 2, 0))
        save_image(sbs, out / f"sbs_{i:02d}.png")
    t = np.array(tot).mean(0)
    print(f"ALL MAE {t[0]:.2f}  MAE@1/8 {t[1]:.2f}")
    return float(t[0]), float(t[1])


def parser(doc):
    ap = argparse.ArgumentParser(description=doc, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("folder", help="work folder")
    ap.add_argument("--frames", default="", help="for example 1,6 (default: all)")
    ap.add_argument("--define", action="append", default=[], metavar="NAME=VALUE", help="override a #define for this render")
    ap.add_argument("--tag", default="", help="write to out<tag>/ instead of out/")
    ap.add_argument("--size", type=int, default=0, help="render size in px (default: meta.json size)")
    return ap


if __name__ == "__main__":
    a = parser(__doc__).parse_args()
    run(work(a.folder), a.frames, a.define, a.tag, a.size)
