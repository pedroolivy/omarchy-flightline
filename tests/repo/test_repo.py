# Repository checks: the manifest, the shaders, the data textures and the
# files a release ships. No GPU, no network, standard library only.
#
#   python3 -m unittest discover -s tests/repo -v
#
# Optional tools widen the checks when they are installed: glslangValidator
# compiles every shader source, and qsb (qt6-shadertools, or QSB=path) re-bakes
# them and compares with the committed .qsb. FLIGHTLINE_REQUIRE_GLSLANG=1 or
# FLIGHTLINE_REQUIRE_QSB=1 (or FLIGHTLINE_REQUIRE_TOOLS=1 for both) turns a
# missing tool into a failure instead of a skip (CI does).
import hashlib
import json
import os
import py_compile
import re
import shutil
import struct
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
REQUIRE_TOOLS = os.environ.get("FLIGHTLINE_REQUIRE_TOOLS") == "1"
REQUIRE_GLSLANG = REQUIRE_TOOLS or os.environ.get("FLIGHTLINE_REQUIRE_GLSLANG") == "1"
REQUIRE_QSB = REQUIRE_TOOLS or os.environ.get("FLIGHTLINE_REQUIRE_QSB") == "1"
QSB = os.environ.get("QSB") or shutil.which("qsb") or "/usr/lib/qt6/bin/qsb"
GLSLANG = shutil.which("glslangValidator")

# Files a user gets but never loads directly; everything else counts towards
# the installed size.
NOT_SHIPPED = ("tests/", "docs/", "tools/", ".github/", ".git/")
SHIPPED_BUDGET = 8_000_000                      # bytes, docs/ARCHITECTURE.md budgets

# Settings the panel stores itself (the saved location); every other key read
# with setting("...") must be declared in the manifest's schema.
INTERNAL_SETTINGS = {"homeName", "homeLat", "homeLon", "homeSource", "homeAccuracyM"}

# The kinds Omarchy knows and the entry point each one needs
# (omarchy-plugin-validate).
KIND_ENTRY_POINTS = {"bar": "bar", "bar-widget": "barWidget", "menu": "menu",
                     "overlay": "overlay", "panel": "panel", "service": "service"}


def tracked_files():
    """The files git tracks, or every file when this is not a checkout."""
    try:
        out = subprocess.run(["git", "ls-files", "-z"], cwd=ROOT, check=True,
                             capture_output=True).stdout.decode()
        return sorted(ROOT / f for f in out.split("\0") if f)
    except (OSError, subprocess.CalledProcessError):
        return sorted(p for p in ROOT.rglob("*") if p.is_file() and ".git" not in p.parts)


def rel(path):
    return path.relative_to(ROOT).as_posix()


def manifest():
    return json.loads((ROOT / "manifest.json").read_text())


def png_info(path):
    """(width, height, bit depth, colour type, chunk types) of a PNG."""
    data = path.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError(f"{path} is not a PNG")
    width, height, depth, colour = struct.unpack(">IIBB", data[16:26])
    chunks, i = set(), 8
    while i < len(data):
        n = struct.unpack(">I", data[i:i + 4])[0]
        chunks.add(data[i + 4:i + 8].decode("ascii"))
        i += 12 + n
    return width, height, depth, colour, chunks


def shader_code(path):
    """A shader source without comments."""
    text = re.sub(r"/\*.*?\*/", " ", path.read_text(), flags=re.S)
    return re.sub(r"//[^\n]*", "", text)


def uniform_block(path):
    """The `uniform buf { ... };` block, as build-shaders.sh compares it."""
    lines, inside = [], False
    for line in path.read_text().splitlines():
        if "uniform buf {" in line:
            inside = True
        if inside:
            lines.append(line)
            if line.startswith("};"):
                break
    return "\n".join(lines)


