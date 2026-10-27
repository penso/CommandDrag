"""Check the actual mounted installer, without launching Finder or the app."""

import os
from pathlib import Path
import subprocess
import sys
import tempfile

from ds_store import DSStore


with tempfile.TemporaryDirectory(prefix="commanddrag-dmg-") as directory:
    mount = Path(directory) / "volume"
    mount.mkdir()
    subprocess.run(
        ["hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", str(mount), sys.argv[1]],
        check=True,
    )
    try:
        assert (mount / "Applications").is_symlink(), "Missing Applications shortcut"
        assert os.readlink(mount / "Applications") == "/Applications", "Incorrect shortcut target"
        app = mount / "CommandDrag.app"
        subprocess.run(["codesign", "--verify", "--strict", str(app)], check=True)
        for arch in ("arm64", "x86_64"):
            subprocess.run(["lipo", str(app / "Contents/MacOS/CommandDrag"), "-verify_arch", arch], check=True)
        with DSStore.open(str(mount / ".DS_Store"), "r") as store:
            assert store["CommandDrag.app"]["Iloc"] == (170, 200), "Incorrect app placement"
            assert store["Applications"]["Iloc"] == (470, 200), "Incorrect shortcut placement"
            assert store["."]["icvp"]["backgroundType"] == 2, "Missing install instructions background"
        print("DMG verified: universal signed app, Applications symlink, and Finder layout.")
    finally:
        result = subprocess.run(["hdiutil", "detach", str(mount)], check=False)
        if result.returncode:
            subprocess.run(["hdiutil", "detach", "-force", str(mount)], check=True)
