#!/usr/bin/env python3
"""Validate the Finder settings inside a mounted Coddle installer."""
from pathlib import Path
from ds_store import DSStore


def verify(volume):
    volume = Path(volume)
    assert (volume / "Applications").is_symlink()
    assert (volume / "Applications").readlink() == Path("/Applications")
    assert (volume / ".background.tiff").stat().st_size > 0
    with DSStore.open(str(volume / ".DS_Store"), "r") as store:
        assert store["Coddle.app"]["Iloc"] == (166, 190)
        assert store["Applications"]["Iloc"] == (474, 190)
        window = store["."]["bwsp"]
        assert window["WindowBounds"] == "{{200, 160}, {640, 400}}"
        assert not any(window[k] for k in ("ShowToolbar", "ShowSidebar", "ShowStatusBar", "ShowPathbar"))
        icons = store["."]["icvp"]
        assert icons["arrangeBy"] == "none" and icons["iconSize"] == 96
        assert icons["backgroundType"] == 2 and icons["backgroundImageAlias"]
    print("PASS: mounted Finder layout, background, window size and Applications target")


if __name__ == "__main__":
    import sys
    verify(sys.argv[1])
