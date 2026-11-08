"""sheet3d (SWD6 v2): установившаяся нить ротора Фёппля за гребнем хребта. Описание и пределы модели — README.md."""
from .foppl import foppl_vortex, velocity_foppl

__all__ = ["foppl_vortex", "velocity_foppl"]
