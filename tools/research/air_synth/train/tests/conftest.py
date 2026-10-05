import sys
from pathlib import Path

TRAIN = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TRAIN))
