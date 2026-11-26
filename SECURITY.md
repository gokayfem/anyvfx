# Security

## What the tools do on your machine

Everything runs locally. Nothing is uploaded, and no API key or account is needed.

- **Rendering.** `tools/render.py` starts a headless Chromium (through Playwright), sets a page from a string held
  in the script, and draws the shader with WebGL2. The browser context is created offline and no URL is loaded.
  On macOS it uses the GPU; elsewhere it asks Chromium for its software renderer (`--enable-unsafe-swiftshader`).
- **Frames.** `tools/new.py` decodes the clip with Pillow's GIF reader only, and the other tools read frames with
  its PNG reader only, whatever a file claims to be. A clip is refused before decoding if it is over 64 MB, over
  240 frames, over 4096 px a side, or over 64 million pixels in total. Only `tools/capture.py` runs `ffmpeg`, on
  frames it rendered itself, with arguments passed as a list and never through a shell.
- **Downloads.** `tools/new.py` downloads only when you pass a URL, only over `https://` (redirects to anything
  else are refused), at most 64 MB and 120 seconds, and writes nothing unless the data starts with a GIF
  signature.
- **Work folders.** A work folder that contains a symbolic link anywhere inside it is refused, and every file the
  tools write goes through a temporary file that is then moved into place, so a link is replaced, never followed.
  `//#include "file"` lines may only name files inside the shader's work folder: absolute paths, `..`, and
  anything that resolves outside are refused.
- **`meta.json`.** Size, frame count, frame time and the light-map entry are range-checked before use.
- **The viewer.** `compare.html` embeds the shader source as an escaped string and loads only `source.gif` from
  its own folder. Its Content-Security-Policy allows no scripts, styles, frames or connections from anywhere else;
  images may come from the page's own origin.
- **Building.** `tools/build.py` runs the bundler and checker from your shader-skills checkout (`SHADER_SKILLS`, or
  a sibling `shader-skills` folder) with the same Python interpreter. Point it only at a checkout you trust.

## What to keep in mind

- A clip or a shader you got from someone else is still input to Pillow and to your GPU driver through WebGL.
  Keep Pillow, Chromium (`playwright install chromium`) and your OS up to date, and do not run the tools on
  untrusted files with elevated privileges.
- An agent following `SKILL.md` runs commands and edits files in this repository. Run it with the permissions you
  would give any coding agent, and review what it publishes.
- `requirements.txt` pins the four packages the tools import. Their own dependencies are not pinned. Install in a
  virtual environment; for a fully locked install, compile a hashed lock file from it with `pip-compile
  --generate-hashes`.

## Reporting a problem

Please report vulnerabilities privately through GitHub's "Report a vulnerability" button on the repository's
Security tab, not in a public issue. Say what you ran, on which file, and what happened.
