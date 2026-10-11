"""End-to-end checks for the portable-project movie converter."""

import json
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path


COMMAND = Path(__file__).resolve().parents[1] / "manimbler"
FFMPEG = shutil.which("ffmpeg")
FFPROBE = shutil.which("ffprobe")
MANIM_SLIDES = (shutil.which("manim-slides") or
                str(Path.home() / "Library/Application Support/Manimble/python/bin/manim-slides"))


@unittest.skipUnless(FFMPEG and FFPROBE, "ffmpeg and ffprobe are required")
class ManimblerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def make_package(self, *, missing_video=False):
        package = self.root / "demo.manimble"
        with zipfile.ZipFile(package, "w") as archive:
            archive.writestr("demo/manimble-project.json", json.dumps({
                "format": "manimble-project", "version": 1, "deckPath": "deck"
            }))
            archive.writestr("demo/deck/order.txt", "Red\nBlue\n")
            for scene, color in (("Blue", "blue"), ("Red", "red")):
                video = f"slides/files/{scene}/forward.mp4"
                archive.writestr(f"demo/deck/slides/{scene}.json", json.dumps({
                    "resolution": [160, 90],
                    "slides": [{"type": "video", "file": video, "rev_file": video,
                                "playback_rate": 2.0 if scene == "Red" else 1.0}],
                }))
                if missing_video and scene == "Red":
                    continue
                path = self.root / f"{scene}.mp4"
                subprocess.run([
                    FFMPEG, "-hide_banner", "-loglevel", "error", "-nostdin", "-y",
                    "-f", "lavfi", "-i", f"color=c={color}:s=160x90:r=10:d=0.4",
                    "-an", "-c:v", "libx264", "-pix_fmt", "yuv420p", str(path),
                ], check=True)
                archive.write(path, f"demo/deck/{video}")
        return package

    def pixel(self, movie, second):
        result = subprocess.run([
            FFMPEG, "-hide_banner", "-loglevel", "error", "-nostdin",
            "-ss", str(second), "-i", str(movie), "-frames:v", "1",
            "-vf", "scale=1:1", "-f", "rawvideo", "-pix_fmt", "rgb24", "-",
        ], capture_output=True, check=True)
        self.assertEqual(len(result.stdout), 3)
        return result.stdout

    def run_command(self, *args):
        return subprocess.run([sys.executable, str(COMMAND), *map(str, args)],
                              capture_output=True, text=True)

    def test_convert_follows_slide_order_and_holds_each_build(self):
        package = self.make_package()
        movie = self.root / "movie.mp4"
        result = subprocess.run([
            sys.executable, str(COMMAND), "--convert", str(package),
            "--output", str(movie), "--hold", "0.2", "--fps", "10",
        ], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("2 slides, 2 builds", result.stdout)
        probe = subprocess.run([
            FFPROBE, "-v", "error", "-show_entries", "format=duration",
            "-of", "json", str(movie),
        ], capture_output=True, text=True, check=True)
        self.assertAlmostEqual(float(json.loads(probe.stdout)["format"]["duration"]), 1.0, delta=0.11)
        red = self.pixel(movie, 0.1)
        blue = self.pixel(movie, 0.8)
        self.assertGreater(blue[2], blue[0] + 100)
        self.assertGreater(red[0], red[2] + 100)

    def test_missing_build_fails_without_writing_output(self):
        package = self.make_package(missing_video=True)
        movie = self.root / "movie.mp4"
        result = subprocess.run([
            sys.executable, str(COMMAND), "--convert", str(package), "-o", str(movie),
        ], capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn("Missing media", result.stderr)
        self.assertFalse(movie.exists())

    def test_check_and_info(self):
        package = self.make_package()
        checked = self.run_command("--check", package)
        self.assertEqual(checked.returncode, 0, checked.stderr)
        self.assertIn("2 slides, 2 builds", checked.stdout)
        details = self.run_command("--info", package, "--hold", "0.2")
        self.assertEqual(details.returncode, 0, details.stderr)
        self.assertIn("1. Red (1 builds)", details.stdout)
        self.assertIn("2. Blue (1 builds)", details.stdout)
        self.assertIn("Estimated MP4 time with 0.2 s holds:", details.stdout)

    def test_check_reports_missing_media(self):
        package = self.make_package(missing_video=True)
        checked = self.run_command("--check", package)
        self.assertEqual(checked.returncode, 1)
        self.assertIn("Missing media", checked.stderr)

    def test_subset_conversion_uses_deck_order(self):
        package = self.make_package()
        movie = self.root / "selection.mp4"
        converted = self.run_command("--convert", package, "--slides", "2,1", "-o", movie,
                                     "--hold", "0", "--fps", "10")
        self.assertEqual(converted.returncode, 0, converted.stderr)
        self.assertIn("2 slides, 2 builds", converted.stdout)
        self.assertGreater(self.pixel(movie, 0.05)[0], 100)
        selected = self.root / "selected-blue.mp4"
        converted = self.run_command("--convert", package, "--slides", "Blue", "-o", selected,
                                     "--hold", "0", "--fps", "10")
        self.assertEqual(converted.returncode, 0, converted.stderr)
        self.assertIn("1 slides, 1 builds", converted.stdout)
        self.assertGreater(self.pixel(selected, 0.05)[2], 100)

    def test_extract_and_reject_traversal(self):
        package = self.make_package()
        target = self.root / "unpacked"
        extracted = self.run_command("--extract", package, "-o", target)
        self.assertEqual(extracted.returncode, 0, extracted.stderr)
        self.assertTrue((target / "deck/slides/Red.json").is_file())
        self.assertTrue((target / "deck/slides/files/Blue/forward.mp4").is_file())
        with zipfile.ZipFile(package, "a") as archive:
            archive.writestr("../escape.txt", "unsafe")
        rejected = self.run_command("--extract", package, "-o", self.root / "unsafe")
        self.assertEqual(rejected.returncode, 1)
        self.assertIn("Invalid archive entry", rejected.stderr)
        self.assertFalse((self.root / "unsafe").exists())

    @unittest.skipUnless(Path(MANIM_SLIDES).is_file(), "Manim Slides is required")
    def test_pdf_and_html_export(self):
        package = self.make_package()
        pdf = self.root / "slides.pdf"
        result = self.run_command("--convert", package, "--to", "pdf", "-o", pdf)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(pdf.read_bytes().startswith(b"%PDF"))
        html = self.root / "slides.html"
        result = self.run_command("--convert", package, "--to", "html", "--slides", "1",
                                  "-o", html)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("slides_assets/", html.read_text())
        self.assertTrue(any((self.root / "slides_assets").iterdir()))


if __name__ == "__main__":
    unittest.main()
