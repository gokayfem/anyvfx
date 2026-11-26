# AGENTS.md

Guidance for coding agents working in this repository.

- **To recreate a clip as a shader, follow [`SKILL.md`](SKILL.md) from the top.** It is the whole process.
- Commands run from the repository root with the project's Python. Setup is in `README.md`, Quick start. The build
  needs a [shader-skills](https://github.com/gokayfem/shader-skills) checkout: a sibling folder, or `SHADER_SKILLS`.
- New work goes in `work/<name>/` (ignored by git). `examples/` are finished references: read them, copy from them,
  and do not edit them unless asked.
- Never edit generated files by hand: `shader.out.glsl`, `lightmap.glsl`, `compare.html`, `compare.gif`, and
  anything in `out/` or `analysis/`. Rebuild them with the tools.
- Report honestly. Give the measured error, say what is measured and what is a procedural stand-in, say when only
  stills were checked, and never call a result exact.
- Before committing: `python -m unittest discover -s tests` must pass, and `git status` must show no file from
  `out/`, `analysis/`, `baseline/` or `work/`.
