import pathlib
import shutil
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
CHECK = ROOT / "Tests" / "vot_proto_check.c"
CODEC = ROOT / "Tweak" / "Features" / "Translation" / "VOTProto.m"
VECTORS = ROOT / "Tests" / "data" / "vot_vectors.txt"


@unittest.skipUnless(shutil.which("cc"), "C compiler not available")
class VOTProtoTests(unittest.TestCase):
    def test_codec_matches_vot_js_vectors(self):
        with tempfile.TemporaryDirectory() as directory:
            binary = pathlib.Path(directory) / "vot_proto_check"
            subprocess.run(
                ["cc", "-std=c99", "-Wall", "-Wextra", "-Werror", "-x", "c",
                 str(CODEC), "-x", "c", str(CHECK), "-o", str(binary)],
                check=True,
            )
            result = subprocess.run(
                [str(binary), str(VECTORS)], capture_output=True, text=True
            )
            self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
