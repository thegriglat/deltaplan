// Шейдер рельефа, вариант «full» (контракт SL-К6): все части включены. Тело — terrain_main.gdshaderinc;
// другие варианты — scripts/terrain/variants/terrain_<имя>.gdshader (те же две строки + #define T_<ЧАСТЬ>_OFF).
shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;
#include "res://scripts/terrain/terrain_main.gdshaderinc"
