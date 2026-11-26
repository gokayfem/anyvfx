#!/usr/bin/env python3
"""Write <folder>/compare.html: the reference GIF beside the live shader (WebGL2). The shader source is embedded, so
the page opens straight from disk and loads nothing from the network.

  python tools/build_viewer.py <work folder>
"""
import html
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from common import meta, work, write_text  # noqa: E402

PAGE = """<!doctype html><meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src 'self' data:; style-src 'unsafe-inline'; script-src 'unsafe-inline'; base-uri 'none'; form-action 'none'">
<title>%(name)s: reference vs shader</title>
<style>
body{margin:0;background:#0d0b16;color:#d8d2ee;font:14px/1.5 system-ui,sans-serif}
main{display:flex;gap:16px;justify-content:center;align-items:flex-start;padding:20px;flex-wrap:wrap}
figure{margin:0}figcaption{padding:6px 0;color:#a79fc8}
img,canvas{width:min(46vw,816px);aspect-ratio:1;display:block;background:#000}
p{text-align:center;margin:0 0 16px}label{margin:0 10px}
</style>
<main>
<figure><img src="source.gif" alt="reference GIF"><figcaption>Reference GIF (%(nf)d frames, %(fps).2f fps)</figcaption></figure>
<figure><canvas id="c" width="%(size)d" height="%(size)d"></canvas><figcaption id="cap">Shader</figcaption></figure>
</main>
<p><label><input type="checkbox" id="step"> hold reference frame times (%(fps).2f fps)</label>
<label><input type="checkbox" id="pause"> pause</label>
<label>time <input type="range" id="t" min="0" max="%(loop).4f" step="0.01" value="0" style="width:300px"></label></p>
<script>
const SRC = %(src)s;
const cap = document.getElementById('cap');
const c = document.getElementById('c'), gl = c.getContext('webgl2', {antialias:false});
if (!gl) { cap.textContent = 'WebGL2 is not available in this browser'; throw new Error('no WebGL2'); }
const mk = (type, s) => { const sh = gl.createShader(type); gl.shaderSource(sh, s); gl.compileShader(sh);
  if (!gl.getShaderParameter(sh, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(sh)); return sh; };
const pr = gl.createProgram();
gl.attachShader(pr, mk(gl.VERTEX_SHADER, '#version 300 es\\nin vec2 p;void main(){gl_Position=vec4(p,0,1);}'));
gl.attachShader(pr, mk(gl.FRAGMENT_SHADER, '#version 300 es\\nprecision highp float;precision highp int;uniform vec3 iResolution;uniform float iTime;uniform int iFrame;out vec4 _o;\\n' + SRC + '\\nvoid main(){vec4 k=vec4(0);mainImage(k,gl_FragCoord.xy);_o=vec4(k.rgb,1.0);}'));
gl.linkProgram(pr); gl.useProgram(pr);
gl.bindBuffer(gl.ARRAY_BUFFER, gl.createBuffer());
gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1,-1,3,-1,-1,3]), gl.STATIC_DRAW);
const loc = gl.getAttribLocation(pr, 'p'); gl.enableVertexAttribArray(loc); gl.vertexAttribPointer(loc, 2, gl.FLOAT, false, 0, 0);
gl.uniform3f(gl.getUniformLocation(pr, 'iResolution'), c.width, c.height, 1);
const uT = gl.getUniformLocation(pr, 'iTime'), uF = gl.getUniformLocation(pr, 'iFrame');
const step = document.getElementById('step'), pause = document.getElementById('pause'), slider = document.getElementById('t');
let frame = 0, t0 = performance.now(), last = t0, fps = 0;
function draw(now) {
  let t = pause.checked ? +slider.value : ((now - t0) / 1000) %% %(loop).4f;
  if (!pause.checked) slider.value = t;
  if (step.checked) t = Math.floor(t / %(dt).4f) * %(dt).4f;
  gl.uniform1f(uT, t); gl.uniform1i(uF, frame++);
  gl.drawArrays(gl.TRIANGLES, 0, 3);
  fps = 0.9 * fps + 0.1 * 1000 / Math.max(now - last, 1); last = now;
  cap.textContent = 'Shader, t = ' + t.toFixed(2) + ' s, ' + fps.toFixed(0) + ' fps';
  requestAnimationFrame(draw);
}
requestAnimationFrame(draw);
</script>
"""


def js_string(text: str) -> str:
    """A JavaScript string literal that is safe inside a <script> element: no `<` survives, so the text cannot close
    the element or open a comment, whatever the shader source contains."""
    return json.dumps(text).replace("<", "\\u003c").replace(">", "\\u003e").replace("&", "\\u0026") \
        .replace("\u2028", "\\u2028").replace("\u2029", "\\u2029")


def page(name: str, src: str, m: dict) -> str:
    size, nf, dt = int(m["size"]), int(m["frames"]), float(m["dt"])
    if dt <= 0 or nf <= 0 or size <= 0:
        sys.exit("meta.json: size, frames and dt must be positive")
    return PAGE % {"name": html.escape(name), "src": js_string(src), "nf": nf, "dt": dt, "fps": 1 / dt,
                   "loop": nf * dt, "size": size}


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    d = work(sys.argv[1])
    bundled = d / "shader.out.glsl"
    if not bundled.is_file():
        sys.exit(f"{bundled}: not built; run tools/go.py {d}")
    write_text(d / "compare.html", page(d.resolve().name, bundled.read_text(), meta(d)))
    print("wrote", d / "compare.html")
