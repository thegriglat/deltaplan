// Вариант «low_far» (SL-К6, дальние LOD пресета «Низкий»): части far и low вместе (форма гор вдали остаётся, как в far).
shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;
#define T_DETAIL_OFF
#define T_GRASS_TEX_OFF
#define T_GRASS_WIND_OFF
#define T_MEADOW_DETAIL_OFF
#define T_OUTCROP_OFF
#define T_ROCK_DETAIL_OFF
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
#define T_WATER_WIND_OFF
#include "res://scripts/terrain/terrain_main.gdshaderinc"
