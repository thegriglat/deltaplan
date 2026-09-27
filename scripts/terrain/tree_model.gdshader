// Материал деревьев-моделей (кора, хвоя/листва, импостор) с покачиванием от ветра (VR-17).
// Повторяет StandardMaterial3D из .glb (текстура, альфа-отсечение) + смещение вершин по ветру:
// чем выше над основанием, тем сильнее (квадратично), порывы — тем же полем, что колышет траву.
// Параметры задают TerrainTreeModels (материал) и TerrainWind (ветер).
shader_type spatial;
render_mode cull_disabled, diffuse_burley;

#include "res://scripts/terrain/terrain_wind.gdshaderinc"

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec4 albedo_color : source_color = vec4(1.0);
uniform bool alpha_clip = false;
uniform float alpha_threshold = 0.5;
uniform float roughness_value = 0.9;
uniform float model_height = 20.0;     // высота модели (меша), м
uniform float sway_top_m = 0.6;        // отклонение макушки при ветре wind_full_ms, м
uniform float sway_hz = 0.25;          // частота качания, Гц

varying vec3 v_color;

void vertex() {
	vec3 base = MODEL_MATRIX[3].xyz;
	float spd = length(wind_vec);
	vec2 d = spd > 0.05 ? wind_vec / spd : vec2(1.0, 0.0);
	float amp = smoothstep(0.3, wind_full_ms, spd);
	vec2 p = base.xz - d * TIME * spd * wind_gust_speed_k;
	float g = wind_noise(p / wind_gust_scale_m);
	float ph = wind_hash(floor(base.xz)) * 6.2832;
	float t = clamp(VERTEX.y / max(model_height, 0.1), 0.0, 1.0);
	float sway = amp * sway_top_m * t * t
			* (0.5 + 0.7 * g + 0.25 * sin(TIME * sway_hz * 6.2832 + ph));
	// мелкая дрожь листвы
	float flutter = amp * 0.05 * t * sin(TIME * 5.0 + dot(VERTEX, vec3(3.1, 1.7, 2.3)) + ph);
	vec3 disp = vec3(d.x, 0.0, d.y) * sway + vec3(flutter, 0.0, -flutter);
	// мир → локальные координаты экземпляра (поворот вокруг Y + равномерный масштаб)
	mat3 m = mat3(MODEL_MATRIX);
	float s2 = max(dot(m[0], m[0]), 1e-6);
	VERTEX += transpose(m) * disp / s2;
	v_color = COLOR.rgb;
}

void fragment() {
	vec4 c = texture(albedo_tex, UV) * albedo_color;
	ALBEDO = c.rgb * v_color;
	ALPHA = alpha_clip ? c.a : 1.0;
	ALPHA_SCISSOR_THRESHOLD = alpha_threshold;
	ROUGHNESS = roughness_value;
	SPECULAR = 0.2;
}