class ManifestTest(unittest.TestCase):
    def setUp(self):
        self.m = manifest()

    def test_schema_version_and_required_fields(self):
        self.assertIs(type(self.m.get("schemaVersion")), int)
        self.assertEqual(self.m["schemaVersion"], 1)
        for field in ("id", "name", "version", "kinds", "entryPoints"):
            self.assertIn(field, self.m)

    def test_id(self):
        plugin_id = self.m["id"]
        self.assertRegex(plugin_id, r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
        self.assertNotIn("..", plugin_id)
        self.assertFalse(plugin_id.startswith("omarchy."), "omarchy.* is reserved")

    def test_version_is_semver(self):
        self.assertRegex(self.m["version"], r"^\d+\.\d+\.\d+$")

    def test_license_matches_license_file(self):
        self.assertEqual(self.m.get("license"), "MIT")
        self.assertTrue((ROOT / "LICENSE").read_text().startswith("MIT License"))

    def test_every_kind_has_its_entry_point(self):
        kinds = self.m["kinds"]
        self.assertIsInstance(kinds, list)
        self.assertTrue(kinds)
        for kind in kinds:
            if kind in KIND_ENTRY_POINTS:
                self.assertIn(KIND_ENTRY_POINTS[kind], self.m["entryPoints"], kind)

    def test_entry_points_are_safe_and_exist(self):
        for name, path in self.m["entryPoints"].items():
            with self.subTest(entry=name):
                self.assertTrue(path and "\n" not in path)
                self.assertFalse(path.startswith("/"), "must be relative")
                self.assertNotIn("..", path)
                self.assertTrue((ROOT / path).is_file(), path)

    def test_bar_widget_defaults_match_schema(self):
        bar = self.m["barWidget"]
        self.assertIn(bar.get("defaultSection", "right"), ("left", "center", "right"))
        defaults, schema = bar["defaults"], bar["schema"]
        self.assertEqual(sorted(defaults), sorted(s["key"] for s in schema))
        for setting in schema:
            with self.subTest(key=setting["key"]):
                value = setting["defaultValue"]
                self.assertEqual(defaults[setting["key"]], value)
                kind = setting["type"]
                if kind == "boolean":
                    self.assertIsInstance(value, bool)
                elif kind == "enum":
                    self.assertIn(value, setting["options"])
                elif kind == "integer":
                    self.assertIsInstance(value, int)
                    self.assertLessEqual(setting["min"], value)
                    self.assertLessEqual(value, setting["max"])
                else:
                    self.fail(f"unexpected setting type {kind}")

    def test_settings_read_by_the_code_are_declared(self):
        declared = {s["key"] for s in self.m["barWidget"]["schema"]} | INTERNAL_SETTINGS
        used = set()
        for qml in ROOT.glob("*.qml"):
            used |= set(re.findall(r'setting\("([A-Za-z0-9_]+)"', qml.read_text()))
        self.assertTrue(used)
        self.assertEqual(sorted(used - declared), [])

    def test_readme_explains_install_and_removal(self):
        readme = (ROOT / "README.md").read_text()
        self.assertIn("omarchy plugin add", readme)
        self.assertIn("omarchy plugin remove " + self.m["id"], readme)


class ShaderTest(unittest.TestCase):
    sources = sorted((ROOT / "shaders").glob("*.vert")) + sorted((ROOT / "shaders").glob("*.frag"))

    def test_there_are_shaders(self):
        self.assertTrue(self.sources)

    def test_every_source_is_baked(self):
        for src in self.sources:
            with self.subTest(shader=src.name):
                self.assertTrue(Path(f"{src}.qsb").is_file())

    def test_bakes_are_from_the_current_sources(self):
        recorded = {}
        for line in (ROOT / "shaders/sources.sha256").read_text().splitlines():
            digest, name = line.split(maxsplit=1)
            recorded[name.strip()] = digest
        self.assertEqual(sorted(recorded), sorted(rel(s) for s in self.sources))
        for src in self.sources:
            with self.subTest(shader=src.name):
                self.assertEqual(hashlib.sha256(src.read_bytes()).hexdigest(), recorded[rel(src)],
                                 "source changed since its bake: run tools/build-shaders.sh")

    def test_pairs_share_one_uniform_block(self):
        for vert in (ROOT / "shaders").glob("*.vert"):
            frag = vert.with_suffix(".frag")
            if frag.exists():
                with self.subTest(pair=vert.stem):
                    block = uniform_block(vert)
                    self.assertTrue(block)
                    self.assertEqual(block, uniform_block(frag))

    def test_no_feature_that_needs_glsl_330(self):
        # GLSL 100 es / 120 targets: no integers, no bitwise ops, no texelFetch.
        banned = [r"\btexelFetch\b", r"\btextureSize\b", r"\b[iu]vec[234]\b", r"\buint\b",
                  r"\bint\b", r"<<|>>", r"(?<![&])&(?![&=])", r"(?<![|])\|(?![|=])", r"\^", r"~"]
        for src in self.sources:
            code = shader_code(src)
            for pattern in banned:
                with self.subTest(shader=src.name, pattern=pattern):
                    self.assertIsNone(re.search(pattern, code))

    def test_sources_compile(self):
        if not GLSLANG:
            if REQUIRE_GLSLANG:
                self.fail("glslangValidator not found")
            self.skipTest("glslangValidator not installed")
        for src in self.sources:
            with self.subTest(shader=src.name):
                result = subprocess.run([GLSLANG, "-V", src, "-o", os.devnull],
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_bakes_match_a_fresh_bake(self):
        if not Path(QSB).is_file():
            if REQUIRE_QSB:
                self.fail(f"qsb not found ({QSB})")
            self.skipTest("qsb not installed")
        with tempfile.TemporaryDirectory() as tmp:
            for src in self.sources:
                with self.subTest(shader=src.name):
                    out = Path(tmp) / f"{src.name}.qsb"
                    subprocess.run([QSB, "--glsl", "100es,120,150", "--hlsl", "50", "--msl", "12",
                                    "-o", out, src], check=True, capture_output=True)
                    self.assertEqual(out.read_bytes(), Path(f"{src}.qsb").read_bytes(),
                                     "run tools/build-shaders.sh")


class AssetTest(unittest.TestCase):
    def test_data_textures_are_plain_rgb(self):
        # Qt premultiplies alpha on upload and applies gamma chunks, either of
        # which would corrupt data channels.
        sizes = {"earth.png": (4096, 2048), "lights.png": (2048, 1024), "terrain.png": (3072, 1536)}
        for name, size in sizes.items():
            with self.subTest(texture=name):
                width, height, depth, colour, chunks = png_info(ROOT / "assets" / name)
                self.assertEqual((width, height), size)
                self.assertEqual(depth, 8)
                self.assertEqual(colour, 2, "RGB without alpha")
                self.assertEqual(chunks & {"gAMA", "cHRM", "iCCP", "sRGB", "tRNS"}, set())

    def test_places(self):
        data = json.loads((ROOT / "assets/places.json").read_text())
        self.assertEqual(data["v"], 1)
        self.assertGreater(len(data["places"]), 100)
        for place in data["places"]:
            name, lat, lon = place[0], place[1], place[2]
            self.assertTrue(isinstance(name, str) and name.strip())
            self.assertTrue(-90 <= lat <= 90 and -180 <= lon <= 180, name)

    def test_every_asset_is_credited(self):
        notice = (ROOT / "NOTICE.md").read_text()
        for asset in (ROOT / "assets").iterdir():
            with self.subTest(asset=asset.name):
                self.assertIn(asset.name, notice)


class FilesTest(unittest.TestCase):
    files = tracked_files()

    def test_installed_size_within_budget(self):
        size = sum(f.stat().st_size for f in self.files if not rel(f).startswith(NOT_SHIPPED))
        self.assertLessEqual(size, SHIPPED_BUDGET, f"{size:,} bytes")

    def test_no_symlinks(self):
        self.assertEqual([rel(f) for f in self.files if f.is_symlink()], [])

    def test_no_build_leftovers(self):
        leftovers = [rel(f) for f in self.files
                     if "__pycache__" in f.parts or f.suffix in (".pyc", ".orig", ".rej", ".swp")
                     or rel(f).startswith("tests/offscreen/out/")]
        self.assertEqual(leftovers, [])

    def test_json_files_parse(self):
        for f in self.files:
            if f.suffix == ".json":
                with self.subTest(file=rel(f)):
                    json.loads(f.read_text())

    def test_python_compiles(self):
        scripts = [f for f in self.files if f.suffix == ".py"
                   or f.read_bytes()[:30].startswith(b"#!/usr/bin/env python3")]
        self.assertTrue(scripts)
        with tempfile.TemporaryDirectory() as tmp:
            for f in scripts:
                with self.subTest(file=rel(f)):
                    py_compile.compile(str(f), cfile=os.path.join(tmp, "x.pyc"), doraise=True)

    def test_commands_are_executable(self):
        for f in self.files:
            head = f.read_bytes()[:2]
            if f.suffix == ".sh" or (head == b"#!" and f.suffix == ""):
                with self.subTest(file=rel(f)):
                    self.assertEqual(head, b"#!", "needs a shebang")
                    self.assertTrue(os.access(f, os.X_OK), "needs the executable bit")

    def test_no_personal_paths(self):
        pattern = re.compile(rb"/home/[a-z_][a-z0-9_-]*/|/Users/[A-Za-z]")
        for f in self.files:
            if f.suffix in (".png", ".webp", ".qsb"):
                continue
            with self.subTest(file=rel(f)):
                self.assertIsNone(pattern.search(f.read_bytes()))


if __name__ == "__main__":
    unittest.main()
