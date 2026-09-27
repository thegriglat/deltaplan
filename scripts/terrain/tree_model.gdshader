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
// смягчение вдали (отзыв пилота: деревья на земле слишком резкие) — та же логика, что у импостеров
// forest_impostors.gdshader; модели видны примерно до inner_end_m (~300–500 м), дальше — билборды.
// та же кривая, что у forest_impostors (300 → 1200 м): в полосе передачи 350–500 м модели и
// билборды смягчены одинаково (при 500 м модели были уже «в полную силу» — бледнее билбордов)
uniform float far_soft_start_m = 300.0;
uniform float far_soft_full_m = 1200.0;
uniform float far_desaturate = 0.4;
uniform float far_contrast = 0.35;
uniform float far_canopy_luma = 0.32;
uniform float far_edge_soft_k = 3.0;

varying vec3 v_color;
varying float v_dist;
varying float v_crown;

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
	v_crown = UV2.x; // 1 — карточка кроны с нормалями «от центра кроны» (build_trees.py), 0 — кора, импостор
	v_dist = length(base.xz - CAMERA_POSITION_WORLD.xz);
}

void fragment() {
	vec4 c = texture(albedo_tex, UV) * albedo_color;
	vec3 rgb = c.rgb * v_color;
	// вдали мягче: та же логика, что у impostor-билбордов (forest_impostors.gdshader) —
	// бледнее и меньше контраст кроны, мягкий (не бинарный) край альфа-отсечения
	float ft = smoothstep(far_soft_start_m, far_soft_full_m, v_dist);
	float luma = dot(rgb, vec3(0.299, 0.587, 0.114));
	rgb = mix(rgb, vec3(luma), far_desaturate * ft);
	rgb = mix(rgb, vec3(mix(luma, far_canopy_luma, 0.6)), far_contrast * ft);
	ALBEDO = rgb;
	if (alpha_clip) {
		// нормали карточек кроны — «от центра кроны» (build_trees.py, crown_normals; метка UV2.x = 1).
		// Godot у изнанки двусторонней грани переворачивает нормаль — возвращаем, чтобы обе стороны
		// карточки светились одинаково (иначе крона пятнистая: половина карточек тёмная)
		if (v_crown > 0.5) {
			NORMAL = FRONT_FACING ? NORMAL : -NORMAL;
		}
		float edge = fwidth(c.a) * mix(0.75, far_edge_soft_k, ft);
		ALPHA = smoothstep(alpha_threshold - edge, alpha_threshold + edge, c.a);
		ALPHA_SCISSOR_THRESHOLD = mix(alpha_threshold, alpha_threshold * 0.05, ft);
	} else {
		ALPHA = 1.0;
	}
	ROUGHNESS = roughness_value;
	// у крон нормали смотрят вверх/наружу — на скользящем взгляде издали блик неба (Френель)
	// выбеливал лес в серые «призраки»; хвоя и листва матовые
	SPECULAR = v_crown > 0.5 ? 0.0 : 0.2;
}
