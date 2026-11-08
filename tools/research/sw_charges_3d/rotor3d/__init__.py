"""rotor3d (SWD7): нить ротора с геометрическим замыканием — R и Γ из точек остановки на гребне и в присоединении."""
from .rotor import rotor_vortex, velocity_rotor

__all__ = ["rotor_vortex", "velocity_rotor"]
