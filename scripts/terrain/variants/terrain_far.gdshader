// Вариант «far» (SL-К6, дальние LOD ≥ variant_far_lod и фоновый слой на всех пресетах, решение Q2): без мелких деталей, текстур травы, ветра по траве (подсос термиков остаётся) и воде, троп, блеска, выходов породы, скальной поверхности и рисунка породы, фактуры луга, извилин кромок. Форма гор вдали (RELIEF_DETAIL, вершины) остаётся — иначе ступенька высот на стыке LOD и пики без подъёма (SL-23). В ближних вариантах эти части гаснут к порогу (far_fade_m).
shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;
#define T_DETAIL_OFF
#define T_GRASS_TEX_OFF
#define T_GRASS_WIND_OFF
#define T_MEADOW_DETAIL_OFF
#define T_OUTCROP_OFF
#define T_ROCK_DETAIL_OFF
#define T_ROCK_SURFACE_OFF
#define T_SL_TRAILS_OFF
#define T_SL_WIND_SHEEN_OFF
#define T_SURFACE_WARP_OFF
#define T_WATER_WIND_OFF
#include "res://scripts/terrain/terrain_main.gdshaderinc"
