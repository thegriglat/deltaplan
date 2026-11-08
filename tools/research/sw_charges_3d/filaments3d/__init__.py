"""filaments3d — замкнутые вихревые нити (SWD3). Описание и пределы модели — README.md."""
from .core import Filaments, imbalance, induced, line, ring, self_velocity
from .dynamics import relabel, shed, step

__all__ = ["Filaments", "imbalance", "induced", "self_velocity", "ring", "line", "shed", "step", "relabel"]
