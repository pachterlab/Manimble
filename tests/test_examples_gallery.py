"""Checks the website's examples gallery (examples/gallery): every entry in examples.json is well formed and its
package is a valid .manimble file, and every package in the folder is listed."""

import json
import subprocess
import sys
import unittest
from datetime import date
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
GALLERY = ROOT / "examples" / "gallery"
FIELDS = {"file", "title", "authors", "institution", "date", "keywords", "description"}


class ExamplesGalleryTests(unittest.TestCase):
    def setUp(self):
        self.examples = json.loads((GALLERY / "examples.json").read_text(encoding="utf-8"))

    def test_entries_are_well_formed(self):
        self.assertIsInstance(self.examples, list)
        files = []
        for entry in self.examples:
            with self.subTest(entry=entry.get("file")):
                self.assertLessEqual(set(entry), FIELDS, "unknown fields")
                for field in ("file", "title", "authors"):
                    self.assertTrue(isinstance(entry.get(field), str) and entry[field].strip(), f"{field} is required")
                self.assertRegex(entry["file"], r"^[a-z0-9][a-z0-9._-]*\.manimble$")
                self.assertTrue((GALLERY / entry["file"]).is_file(), "the package is missing")
                if "date" in entry:
                    date.fromisoformat(entry["date"])
                if "keywords" in entry:
                    self.assertTrue(all(isinstance(k, str) and k for k in entry["keywords"]))
                for field in ("institution", "description"):
                    if field in entry:
                        self.assertIsInstance(entry[field], str)
                files.append(entry["file"])
        self.assertEqual(len(files), len(set(files)), "a package is listed twice")
        unlisted = sorted({p.name for p in GALLERY.glob("*.manimble")} - set(files))
        self.assertEqual(unlisted, [], "packages in examples/gallery that examples.json does not list")

    def test_packages_are_valid(self):
        for entry in self.examples:
            package = GALLERY / entry["file"]
            self.assertLess(package.stat().st_size, 100 * 1024 * 1024, f"{package.name}: GitHub refuses files over 100 MB")
            result = subprocess.run([sys.executable, str(ROOT / "manimbler"), "--check", str(package)],
                                    capture_output=True, text=True, stdin=subprocess.DEVNULL)
            self.assertEqual(result.returncode, 0, f"{package.name}: {result.stderr}")


if __name__ == "__main__":
    unittest.main()
