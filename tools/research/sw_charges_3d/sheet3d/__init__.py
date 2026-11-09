"""sheet3d (SWD6 v5): нить Фёппля (отрицательный результат) и установившийся вихревой слой из рядов. Описание — README.md."""
from .foppl import foppl_vortex, velocity_foppl
from .sheet import Sheet, build_sheet, velocity_sheet

__all__ = ["foppl_vortex", "velocity_foppl", "Sheet", "build_sheet", "velocity_sheet"]
