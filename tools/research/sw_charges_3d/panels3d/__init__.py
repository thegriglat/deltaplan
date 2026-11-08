"""panels3d (SWD2): треугольные панели-источники по рельефу, внутренний слой Jackson–Hunt, отрыв по линиям тока."""
from .terrain import Terrain3D, bg_uniform, bg_profile, bg_zero
from .mesh import Panels, build_panels
from .api import assemble, solve, velocity, surface_flow
from .jh import hill_length, velocity_jh
from .sep import separation3d

__all__ = ["Terrain3D", "Panels", "build_panels", "bg_uniform", "bg_profile", "bg_zero", "assemble", "solve",
           "velocity", "surface_flow", "hill_length", "velocity_jh", "separation3d"]
