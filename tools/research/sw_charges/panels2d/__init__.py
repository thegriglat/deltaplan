"""panels2d (SW6): панели постоянных источников по линии рельефа + дискретные вихри Лэмба — Озеена, 2D x–z."""
from .core import (Terrain, Panels, Vortices, build_panels, bg_uniform, bg_profile,
                   solve, velocity, step, residual)

__all__ = ["Terrain", "Panels", "Vortices", "build_panels", "bg_uniform", "bg_profile",
           "solve", "velocity", "step", "residual"]
