// Картинка сочнее (модуль scene-look, контракт SL-К1): весь новый шейдерный код модуля — здесь,
// функции и uniform-ы sl_*. Ключ configs/world.json → scene_look.<k> попадает в uniform sl_<k>
// (TerrainRenderer.apply_scene_look_params); значения по умолчанию ниже — «модуль выключен»
// (картинка как до модуля), включает конфиг. Подключается в terrain.gdshader (после
// terrain_common), forest_impostors.gdshader; может — в grass, tree_model, road.
// Рантайм-uniform-ы (не ключи конфига) ставит Terrain: sl_lat_deg, sl_doy (SL-К2), sl_sun_dir,
// sl_sky_up, sl_ground_low (свет неба по высоте солнца, TerrainRenderer.scene_look_sky).

// --- SL-К2: место и дата полёта ---
uniform float sl_lat_deg = 0.0;      // широта центра места, градусы, + север
uniform float sl_doy = 196.0;        // день года 1…366 (по умолчанию 15 июля)

// --- SL-2: свет — небо сверху, земля снизу ---
uniform bool sl_light_enabled = false;
uniform vec3 sl_sun_dir = vec3(0.0, 1.0, 0.0);   // направление НА солнце (мир)
// Рассеянный свет Godot (небо sky.gdshader × ambient_light_energy × sky_energy × доля неба), линейный:
// верхняя полусфера (≈ цвет зенита) и нижняя (sky.ground_bottom_color — серо-зелёная, без солнца).
uniform vec3 sl_sky_up = vec3(0.0);
uniform vec3 sl_ground_low = vec3(0.0);
uniform vec3 sl_ground_albedo = vec3(0.06, 0.09, 0.04);  // альбедо окрестной земли (луг/лес), линейное
uniform float sl_ground_local = 0.5;  // доля собственного цвета точки в «земле снизу»
// Полог вдали: альбедо (яркость Y, линейная, в среднем по полусфере) хвойного / лиственного
uniform vec2 sl_canopy_albedo = vec2(0.05, 0.08);
uniform vec2 sl_canopy_near_m = vec2(500.0, 2000.0);  // ближе — тон как у моделей деревьев; дальше — альбедо полога
uniform float sl_canopy_floor = 0.5;       // пятна древостоев, опушка, сырость — не темнее ×floor
uniform float sl_canopy_shadow_k = 0.8;    // доля полога в тени соседних крон: 1 − exp(−k·tg зенитного угла солнца к склону)
uniform float sl_canopy_hide_p = 2.0;      // скрытие теней по фазовому углу: ((1 + cos ξ) / 2)^p
uniform vec2 sl_canopy_hotspot = vec2(0.3, 0.12);  // горячее пятно: добавка, полуширина (рад)
uniform float sl_tree_far_desat = 0.3;     // импостеры вдали: обесцвечивание (как canopy_far_sat полога)

varying float v_sl_ny;    // мировая нормаль · вверх (доля нижней полусферы в рассеянном свете)
varying float v_sl_ao;    // AO рассеянного света точки
varying float v_sl_sun;   // множитель прямого солнца облаками в точке (для света земли вокруг)

const vec3 SL_LW = vec3(0.2126, 0.7152, 0.0722);

// Земля снизу (вызывать в light(), прибавляет к DIFFUSE_LIGHT): нижняя полусфера неба Godot
// (sl_ground_low) заменяется светом, отражённым от земли: ρ_земли · (солнце на горизонтальную
// поверхность + небо). Доля нижней полусферы в косинусно-взвешенном свете — (1 − n_y) / 2.
// Единицы — как у рассеянного света Godot (LIGHT_COLOR включает π).
void sl_ground_light(inout vec3 diffuse, vec3 light_color, bool directional, vec3 albedo,
		float ny, float ao, float cs) {
	if (!sl_light_enabled || !directional) {
		return;
	}
	vec3 rho = mix(sl_ground_albedo, albedo, sl_ground_local);
	vec3 e = light_color * (max(sl_sun_dir.y, 0.0) * cs / PI) + sl_sky_up;
	float lower = 0.5 * (1.0 - clamp(ny, -1.0, 1.0));
	diffuse += (rho * e - sl_ground_low) * lower * ao;
}

// Дальняя тень рельефа (relief_shadow_*) — только прямое солнце: возвращает (на что разделить
// ALBEDO — снять прежнее затемнение цвета, множитель прямого солнца). Тень остаётся под небом
// (голубая) и светом земли, как тени Godot вблизи. Выключено — (1, 1).
vec2 sl_relief_shadow(bool on, vec3 n, float hz_deg, float dist, float amb, float soft_deg,
		float strength, vec2 near_m) {
	if (!sl_light_enabled || !on) {
		return vec2(1.0);
	}
	vec3 sd = normalize(sl_sun_dir);
	float sun_el = degrees(asin(clamp(sd.y, -1.0, 1.0)));
	float vis = smoothstep(hz_deg - soft_deg, hz_deg + soft_deg, sun_el);
	float ndl = max(dot(n, sd), 0.0);
	float k = strength * smoothstep(near_m.x, near_m.y, dist);
	float sh = (amb + vis * ndl) / (amb + ndl);
	return vec2(mix(1.0, sh, k), mix(1.0, vis, k));
}

