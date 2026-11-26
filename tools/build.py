#!/usr/bin/env python3
"""Assemble a work folder's shader, bundle it with the shader-skills library, lint and compile it.

  python tools/build.py examples/04-foundry-waveform      -> shader.out.glsl (paste-ready Shadertoy code)

`//#include "file"` lines of shader.glsl are resolved against the work folder first. Includes may only name files
inside that folder. A missing lightmap.glsl resolves to an identity map, so a new shader builds before its light map
has been fitted.
"""
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from common import glsl_tools, work, write_text  # noqa: E402

INCLUDE = re.compile(r'^//#include "([^"\n]+)"[ \t]*\n', re.M)
IDENTITY_MAP = "vec3 lightMapRaw(vec2 P) { return vec3(1.0); }\n"


def assemble(d: Path) -> str:
    """shader.glsl with its includes pasted in. Every file read must lie inside the work folder."""
    root = d.resolve()
    src_path = d / "shader.glsl"

    def inside(p: Path, what: str) -> Path:
        r = p.resolve()
        if root != r and root not in r.parents:
            sys.exit(f"{src_path}: {what} resolves outside the work folder")
        return r

    if not src_path.is_file():
        sys.exit(f"{src_path}: no shader here")
    inside(src_path, "shader.glsl")

    def sub(mo):
        name = mo.group(1)
        rel = Path(name)
        if rel.is_absolute() or ".." in rel.parts:
            sys.exit(f'{src_path}: include "{name}" must be a path inside the work folder')
        p = inside(root / rel, f'include "{name}"')
        if p.is_file():
            return p.read_text()
        if rel.name == "lightmap.glsl":
            return IDENTITY_MAP
        sys.exit(f"{src_path}: missing include {name}")

    return INCLUDE.sub(sub, src_path.read_text())


def build(d: Path, quiet: bool = False) -> Path:
    """Write .build.glsl and shader.out.glsl; exit non-zero on a bundler or lint failure."""
    tools = glsl_tools()
    assembled, out = d / ".build.glsl", d / "shader.out.glsl"
    write_text(assembled, assemble(d))
    # the bundler writes to a fresh temporary file, which is then moved into place: a link at shader.out.glsl is
    # replaced, never followed
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".tmp-", suffix=".glsl")
    os.close(fd)
    try:
        r = subprocess.run([sys.executable, str(tools), "bundle", str(assembled), "-o", tmp], capture_output=True, text=True)
        if r.returncode != 0:
            sys.exit((r.stdout + r.stderr).strip() or "bundle failed")
        r = subprocess.run([sys.executable, str(tools), "check", tmp], capture_output=True, text=True)
        report = (r.stdout + r.stderr).strip().splitlines()
        if r.returncode != 0:
            sys.exit("\n".join(report[-30:]) or "check failed")
        os.replace(tmp, out)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)
    if not quiet:
        print("\n".join(report[-1:]))
    return out


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    print("wrote", build(work(sys.argv[1])))
