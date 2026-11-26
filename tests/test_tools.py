"""Checks that run without a GPU or a shader-skills checkout: the guards in the tools, and the repository's hygiene.

  python -m unittest discover -s tests
"""
import json
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

import build  # noqa: E402
import build_viewer  # noqa: E402
import common  # noqa: E402
import new  # noqa: E402
import render  # noqa: E402

GIF = b"GIF89a" + b"\x00" * 32


class Includes(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.d = Path(self.tmp.name) / "clip"
        self.d.mkdir()

    def tearDown(self):
        self.tmp.cleanup()

    def shader(self, text):
        (self.d / "shader.glsl").write_text(text)

    def test_include_is_pasted(self):
        (self.d / "scene").mkdir()
        (self.d / "scene" / "env.glsl").write_text("float env;\n")
        self.shader('//#include "scene/env.glsl"\nfloat after;\n')
        self.assertEqual(build.assemble(self.d), "float env;\nfloat after;\n")

    def test_missing_light_map_is_identity(self):
        self.shader('//#include "scene/lightmap.glsl"\n')
        self.assertEqual(build.assemble(self.d), build.IDENTITY_MAP)

    def test_missing_include_fails(self):
        self.shader('//#include "nope.glsl"\n')
        with self.assertRaises(SystemExit):
            build.assemble(self.d)

    def test_parent_path_refused(self):
        (Path(self.tmp.name) / "secret.glsl").write_text("float secret;\n")
        self.shader('//#include "../secret.glsl"\n')
        with self.assertRaises(SystemExit):
            build.assemble(self.d)

    def test_absolute_path_refused(self):
        outside = Path(self.tmp.name) / "secret.glsl"
        outside.write_text("float secret;\n")
        self.shader(f'//#include "{outside}"\n')
        with self.assertRaises(SystemExit):
            build.assemble(self.d)

    def test_link_out_of_folder_refused(self):
        outside = Path(self.tmp.name) / "secret.glsl"
        outside.write_text("float secret;\n")
        try:
            (self.d / "link.glsl").symlink_to(outside)
        except OSError:
            self.skipTest("links are not available here")
        self.shader('//#include "link.glsl"\n')
        with self.assertRaises(SystemExit):
            build.assemble(self.d)


class Viewer(unittest.TestCase):
    META = {"size": 816, "frames": 12, "dt": 0.12}

    def test_source_cannot_close_the_script_element(self):
        src = 'void mainImage(){} // </script><script>alert(1)</script> <!-- & \u2028'
        page = build_viewer.page("clip", src, self.META)
        body = page.split("const SRC = ", 1)[1].split(";\n", 1)[0]
        self.assertNotIn("<", body)
        self.assertNotIn(">", body)
        self.assertEqual(json.loads(body), src)
        self.assertEqual(page.count("</script>"), 1)

    def test_name_is_escaped(self):
        page = build_viewer.page('<img src=x onerror=alert(1)>', "void mainImage(){}", self.META)
        self.assertNotIn("<img src=x", page)

    def test_no_network_in_page(self):
        page = build_viewer.page("clip", "void mainImage(){}", self.META)
        self.assertIn("default-src 'none'", page)
        self.assertIsNone(re.search(r"https?://", page))

    def test_bad_meta_refused(self):
        with self.assertRaises(SystemExit):
            build_viewer.page("clip", "", {"size": 816, "frames": 12, "dt": 0})


class Defines(unittest.TestCase):
    SRC = "#define SHAKE 1.0   // camera\n#define MODE 0\nfloat x = SHAKE;\n"

    def test_override(self):
        out = render.apply_defines(self.SRC, ["SHAKE=0.0", "MODE=2"])
        self.assertIn("#define SHAKE 0.0", out)
        self.assertIn("#define MODE 2", out)
        self.assertIn("float x = SHAKE;", out)

    def test_code_in_value_refused(self):
        for bad in ("SHAKE=0.0; discard", "SHAKE=1.0\n#define X 1", "SHAKE", "=1", "SHAKE=(1)", "SH AKE=1"):
            with self.assertRaises(SystemExit, msg=bad):
                render.apply_defines(self.SRC, [bad])

    def test_unknown_name_refused(self):
        with self.assertRaises(SystemExit):
            render.apply_defines(self.SRC, ["NOPE=1"])


class Arguments(unittest.TestCase):
    def test_frame_list(self):
        self.assertEqual(common.frame_list("", 3), [1, 2, 3])
        self.assertEqual(common.frame_list("1,3", 3), [1, 3])
        for bad in ("0", "4", "a", "1;2"):
            with self.assertRaises(SystemExit, msg=bad):
                common.frame_list(bad, 3)

    def test_box(self):
        self.assertEqual(common.box("1,2,30,40"), (1, 2, 30, 40))
        for bad in ("1,2,3", "5,5,5,9", "a,b,c,d", "1,2,3,4,5"):
            with self.assertRaises(SystemExit, msg=bad):
                common.box(bad)

    def test_work_folder_must_exist(self):
        with self.assertRaises(SystemExit):
            common.work("/nonexistent/anyvfx/folder")


class Links(unittest.TestCase):
    """A work folder from someone else must not be able to redirect a write."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.t = Path(self.tmp.name)
        self.d = self.t / "clip"
        self.d.mkdir()
        self.victim = self.t / "victim.txt"
        self.victim.write_text("keep me")

    def tearDown(self):
        self.tmp.cleanup()

    def link(self, name):
        try:
            (self.d / name).symlink_to(self.victim)
        except OSError:
            self.skipTest("links are not available here")

    def test_folder_with_a_link_is_refused(self):
        self.link(".build.glsl")
        with self.assertRaises(SystemExit):
            common.work(self.d)
        self.assertEqual(self.victim.read_text(), "keep me")

    def test_nested_link_is_refused(self):
        (self.d / "out").mkdir()
        try:
            (self.d / "out" / "f01.png").symlink_to(self.victim)
        except OSError:
            self.skipTest("links are not available here")
        with self.assertRaises(SystemExit):
            common.work(self.d)

    def test_write_replaces_a_link_instead_of_following_it(self):
        self.link("shader.out.glsl")
        common.write_text(self.d / "shader.out.glsl", "new text")
        self.assertEqual(self.victim.read_text(), "keep me")
        self.assertFalse((self.d / "shader.out.glsl").is_symlink())
        self.assertEqual((self.d / "shader.out.glsl").read_text(), "new text")


class Limits(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.d = Path(self.tmp.name)
        (self.d / "ref").mkdir()
        (self.d / "ref" / "f01.png").write_bytes(b"")

    def tearDown(self):
        self.tmp.cleanup()

    def test_hostile_meta_is_refused(self):
        for bad in ('{"size": 1000000}', '{"frames": 1000000000}', '{"dt": 0}', '{"dt": 1e9}', '{"size": "big"}',
                    '[1, 2]', 'not json'):
            (self.d / "meta.json").write_text(bad)
            with self.assertRaises(SystemExit, msg=bad):
                common.meta(self.d)

    def test_good_meta(self):
        (self.d / "meta.json").write_text('{"size": 816, "frames": 12, "dt": 0.12}')
        self.assertEqual(common.meta(self.d)["size"], 816)

    def test_oversized_gif_is_refused_before_decoding(self):
        from PIL import Image
        big = self.d / "source.gif"
        frames = [Image.new("RGB", (2048, 2048), (i * 12, 255 - i * 12, 7)) for i in range(20)]   # 84 million pixels in total
        frames[0].save(big, save_all=True, append_images=frames[1:], duration=100)
        with self.assertRaises(SystemExit):
            new.decode(big)

    def test_small_gif_decodes(self):
        from PIL import Image
        small = self.d / "source.gif"
        frames = [Image.new("RGB", (32, 32), (i * 100, 255 - i * 100, 7)) for i in range(3)]
        frames[0].save(small, save_all=True, append_images=frames[1:], duration=120)
        got, dt = new.decode(small)
        self.assertEqual((len(got), dt), (3, 0.12))

    def test_contact_sheet_cells_stay_bounded(self):
        # a 16 x 4096 clip passes the pixel limits; its thumbnails must still fit the sheet's cells
        for w, h in ((16, 4096), (4096, 16), (816, 816), (17, 16)):
            tw, th = new.thumb_size(w, h, 390)
            self.assertTrue(1 <= tw <= 390 and 1 <= th <= 390, (w, h, tw, th))
        self.assertEqual(new.thumb_size(816, 816, 390), (390, 390))


class Fetch(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.t = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_local_gif_is_copied(self):
        (self.t / "a.gif").write_bytes(GIF)
        new.fetch(str(self.t / "a.gif"), self.t / "out.gif")
        self.assertEqual((self.t / "out.gif").read_bytes(), GIF)

    def test_not_a_gif_refused(self):
        (self.t / "a.gif").write_bytes(b"#!/bin/sh\necho hi\n")
        with self.assertRaises(SystemExit):
            new.fetch(str(self.t / "a.gif"), self.t / "out.gif")
        self.assertFalse((self.t / "out.gif").exists())

    def test_other_schemes_refused(self):
        for url in ("http://example.com/a.gif", "file:///etc/hosts", "ftp://example.com/a.gif", "FILE:///etc/hosts"):
            with self.assertRaises(SystemExit, msg=url):
                new.fetch(url, self.t / "out.gif")
            self.assertFalse((self.t / "out.gif").exists())

    def test_redirect_off_https_refused(self):
        import urllib.error
        import urllib.request
        handler = new.HttpsOnly()
        req = urllib.request.Request("https://example.com/a.gif")
        with self.assertRaises(urllib.error.HTTPError):
            handler.redirect_request(req, None, 302, "Found", {}, "http://example.com/a.gif")
        with self.assertRaises(urllib.error.HTTPError):
            handler.redirect_request(req, None, 302, "Found", {}, "file:///etc/hosts")


class Repository(unittest.TestCase):
    """What is committed must not carry anything from the machine it was made on."""

    def tracked(self):
        r = subprocess.run(["git", "ls-files", "-z"], cwd=ROOT, capture_output=True)
        if r.returncode != 0:
            self.skipTest("not a git checkout")
        return [ROOT / p.decode() for p in r.stdout.split(b"\0") if p]

    def test_no_local_paths_or_keys_in_text_files(self):
        patterns = [re.compile(p) for p in (
            rb"/Users/[A-Za-z0-9._-]+/", rb"/home/[A-Za-z0-9._-]+/", rb"[A-Za-z]:\\Users\\",
            rb"-----BEGIN [A-Z ]*PRIVATE KEY-----", rb"gh[pousr]_[A-Za-z0-9]{30,}", rb"github_pat_[A-Za-z0-9_]{30,}",
            rb"sk-[A-Za-z0-9_-]{24,}", rb"AKIA[0-9A-Z]{16}", rb"(?i)fal_key\s*[=:]\s*\S+", rb"@[A-Za-z0-9-]+\.local\b",
            rb"fal\.media/",
        )]
        text = {".py", ".md", ".glsl", ".json", ".txt", ".yml", ".yaml", ".html", ".toml", ""}
        for p in self.tracked():
            if p.suffix.lower() not in text or p == Path(__file__).resolve() or not p.is_file():
                continue
            data = p.read_bytes()
            for pat in patterns:
                self.assertIsNone(pat.search(data), f"{p.relative_to(ROOT)} matches {pat.pattern!r}")

    def test_nothing_generated_is_tracked(self):
        banned = {"out", "analysis", "baseline", "work", ".venv", "__pycache__"}
        for p in self.tracked():
            rel = p.relative_to(ROOT)
            self.assertFalse(banned & set(rel.parts), f"{rel} should not be tracked")
            self.assertNotIn(rel.name, {".build.glsl", "shader.gif", "live.mp4", ".env", ".DS_Store"}, f"{rel}")

    def test_examples_are_complete(self):
        for d in sorted((ROOT / "examples").iterdir()):
            if not d.is_dir():
                continue
            for name in ("shader.glsl", "shader.out.glsl", "meta.json", "source.gif", "compare.gif", "compare.html", "NOTES.md"):
                self.assertTrue((d / name).is_file(), f"{d.name}/{name} is missing")
            m = json.loads((d / "meta.json").read_text())
            self.assertEqual(len(list((d / "ref").glob("f*.png"))), m["frames"], d.name)
            self.assertNotIn("url", m, f"{d.name}/meta.json")


if __name__ == "__main__":
    unittest.main()