// Доля освещённого полога, видимая с направления v, при солнце l на склоне n (геометрическая
// оптика крон, как у моделей Ли–Страхлера / горячего пятна Хапке): тени крон занимают
// s = 1 − exp(−k·tg θs) полога (θs — зенитный угол солнца к склону); со стороны солнца их
// закрывают сами кроны ((1 + cos ξ)/2)^p, ξ — угол между взглядом и солнцем; при взгляде вскользь
// к тени прибавляются неосвещённые бока крон (половина боков, доля 1 − cos θv); у ξ → 0 — горячее
// пятно (теней не видно совсем, кроны ярче). Нормировка — вид в надир при солнце 45° к склону:
// средняя яркость полога при этом = альбедо sl_canopy_albedo.
float sl_canopy_lit(vec3 n, vec3 v, vec3 l) {
	float mu = clamp(dot(n, l), 0.02, 1.0);
	float s = 1.0 - exp(-sl_canopy_shadow_k * sqrt(1.0 - mu * mu) / mu);
	// взгляд под углом к пологу: видны и бока крон, а у них в среднем половина — без солнца
	s += (1.0 - s) * (1.0 - clamp(dot(n, v), 0.0, 1.0)) * 0.5;
	float cx = clamp(dot(v, l), -1.0, 1.0);
	float hs = exp(-acos(cx) / max(sl_canopy_hotspot.y, 1e-3));
	float hide = 1.0 - (1.0 - pow(0.5 + 0.5 * cx, sl_canopy_hide_p)) * (1.0 - hs);
	return 1.0 - s * (1.0 - hide) + sl_canopy_hotspot.x * hs;
}

// Множитель прямого солнца на пологе (вес w: доля леса × удаление): видимая доля освещённых крон
// относительно нормировки (надир, солнце 45°).
float sl_canopy_direct(vec3 n, vec3 v, float w) {
	if (!sl_light_enabled || w <= 0.0) {
		return 1.0;
	}
	vec3 l = normalize(sl_sun_dir);
	// нормировка: надир (v = n), солнце 45° к склону — те же формулы
	float s45 = 1.0 - exp(-sl_canopy_shadow_k);
	float h45 = 1.0 - (1.0 - pow(0.5 + 0.5 * 0.70711, sl_canopy_hide_p))
			* (1.0 - exp(-0.7854 / max(sl_canopy_hotspot.y, 1e-3)));
	float ref = 1.0 - s45 * (1.0 - h45);
	return mix(1.0, sl_canopy_lit(n, v, l) / ref, w);
}

// Вес «дальнего» леса по удалению: ближе sl_canopy_near_m.x — как прежде (там лес — модели).
float sl_canopy_far(float dist) {
	return sl_light_enabled ? smoothstep(sl_canopy_near_m.x, sl_canopy_near_m.y, dist) : 0.0;
}

// Тон полога рельефа: fc — после пятен/опушки/сырости, fc0 — до них; fmean — цвет пород,
// con_p — доля хвойных, far_shade — canopy_far_shade (средняя яркость смеси крон и просветов).
// Пятна не темнее ×sl_canopy_floor; вдали средняя яркость — альбедо полога (цвет не меняется).
vec3 sl_canopy_tone(vec3 fc, vec3 fc0, vec3 fmean, float con_p, float dist, float far_shade) {
	if (!sl_light_enabled) {
		return fc;
	}
	fc = max(fc, sl_canopy_floor * fc0);
	float target = mix(sl_canopy_albedo.y, sl_canopy_albedo.x, con_p);
	float base = max(dot(fmean, SL_LW) * far_shade, 1e-4);
	return fc * mix(1.0, target / base, sl_canopy_far(dist));
}

// Импостер дерева вдали: rgb — цвет атласа × tint, mean_luma — средняя яркость ячейки атласа × tint,
// con — хвойное (1) / лиственное (0), t — смягчение вдали (0..1), contrast — far_contrast.
// Контраст мягче к собственной средней (не к общей 0,32), обесцвечивание как у полога, средняя
// яркость вдали — альбедо полога той же породы.
vec3 sl_tree_tone(vec3 rgb, float mean_luma, float con, float dist, float t, float contrast) {
	float luma = dot(rgb, SL_LW);
	float m = max(mean_luma, 1e-4);
	rgb *= mix(1.0, mix(luma, m, 0.6) / max(luma, 1e-4), contrast * t);
	rgb = mix(rgb, vec3(dot(rgb, SL_LW)), sl_tree_far_desat * t);
	float target = mix(sl_canopy_albedo.y, sl_canopy_albedo.x, con);
	return rgb * mix(1.0, target / m, sl_canopy_far(dist));
}
