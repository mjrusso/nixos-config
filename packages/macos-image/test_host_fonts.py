import hashlib
import io
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from unittest.mock import patch

from fontTools.ttLib import TTCollection, TTFont, newTable

import bake
import host_fonts


def font_face(family, style="Regular", preferred=None):
    font = TTFont()
    names = font["name"] = newTable("name")
    names.names = []
    values = {1: family, 2: style, 13: "Example desktop license", 14: "https://example.com/license"}
    if preferred:
        values[16] = preferred
    for name_id, text in values.items():
        names.setName(text, name_id, 3, 1, 0x409)
    return font


class LocalGuest:
    def __init__(self, home, corrupt=False):
        self.home = home
        self.corrupt = corrupt

    def copy(self, source, destination):
        target = self.home / destination
        shutil.copyfile(source, target)
        if self.corrupt:
            target.write_bytes(b"corrupt transfer")

    def ssh(self, command, **kwargs):
        if command.startswith("mkdir"):
            (self.home / "Library/Fonts").mkdir(parents=True)
            return subprocess.CompletedProcess([], 0)
        relative = command.split('"$HOME/', 1)[1].rstrip('"')
        digest = hashlib.sha256((self.home / relative).read_bytes()).hexdigest()
        return subprocess.CompletedProcess([], 0, stdout=digest + "  " + relative + "\n")


class FontTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.fonts = self.root / "host fonts"
        self.fonts.mkdir()
        self.staging = self.root / "staging"

    def save_font(self, name, family, style="Regular", preferred=None):
        path = self.fonts / name
        with font_face(family, style, preferred) as font:
            font.save(path)
        return path

    def stage(self, families):
        with redirect_stdout(io.StringIO()):
            return host_fonts.stage_fonts([self.fonts], families, self.staging)

    def test_default_recipe_copies_no_fonts_even_when_installed(self):
        from test_bake import RECIPE

        self.save_font("BerkeleyMono.ttf", "Berkeley Mono")
        recipe = bake.parse_recipe(RECIPE)
        self.assertEqual(self.stage(recipe["fontFamilies"]), [])
        self.assertFalse(self.staging.exists())

    def test_selection_uses_family_metadata_and_reports_license_fields(self):
        chosen = self.save_font("unrelated-filename.ttf", "Legacy Name", preferred="Berkeley Mono")
        self.save_font("BerkeleyMono.ttf", "Other Family")
        files = self.stage(["berkeley mono"])
        self.assertEqual(len(files), 1)
        record = files[0]
        self.assertEqual(record["sourceFile"], chosen.name)
        self.assertEqual(record["licenseDescriptions"], ["Example desktop license"])
        self.assertEqual(record["licenseUrls"], ["https://example.com/license"])
        self.assertEqual(record["sha256"], hashlib.sha256(chosen.read_bytes()).hexdigest())
        self.assertEqual((self.staging / record["file"]).read_bytes(), chosen.read_bytes())
        self.assertNotIn("path", record)

    def test_multiple_families_colliding_names_and_duplicate_files(self):
        first = self.save_font("same.ttf", "Family One")
        other_dir = self.root / "other fonts"
        other_dir.mkdir()
        with font_face("Family Two") as font:
            font.save(other_dir / "same.ttf")
        shutil.copyfile(first, other_dir / "duplicate.ttf")
        with redirect_stdout(io.StringIO()):
            files = host_fonts.stage_fonts([self.fonts, other_dir], ["Family One", "Family Two"], self.staging)
        self.assertEqual(len(files), 2)
        self.assertEqual(len({font["file"] for font in files}), 2)
        self.assertEqual({font["sourceFile"] for font in files}, {"same.ttf"})

    def test_collection_keeps_all_faces_in_selected_file(self):
        path = self.fonts / "families.ttc"
        with TTCollection() as collection:
            collection.fonts = [font_face("Berkeley Mono"), font_face("Another Family")]
            collection.save(path)
        files = self.stage(["Berkeley Mono"])
        self.assertEqual(len(files), 1)
        self.assertEqual(files[0]["families"], ["Another Family", "Berkeley Mono"])
        self.assertEqual((self.staging / files[0]["file"]).read_bytes(), path.read_bytes())

    def test_missing_optional_family_does_not_create_staging(self):
        output = io.StringIO()
        with redirect_stdout(output):
            files = host_fonts.stage_fonts([self.fonts], ["Berkeley Mono"], self.staging)
        self.assertEqual(files, [])
        self.assertFalse(self.staging.exists())
        self.assertIn("Optional host font family not found: Berkeley Mono", output.getvalue())

    def test_inventory_skips_invalid_files_and_duplicate_symlinks(self):
        path = self.save_font("valid.ttf", "Berkeley Mono")
        (self.fonts / "alias.ttf").symlink_to(path)
        (self.fonts / "invalid.otf").write_bytes(b"not a font")
        errors = io.StringIO()
        with redirect_stderr(errors):
            inventory = host_fonts.discover_fonts([self.fonts])
        self.assertEqual(len(inventory), 1)
        self.assertIn("Skipping unreadable host font", errors.getvalue())

    def test_transfer_verifies_guest_bytes_and_detects_corruption(self):
        self.save_font("font with spaces.ttf", "Berkeley Mono")
        files = self.stage(["Berkeley Mono"])
        guest = LocalGuest(self.root / "guest")
        with redirect_stdout(io.StringIO()):
            host_fonts.install_fonts(guest, files, self.staging)
        record = files[0]
        self.assertEqual((guest.home / "Library/Fonts" / record["file"]).read_bytes(), (self.staging / record["file"]).read_bytes())
        with self.assertRaisesRegex(ValueError, "checksum mismatch"):
            host_fonts.install_fonts(LocalGuest(self.root / "corrupt guest", corrupt=True), files, self.staging)

    def test_font_inventory_does_not_require_a_flake_or_mac(self):
        self.save_font("test.ttf", "Berkeley Mono")
        output = io.StringIO()
        with (
            patch("sys.argv", ["bake-macos", "--list-host-fonts"]),
            patch("bake.host_font_directories", return_value=[self.fonts]),
            redirect_stdout(output),
        ):
            bake.main()
        self.assertEqual(json.loads(output.getvalue())[0]["families"], ["Berkeley Mono"])


if __name__ == "__main__":
    unittest.main()
