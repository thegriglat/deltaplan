// Вариант «low» (SL-К6, пресет «Низкий», решение Q2 этапа T-79): без выходов породы, искажения поверхности, рисунка скал и эффектов scene-look, кроме света и сезона.
shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;
#define T_OUTCROP_OFF
#define T_ROCK_SURFACE_OFF
#define T_SL_GLACIER_OFF
#define T_SL_PATCH_OFF
#define T_SL_RIPARIAN_OFF
#define T_SL_ROCK_OFF
#define T_SL_SNOW_OFF
#define T_SL_TRAILS_OFF
#define T_SL_TREELINE_OFF
#define T_SL_WIND_SHEEN_OFF
#define T_SURFACE_WARP_OFF
#include "res://scripts/terrain/terrain_main.gdshaderinc"
