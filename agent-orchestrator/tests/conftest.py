import pathlib
import sys

ASSETS_DIR = pathlib.Path(__file__).parent.parent / "assets"
sys.path.insert(0, str(ASSETS_DIR))
