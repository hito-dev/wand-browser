import importlib.util
import pathlib
import plistlib
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
VERIFIER_PATH = ROOT / "scripts/verify-testflight.py"
verifier = None
if VERIFIER_PATH.exists():
    spec = importlib.util.spec_from_file_location("release_verifier", VERIFIER_PATH)
    verifier = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(verifier)


@unittest.skipUnless(VERIFIER_PATH.exists(), "Local release preparation helper is not present")
class ReleaseIdentityTests(unittest.TestCase):
    def test_rejects_wrong_release_identity_before_signing(self):
        baseline = {"CFBundleIdentifier": "ai.hito.wand", "CFBundleShortVersionString": "0.3.2", "CFBundleVersion": "9"}
        cases = [("CFBundleIdentifier", "ai.hito.wand.dev", "Wrong bundle ID"),
                 ("CFBundleShortVersionString", "0.2.3", "Wrong marketing version"),
                 ("CFBundleVersion", "8", "Wrong build number")]
        with tempfile.TemporaryDirectory() as directory:
            app = pathlib.Path(directory)
            for field, incorrect, message in cases:
                with self.subTest(field=field):
                    info = dict(baseline)
                    info[field] = incorrect
                    (app / "Info.plist").write_bytes(plistlib.dumps(info))
                    with self.assertRaisesRegex(ValueError, message):
                        verifier.verify(app, "9", True, "ai.hito.wand", "0.3.2", "KUV9LF7VX6")
