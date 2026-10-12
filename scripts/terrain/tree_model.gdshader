// Материал деревьев-моделей (кора, хвоя/листва, импостор) с покачиванием от ветра (VR-17).
// Повторяет StandardMaterial3D из .glb (текстура, альфа-отсечение) + смещение вершин по ветру:
// чем выше над основанием, тем сильнее (квадратично), порывы — тем же полем, что колышет траву.
// Параметры задают TerrainTreeModels (материал) и TerrainWind (ветер).
// Мягкая смена LOD: у границы экземпляр стоит в обоих LOD (TreePlacer), код в альфе цвета экземпляра
// (1 — нет; 0,1/0,2 — уходит/проявляется у lod_d.x; 0,3/0,4 — у lod_d.y). Доля t по живому
// расстоянию до камеры; пиксель виден у уходящего при шум ≥ t, у проявляющегося при шум < t —
// с одним шумом экрана оба LOD дополняют друг друга, без прозрачности (discard).
shader_type spatial;
render_mode cull_disabled, diffuse_burley;

#include "res://scripts/terrain/terrain_wind.gdshaderinc"
#include "res://scripts/terrain/cloud_shadow.gdshaderinc"

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec4 albedo_color : source_color = vec4(1.0);
uniform bool alpha_clip = false;
uniform float alpha_threshold = 0.5;
uniform float roughness_value = 0.9;
uniform float model_height = 20.0;     // высота модели (меша), м
uniform float sway_top_m = 0.6;        // отклонение макушки при ветре wind_full_ms, м
uniform float sway_hz = 0.25;          // частота качания, Гц
// ветки (вторичный изгиб): вес растёт с удалением вершины от оси ствола, нормирован габаритом кроны
uniform float branch_amp_m = 0.3;      // размах конца ветки при ветре wind_full_ms, м (при масштабе 1)
uniform float branch_hz = 0.9;         // частота ветки, Гц (у каждой ветки своя фаза и ±25%)
uniform float branch_reach_k = 0.22;   // вылет кроны от оси, доля model_height
uniform float leaf_flutter_m = 0.04;   // трепет листвы на конце ветки, м
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
uniform vec2 lod_d = vec2(60.0, 180.0); // границы LOD, м (configs/world.json → trees.lod_distances_m)
uniform float lod_fade_m = 10.0;        // ширина растворения, м (trees.lod_fade_m)

varying vec3 v_color;
varying float v_dist;
varying float v_crown;
// тень облаков: множитель прямого солнца (cloud_shadow.gdshaderinc) — в light()
varying float v_cs_sun;
// окно шума, в котором пиксель виден: [v_fade.x, v_fade.y) (растворение на смене LOD)
varying vec2 v_fade;

void vertex() {
	vec3 base = MODEL_MATRIX[3].xyz;
	v_dist = length(base.xz - CAMERA_POSITION_WORLD.xz);
	v_fade = vec2(0.0, 2.0);
	int code = int(COLOR.a * 10.0 + 0.5);
	if (code >= 1 && code <= 4) {
		float t = clamp((v_dist - (code <= 2 ? lod_d.x : lod_d.y)) / lod_fade_m + 0.5, 0.0, 1.0);
		v_fade = (code % 2 == 1) ? vec2(t, 2.0) : vec2(0.0, t);
	}
	float spd = length(wind_vec);
	vec2 d = spd > 0.05 ? wind_vec / spd : vec2(1.0, 0.0);
	float amp = smoothstep(0.3, wind_full_ms, spd);
	vec2 p = base.xz - d * TIME * spd * wind_gust_speed_k;
	float g = wind_noise(p / wind_gust_scale_m);
	float ph = wind_hash(floor(base.xz)) * 6.2832;
	float t = clamp(VERTEX.y / max(model_height, 0.1), 0.0, 1.0);
	float sway = amp * sway_top_m * t * t
			* (0.5 + 0.7 * g + 0.25 * sin(TIME * sway_hz * 6.2832 + ph));
	// ветки: только ближние LOD (за lod_d.y плавно гаснут), у земли и у оси ствола неподвижно
	mat3 m = mat3(MODEL_MATRIX);
	float s2 = max(dot(m[0], m[0]), 1e-6);
	float reach = max(model_height * branch_reach_k, 0.1);
	float rr = length(VERTEX.xz) / reach;
	float bw = smoothstep(0.15, 0.9, rr) * smoothstep(0.12, 0.4, t)
			* (1.0 - smoothstep(lod_d.y, lod_d.y + lod_fade_m * 2.0, v_dist)) * amp;
	vec3 disp = vec3(d.x, 0.0, d.y) * sway;
	if (bw > 0.0) {
		// «ветка» — сектор азимута (8) и ярус высоты (6): свои фаза и частота
		float az = floor((atan(VERTEX.z, VERTEX.x) + 3.1416) * 1.2732);
		float bph = wind_hash(vec2(az, floor(t * 6.0)) + floor(base.xz * 0.37)) * 6.2832;
		float f = branch_hz * (0.75 + 0.5 * fract(bph * 1.618));
		// порыв бежит по кроне (мелкое поле, сдвиг по ветру)
		float g2 = wind_noise((p + VERTEX.xz) / (wind_gust_scale_m * 0.12));
		float w = sin(TIME * f * 6.2832 + bph - dot(VERTEX.xz, d) * 0.8) * (0.55 + 0.9 * g2);
		float wv = sin(TIME * f * 6.2832 * 1.3 + bph * 1.7);
		float sc = sqrt(s2);
		disp += (vec3(d.x, 0.0, d.y) * (0.6 + 0.5 * g2) * w * 0.5 + vec3(-d.y, 0.0, d.x) * w * 0.25
				+ vec3(0.0, 0.5 * wv, 0.0)) * bw * branch_amp_m * sc;
		// листва: мельче и быстрее, фаза по положению вершины, амплитуда к концам веток
		float fl = bw * leaf_flutter_m * sc * sin(TIME * 5.0 + dot(VERTEX, vec3(3.1, 1.7, 2.3)) + ph);
		disp += vec3(fl, 0.4 * fl, -fl);
	}
	// мир → локальные координаты экземпляра (поворот вокруг Y + равномерный масштаб)
	VERTEX += transpose(m) * disp / s2;
	v_color = COLOR.rgb;
	v_crown = UV2.x; // 1 — карточка кроны с нормалями «от центра кроны» (build_trees.py), 0 — кора, импостор
	v_cs_sun = cloud_sun_at(base);
	// целиком растворённый экземпляр — вырожденные треугольники (не растеризуется)
	if (v_fade.x >= 1.0 || v_fade.y <= 0.0) {
		VERTEX = vec3(0.0);
	}
}

void fragment() {
	// шум экрана (interleaved gradient noise) — порог растворения
	float n = fract(52.9829189 * fract(dot(FRAGCOORD.xy, vec2(0.06711056, 0.00583715))));
	if (n < v_fade.x || n >= v_fade.y) {
		discard;
	}
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
	AO = cloud_sky_ao(v_cs_sun);
}

// Встроенное освещение, прямое солнце — в тени облаков слабее (cloud_shadow.gdshaderinc).
void light() {
	cloud_light(NORMAL, VIEW, LIGHT, LIGHT_COLOR, ATTENUATION, LIGHT_IS_DIRECTIONAL, v_cs_sun,
			ALBEDO, ROUGHNESS, METALLIC, v_crown > 0.5 ? 0.0 : 0.2, vec3(0.0), CS_BURLEY, SPECULAR_AMOUNT,
			DIFFUSE_LIGHT, SPECULAR_LIGHT);
}
