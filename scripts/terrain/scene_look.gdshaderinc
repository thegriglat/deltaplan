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
// SL-14: ближе — прямое освещение полога как у моделей (они затеняют себя сами); дальше — видимая доля
// освещённых крон по солнцу и взгляду. Тон (альбедо) от расстояния не зависит: модели и импостеры
// поднимаются до альбедо полога множителем по породам (trees.albedo_gain), см. sl_tree_albedo_enabled.
uniform vec2 sl_canopy_near_m = vec2(500.0, 2000.0);
// SL-14: альбедо крон моделей и импостеров доведено до альбедо полога множителем по породам; полог рельефа
// и импостеры без сшивки по расстоянию. false — как до SL-14 (сшивка по sl_canopy_near_m).
uniform bool sl_tree_albedo_enabled = false;
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

// Вес подгонки тона к альбедо полога: с SL-14 везде 1 (деревья уже того же альбедо), без — по удалению.
float sl_canopy_tone_w(float dist) {
	return sl_tree_albedo_enabled ? 1.0 : sl_canopy_far(dist);
}

// Множитель альбедо породы (SL-14): g — trees.albedo_gain; выключено — 1. Применять к базовому цвету
// (текстура) до сезона SL-6 и просвета SL-7.
float sl_tree_gain(float g) {
	return sl_tree_albedo_enabled ? g : 1.0;
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
	return fc * mix(1.0, target / base, sl_canopy_tone_w(dist));
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
	if (sl_tree_albedo_enabled) {
		return rgb;  // SL-14: альбедо породы уже у полога (множитель gain), сшивки нет
	}
	float target = mix(sl_canopy_albedo.y, sl_canopy_albedo.x, con);
	return rgb * mix(1.0, target / m, sl_canopy_far(dist));
}

#ifndef SL_NO_GROUND   // SL-5 использует vnoise/fbm/forest_mask_g из terrain_common
// --- SL-5: крупные пятна, прибрежная зелень, граница леса ---
// Широта места — SL-К2: sl_lat_deg.
// Крупные пятна тона 0,5–3 км (один fbm из 2 октав) на лугах и в лесу
uniform bool sl_patch_enabled = false;
uniform float sl_patch_scale_m = 2400.0;  // длина волны первой октавы, м (вторая — вдвое короче)
uniform float sl_patch_k = 0.1;           // ± яркость пятен
uniform float sl_patch_hue = 0.5;         // сдвиг тёплый/холодный относительно яркости
// Прибрежная зелень: доля воды маски 10 м в 12 точках двух колец (R, R/2) вокруг пикселя
uniform bool sl_riparian_enabled = false;
uniform float sl_riparian_radius_m = 60.0; // полоса до R от воды, в полную силу — до 0,7·R
uniform float sl_riparian_sat = 0.3;       // средняя доля воды на кольцах, с которой полоса в полную силу
uniform float sl_riparian_k = 0.6;         // подмес сочного grass_color (яркость сохраняется)
uniform float sl_riparian_bright = 0.18;   // добавка яркости
uniform vec2 sl_riparian_fade_m = vec2(800.0, 3000.0);  // вдали полоса уже мельче пикселя — гаснет
// Граница леса от широты: высота (м) в узлах широты (градусы, по |lat|), между ними линейно
uniform bool sl_treeline_enabled = false;
uniform vec4 sl_treeline_lat = vec4(0.0, 30.0, 47.0, 70.0);  // таблица границы леса (SL-К1: каждый ключ — uniform); шейдер берёт готовую sl_treeline_h
uniform vec4 sl_treeline_m = vec4(3900.0, 3500.0, 2100.0, 300.0);
uniform float sl_treeline_h = 0.0;        // высота границы леса на широте места, м (считает Terrain.treeline_height по treeline_lat/_m)
uniform float sl_treeline_thin_m = 300.0;  // ниже границы лес редеет на столько (просветы луга)
uniform vec2 sl_treeline_blend_m = vec2(80.0, 250.0);  // альпийский луг: от границы − x до границы + y
uniform float sl_treeline_top_m = 700.0;   // выше границы + это альпийский тон сходит на нет (камень — прежний код)
uniform vec3 sl_treeline_tint = vec3(1.1, 0.98, 0.72);  // альпийский луг: ниже ростом, охристо-зелёный (множитель цвета луга)
uniform float sl_treeline_gap_m = 70.0;    // размер просветов у границы леса, м

// Пятно тона: −1…1 (низкочастотный fbm), множитель цвета.
vec3 sl_patch_mul(vec2 xz) {
	float t = clamp((fbm(xz / sl_patch_scale_m + vec2(17.3, 5.9), 1) - 0.5) * 4.0, -1.0, 1.0);
	float b = sl_patch_k * t;
	return (1.0 + b) * vec3(1.0 + sl_patch_hue * b, 1.0, 1.0 - sl_patch_hue * b);
}

// Вес альпийского луга на высоте h: растёт от границы леса, сходит выше (камень).
float sl_alpine_w(float h, float tl) {
	return smoothstep(tl - sl_treeline_blend_m.x, tl + sl_treeline_blend_m.y, h)
			* (1.0 - smoothstep(tl + 0.5 * sl_treeline_top_m, tl + sl_treeline_top_m, h));
}

// Луг: пятна, альпийский тон.
vec3 sl_meadow(vec3 c, vec3 wp) {
	if (sl_patch_enabled) {
		c *= sl_patch_mul(wp.xz);
	}
	if (sl_treeline_enabled) {
		float w = sl_alpine_w(wp.y + 40.0 * (vnoise(wp.xz / 180.0) - 0.5), sl_treeline_h);
		c = mix(c, c * sl_treeline_tint, w);
	}
	return c;
}

// Полог (пятна в лесу не нужны — их даёт полог): у границы леса просветы и выше — луг (gcol уже альпийский).
vec3 sl_forest(vec3 f, vec3 gcol, vec3 wp) {
	if (sl_treeline_enabled) {
		float p = smoothstep(sl_treeline_h - sl_treeline_thin_m, sl_treeline_h, wp.y);
		if (p > 0.0) {
			float n2 = vnoise(wp.xz / sl_treeline_gap_m + vec2(4.1, 8.3));
			float gap = smoothstep(0.0, 0.2, p * 1.2 - n2);
			f = mix(f, gcol * 0.85, gap);
		}
	}
	return f;
}

// Средняя доля воды в 4 точках на радиусе 0,65·R (крест, повёрнут на 20°) вокруг xz: маска G 10 м
// (мипов у неё нет, поэтому 4 выборки вместо 12).
float sl_riparian_ring(vec2 xz) {
	float r = 0.65 * sl_riparian_radius_m;
	return 0.25 * (forest_mask_g(xz + vec2(0.940, 0.342) * r) + forest_mask_g(xz + vec2(-0.342, 0.940) * r)
			+ forest_mask_g(xz + vec2(-0.940, -0.342) * r) + forest_mask_g(xz + vec2(0.342, -0.940) * r));
}

// Вес прибрежной полосы по средней доле воды на кольце (на самой воде и далеко от неё — 0).
float sl_riparian_w(float ring_mean, float water, float dist) {
	return smoothstep(0.0, sl_riparian_sat, ring_mean) * (1.0 - water)
			* (1.0 - smoothstep(sl_riparian_fade_m.x, sl_riparian_fade_m.y, dist));
}

// Сочнее и зеленее у воды: к свежему grass_color с сохранением яркости, + яркость.
vec3 sl_riparian_color(vec3 c, vec3 grass, float w) {
	float l = dot(c, SL_LW);
	vec3 lush = grass * (l / max(dot(grass, SL_LW), 1e-3));
	return mix(c, lush, sl_riparian_k * w) * (1.0 + sl_riparian_bright * w);
}

#endif
// --- SL-6: сезон по дате полёта, широте и высоте (контракт SL-К2; зеркало — scripts/terrain/season_look.gd,
// формулы правятся вместе). Фенология — закон Хопкинса: ≈ 4 дня на 1° широты и на 122 м высоты
// (весна позже, осень раньше); южное полушарие — дата сдвинута на полгода; тропики (|φ| < ~23°) без
// сезона. Сезон считается в пикселе (рельеф) / вершине (трава, импостеры, модели) только по высоте:
// дата и широта — uniform-ы. ---
uniform bool sl_season_enabled = false;
uniform vec2 sl_season_hopkins = vec2(4.0, 122.0);      // дней и метров на единицу сдвига
uniform float sl_season_autumn_alt_k = 0.5;             // доля высотного сдвига для осени
uniform float sl_season_lat_ref = 50.0;
uniform vec2 sl_season_dates = vec2(100.0, 280.0);      // начало вегетации, середина окраски берёзы (50°, 0 м)
uniform vec3 sl_season_fresh = vec3(12.0, 40.0, 90.0);
uniform vec2 sl_season_dry_days = vec2(75.0, 135.0);
uniform float sl_season_dry_amount = 0.35;
uniform float sl_season_winter_dry = 0.4;
uniform vec3 sl_season_spring_tint = vec3(0.95, 1.18, 0.8);
uniform vec4 sl_season_leaf_days = vec4(-15.0, 10.0, 18.0, 38.0);
uniform vec2 sl_season_leafout_days = vec2(2.0, 16.0);
uniform float sl_season_larch_lag = 8.0;
uniform float sl_season_larch_share = 0.3;
uniform vec3 sl_season_autumn_color = vec3(0.6, 0.4, 0.07);
uniform vec2 sl_season_autumn_luma = vec2(1.25, 1.1);
uniform vec3 sl_season_bare_color = vec3(0.1, 0.085, 0.07);
uniform vec3 sl_season_crop_green = vec3(0.16, 0.26, 0.05);
uniform vec3 sl_season_crop_ripe = vec3(0.5, 0.37, 0.12);
uniform vec3 sl_season_crop_soil = vec3(0.12, 0.085, 0.055);
uniform vec4 sl_season_crop_days = vec4(10.0, 95.0, 22.0, 30.0);

// Всё, что зависит только от даты и широты (нормированный день берёзы/лиственницы, сдвиг Хопкинса по
// широте, множитель тропиков), считает CPU при смене даты/места (SeasonLook.pre → uniform sl_season_pre
// = (день берёзы, день лиственницы, сдвиг по широте, тропики)); в пикселе остаётся сдвиг по высоте.
uniform vec4 sl_season_pre = vec4(196.0, 196.0, 0.0, 1.0);

// Сезон по подготовленным d (день года 0…365, северное полушарие), sh_lat, trop и высоте.
vec4 sl_season_f(float d, float sh_lat, float trop, float alt, out float rel) {
	rel = 0.0;
	if (!sl_season_enabled) {
		return vec4(0.0);
	}
	float sh_alt = sl_season_hopkins.x * max(alt, 0.0) / sl_season_hopkins.y;
	float spring = sl_season_dates.x + clamp(sh_lat + sh_alt, -60.0, 90.0);
	float fall = clamp(sl_season_dates.y - sh_lat - sl_season_autumn_alt_k * sh_alt, 200.0, 330.0);
	rel = d - spring;
	float green = smoothstep(spring, spring + sl_season_fresh.x, d)
			* (1.0 - smoothstep(spring + sl_season_fresh.y, spring + sl_season_fresh.z, d));
	float dsum = smoothstep(spring + sl_season_dry_days.x, spring + sl_season_dry_days.y, d);
	float autumn = smoothstep(fall + sl_season_leaf_days.x, fall + sl_season_leaf_days.y, d);
	float bare = max(smoothstep(fall + sl_season_leaf_days.z, fall + sl_season_leaf_days.w, d),
			1.0 - smoothstep(spring + sl_season_leafout_days.x, spring + sl_season_leafout_days.y, d));
	float dorm = 1.0 - smoothstep(spring - 10.0, spring + 10.0, d);
	float dry = max(sl_season_dry_amount * dsum, sl_season_winter_dry * max(dorm, bare));
	return trop * vec4(green, dry, autumn, bare);
}

// Состояние сезона (green, dry, autumn, bare), все 0…1: свежесть весенней травы, добавка к сухости
// луга, окраска листвы (не убывает до листопада), листва опала. rel — дней от начала вегетации
// (для полей). Полная форма от (день, широта, высота) — то, что считает CPU-зеркало SeasonLook.state.
vec4 sl_season_x(float doy, float lat, float alt, out float rel) {
	float al = abs(lat);
	float d = doy + (lat < 0.0 ? 182.5 : 0.0);
	d -= 365.0 * floor(d / 365.0);
	float sh_lat = sl_season_hopkins.x * clamp(al - sl_season_lat_ref, -15.0, 20.0);
	return sl_season_f(d, sh_lat, smoothstep(20.0, 26.0, al), alt, rel);
}

vec4 sl_season(float doy, float lat, float alt) {
	float rel;
	return sl_season_x(doy, lat, alt, rel);
}

// Берёза/осина на высоте alt по подготовленным uniform-ам (рельеф, трава).
vec4 sl_season_b(float alt, out float rel) {
	return sl_season_f(sl_season_pre.x, sl_season_pre.z, sl_season_pre.w, alt, rel);
}

// Порода: 1 — берёза/осина, 2 — лиственница (позже на season_larch_lag дней); остальные вечнозелёные.
vec4 sl_season_sp(float kind, float alt) {
	float rel;
	return sl_season_f(kind > 1.5 ? sl_season_pre.y : sl_season_pre.x, sl_season_pre.z, sl_season_pre.w, alt, rel);
}

#ifndef SL_NO_GROUND   // нужен terrain_common (палитра луга, поля); у tree_model.gdshader его нет
// Цвет луга по ряду сухости (как meadow_color_dry в terrain_common, без пятен).
vec3 sl_meadow_ramp(float dry) {
	vec3 c = dry < 0.5 ? mix(grass_color, dry_grass_color, dry * 2.0)
			: mix(dry_grass_color, straw_color, dry * 2.0 - 1.0);
	return mix(vec3(dot(c, SL_LW)), c, grass_saturation);
}

// Луг по сезону: сухость сезона складывается с местной (разность цветов ряда от dryness места
// до dryness + прибавка — пятна и склоны сохраняются), весной — свежая трава светлее и зеленее.
vec3 sl_meadow_season(vec3 gcol, vec4 s) {
	if (!sl_season_enabled) {
		return gcol;
	}
	gcol += sl_meadow_ramp(clamp(dryness + s.y, 0.0, 1.0)) - sl_meadow_ramp(clamp(dryness, 0.0, 1.0));
	return max(gcol, vec3(0.0)) * mix(vec3(1.0), sl_season_spring_tint, s.x);
}

// Поле: участок (как в field_plot_color; сеяный — fh < 0.45, остальные — залежь = луг) по датам:
// пашня → всходы → зелень/рожь → спелая нива → стерня (прежний field_color) → часть участков
// вспахана. Множители яркости/фактуры участка сохраняются (отношение к field_color).
vec3 sl_field_season(vec3 fcol, vec2 xz, float rel) {
	if (!sl_season_enabled) {
		return fcol;
	}
	vec2 cell = floor(xz / field_size_m + vec2(floor(xz.y / (field_size_m.y * 6.0)) * 0.37, 0.0));
	if (hash12(cell) >= 0.45) {
		return fcol;
	}
	float h2 = hash12(cell + 41.3);
	bool plowed = hash12(cell + 57.9) < 0.6;
	vec3 stub = field_color;
	vec3 soil = sl_season_crop_soil;
	vec3 t = plowed ? soil : stub;                                   // зимнее состояние
	t = mix(t, soil, smoothstep(-15.0, 0.0, rel));  // весенняя обработка
	t = mix(t, sl_season_crop_green, smoothstep(sl_season_crop_days.x, sl_season_crop_days.x + 25.0, rel));
	t = mix(t, sl_season_crop_ripe,
			smoothstep(sl_season_crop_days.y - 20.0, sl_season_crop_days.y, rel));
	float harvest = sl_season_crop_days.y + 3.0 + sl_season_crop_days.z * h2;
	t = mix(t, stub, smoothstep(harvest, harvest + 4.0, rel));
	t = mix(t, soil, plowed ? smoothstep(harvest + sl_season_crop_days.w,
			harvest + sl_season_crop_days.w + 10.0, rel) : 0.0);
	// разброс тона: между полями (хеш участка) и внутри поля (низкочастотно) — яркость и лёгкий
	// тёплый/холодный сдвиг, без изменения насыщенности
	float vf = hash12(cell + 7.7) - 0.5;
	float vi = vnoise(xz / 45.0 + cell * 3.1) - 0.5;
	float vb = 1.0 + 0.16 * vf + 0.10 * vi;
	t *= vb * vec3(1.0 + 0.05 * vf, 1.0, 1.0 - 0.05 * vf);
	return fcol * t / max(field_color, vec3(1e-3));
}

// Высота посева (множитель к crop_height_m): всходы низкие, нива до уборки в полный рост, стерня и
// пашня — короткие. Участок и сроки те же, что в sl_field_season.
float sl_field_height(vec2 xz, float rel) {
	if (!sl_season_enabled) {
		return 1.0;
	}
	vec2 cell = floor(xz / field_size_m + vec2(floor(xz.y / (field_size_m.y * 6.0)) * 0.37, 0.0));
	if (hash12(cell) >= 0.45) {
		return 1.0;
	}
	float harvest = sl_season_crop_days.y + 3.0 + sl_season_crop_days.z * hash12(cell + 41.3);
	float grow = mix(0.25, 1.0, smoothstep(sl_season_crop_days.x, sl_season_crop_days.x + 50.0, rel));
	return mix(grow, 0.15, smoothstep(harvest, harvest + 4.0, rel));
}

#endif

// Тон осенней листвы: оттенок season_autumn_color, яркость — от исходного цвета × luma_k (тон
// отдельно от яркости: множитель альбедо по породам ложится поверх).
vec3 sl_autumn_tone(vec3 rgb, float luma_k) {
	vec3 g = sl_season_autumn_color;
	return g * (dot(rgb, SL_LW) * luma_k / max(dot(g, SL_LW), 1e-4));
}

// Полог рельефа: берёзово-осиновая доля (1 − con_p) и лиственничная (con_p · season_larch_share)
// желтеют и оголяются по датам; хвойные остаются зелёными. sb — сезон берёзы на высоте alt.
vec3 sl_canopy_season(vec3 fc, float con_p, vec4 sb, float alt) {
	if (!sl_season_enabled) {
		return fc;
	}
	vec4 sg = sl_season_sp(2.0, alt);
	float wb = 1.0 - con_p;
	float wl = con_p * sl_season_larch_share;
	float y = dot(fc, SL_LW);
	vec3 bare = sl_season_bare_color * clamp(y / 0.17, 0.4, 1.6);
	vec3 r = mix(fc, sl_autumn_tone(fc, sl_season_autumn_luma.x), wb * sb.z * (1.0 - sb.w));
	r = mix(r, sl_autumn_tone(fc, sl_season_autumn_luma.y), wl * sg.z * (1.0 - sg.w));
	r = mix(r, bare, wb * sb.w);
	return mix(r, bare, wl * sg.w);
}

// Дерево-модель/импостер лиственной породы: rgb → осенний тон (по сезону s породы); голое — в тон
// ветвей (листья дополнительно прореживает sl_leaf_gone).
vec3 sl_tree_season(vec3 rgb, vec4 s, float kind) {
	float y = dot(rgb, SL_LW);
	rgb = mix(rgb, sl_autumn_tone(rgb, kind > 1.5 ? sl_season_autumn_luma.y : sl_season_autumn_luma.x),
			s.z * (1.0 - s.w));
	return mix(rgb, sl_season_bare_color * clamp(y / 0.17, 0.4, 1.6), 0.6 * s.w);
}

// Лист опал: шум экрана n (0..1) ниже доли опавшей листвы — пиксель не рисуется (крона редеет).
bool sl_leaf_gone(float bare, float n) {
	return n < bare * 0.85;
}

#ifndef SL_NO_GROUND   // SL-8 использует vnoise/hash12 из terrain_common
// --- SL-8: скотные тропы с высоты ---
// Горизонтальные ступеньки на крутом лугу (шаг по высоте 1–3 м): светлая полка (тропа, ровная —
// освещена как горизонталь) и подъём уступа (обращён вниз по склону — тень, если солнце с
// верховой стороны). Тон считается освещённостью: ambient + max(n·l, 0) относительно склона;
// профиль нормирован на нулевое среднее, поэтому при следе пикселя больше шага амплитуда гаснет
// к среднему цвету луга (без мерцания и муара).
uniform bool sl_trails_enabled = false;
uniform vec2 sl_trails_step_m = vec2(1.2, 2.8);    // шаг по высоте: от и до, м (на каждый участок свой)
uniform vec2 sl_trails_deg = vec2(16.0, 35.0);     // уклон лестницы: от и до, градусы (края мягкие, 5°)
uniform float sl_trails_strength = 0.5;            // доля профиля, подмешиваемая к цвету
uniform float sl_trails_tread_light = 0.25;        // полка светлее (голый грунт), доля
uniform float sl_trails_ambient = 0.25;            // рассеянный свет относительно прямого при n·l = 1
uniform vec2 sl_trails_near_m = vec2(60.0, 160.0); // ближе — работают терраски meadow_detail, м

const float SL_TRAIL_RISER_A = 0.6;    // подъём занимает фазу 0,6…0,95
const float SL_TRAIL_RISER_B = 0.95;

// Доля подъёма (0 полка, 1 подъём) в фазе fr с мягкими краями шириной w (в долях шага).
float sl_trail_riser(float fr, float w) {
	return smoothstep(SL_TRAIL_RISER_A - w, SL_TRAIL_RISER_A + w, fr)
			* (1.0 - smoothstep(SL_TRAIL_RISER_B - w, SL_TRAIL_RISER_B + w, fr));
}

// Множитель тона луга от ступенек. p — xz, h — высота, nc — нормаль склона, slope_deg — уклон,
// fh — fwidth(h) (м/пиксель), l — на солнце (мир), dist — расстояние до камеры, м.
vec3 sl_trails(vec3 c, vec2 p, float h, vec3 nc, float slope_deg, float fh, vec3 l, float dist) {
	if (!sl_trails_enabled) {
		return c;
	}
	float k = smoothstep(sl_trails_deg.x, sl_trails_deg.x + 5.0, slope_deg)
			* (1.0 - smoothstep(sl_trails_deg.y - 5.0, sl_trails_deg.y, slope_deg))
			* smoothstep(sl_trails_near_m.x, sl_trails_near_m.y, dist);
	if (k <= 0.0) {
		return c;
	}
	// участки с разным шагом (границы неровные); тропы рвутся и бывают не везде
	vec2 cell = floor(p / 320.0 + (vnoise(p / 90.0) - 0.5) * 0.8);
	float s = mix(sl_trails_step_m.x, sl_trails_step_m.y, hash12(cell + vec2(3.7, 11.1)));
	float fw = fh / s;
	k *= 1.0 - smoothstep(0.3, 0.7, fw);    // мельче пикселя — к среднему
	k *= smoothstep(0.25, 0.5, vnoise(p / 40.0 + vec2(8.1, 2.9)));
	if (k <= 0.0) {
		return c;
	}
	float ph = (h + (vnoise(p / 55.0) - 0.5) * 1.4 * s + (vnoise(p / 13.0) - 0.5) * 0.4 * s) / s;
	float w = clamp(0.05 + fw, 0.05, 0.3);
	float rm = sl_trail_riser(fract(ph), w);
	// освещённость: полка — нормаль вверх, подъём — горизонтально вниз по склону
	vec2 dn = length(nc.xz) > 1e-4 ? normalize(nc.xz) : vec2(1.0, 0.0);
	vec3 n_riser = vec3(dn.x, 0.15, dn.y);
	n_riser = normalize(n_riser);
	float amb = sl_trails_ambient;
	float e_t = (amb + max(l.y, 0.0)) * (1.0 + sl_trails_tread_light);
	float e_r = amb + max(dot(n_riser, l), 0.0);
	float wr = SL_TRAIL_RISER_B - SL_TRAIL_RISER_A;
	float mean_e = (1.0 - wr) * e_t + wr * e_r;
	float tone = mix(e_t, e_r, rm) / max(mean_e, 1e-3);
	return c * mix(1.0, tone, k * sl_trails_strength);
}
#endif

#ifndef SL_NO_GROUND   // SL-9 использует vnoise/hash12 из terrain_common
// --- SL-9: анти-тайлинг скал и осыпей, конусы выноса ---
uniform bool sl_rock_enabled = false;
uniform float sl_rock_anti = 0.22;                  // размах яркости разрывающего слоя (± доля)
uniform float sl_rock_anti_tint = 0.06;             // тёплый/холодный сдвиг тона (± доля, яркость сохраняется)
uniform vec3 sl_rock_anti_scale = vec3(2.7, 0.63, 1.9);  // периоды слоёв: мелкий — × тайл породы; крупный — × тайл × rock_macro_k; осыпь — × тайл осыпи
uniform float sl_rock_bump = 0.35;                  // рваная неровность в нормали (наклон на масштабе неровности)
uniform vec3 sl_rock_rough_m = vec3(0.7, 3.5, 16.0); // масштабы неровности: мелкая, средняя, крупная, м
uniform float sl_rock_crevice = 0.35;               // затенение в щелях, доля
uniform float sl_rock_tone = 0.18;                  // разброс тона глыб, ± доля
uniform float sl_rock_block_m = 2.6;                // размер глыбы, м
uniform float sl_rock_crack = 0.4;                  // тёмные трещины, доля
uniform float sl_fan_strength = 0.6;                // доля светлого веера под обрывом
uniform vec2 sl_fan_deg = vec2(26.0, 36.0);         // склон, на котором материал копится (угол естественного откоса), градусы; края 4°
uniform float sl_fan_light = 1.12;                  // светлее свежим сколом, множитель
uniform float sl_fan_width_m = 28.0;                // ширина лопасти веера, м
uniform float sl_fan_above_deg = 40.0;              // выше по склону не положе этого, градусы (иначе обрыва нет)

// Шум значений с производной (одна выборка = значение + градиент в координатах шума).
vec3 sl_noise_d(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 w = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
	vec2 dw = 30.0 * f * f * (f * (f - 2.0) + 1.0);
	float a = hash12(i);
	float b = hash12(i + vec2(1.0, 0.0));
	float c = hash12(i + vec2(0.0, 1.0));
	float d = hash12(i + vec2(1.0, 1.0));
	float k1 = b - a;
	float k2 = c - a;
	float k4 = a - b - c + d;
	return vec3(a + k1 * w.x + k2 * w.y + k4 * w.x * w.y, dw * vec2(k1 + k4 * w.y, k2 + k4 * w.x));
}

// Результат скал/осыпей/выходов породы (вызывать после col = mix(col, rcol, rock)):
// анти-тайлинг + светлые конусы выноса под крутыми участками.
// rs — вес скалы (max(rock, ocw)), sc — осыпи; open_w — доля «не лес».
vec3 sl_rock_look(vec3 c, vec3 wp, vec3 nc, float dist, float rs, float sc, float open_w,
		float slope_deg, float slope_up, float cvx, vec3 scree_col,
		float rock_tile, float rock_macro_k, float scree_tile, out vec3 rg) {
	rg = vec3(0.0);
	if (!sl_rock_enabled) {
		return c;
	}
	float pix = dist * 0.0018;
	float wr = rs;
	float ws = sc * (1.0 - rs);
	float w = clamp(wr + ws, 0.0, 1.0);
	if (w > 0.001) {
		// координаты: на крутом — вдоль горизонтальной касательной и высоты, на пологом — xz
		float flat_w = smoothstep(0.6, 0.9, nc.y);
		vec2 tg = length(nc.xz) > 1e-4 ? normalize(vec2(-nc.z, nc.x)) : vec2(1.0, 0.0);
		vec2 u = mix(vec2(dot(wp.xz, tg), wp.y), wp.xz, flat_w) + vec2(17.3, 5.1);
		vec3 tg3 = vec3(tg.x, 0.0, tg.y);
		float tone = 0.0;
		float crev = 0.0;
		// крупный слой (период 2,7 тайла породы — разрывает повтор; тон + нормаль из одной выборки)
		float p1 = sl_rock_rough_m.z;
		float f1 = 1.0 - smoothstep(0.12 * p1, 0.4 * p1, pix);
		if (f1 > 0.0) {
			vec3 nd = sl_noise_d(u / p1 + 3.1);
			tone += (nd.x - 0.5) * 2.0 * f1;
			vec2 gd = nd.yz * 0.5 * f1;
			rg += mix(tg3 * gd.x + vec3(0.0, gd.y, 0.0), vec3(gd.x, 0.0, gd.y), flat_w);
		}
		// средний (щели: низ шума темнее; нормаль из той же выборки)
		float p2 = sl_rock_rough_m.y;
		float f2 = 1.0 - smoothstep(0.12 * p2, 0.4 * p2, pix);
		if (f2 > 0.0) {
			vec3 nd = sl_noise_d(u / p2 + 7.7);
			crev = (1.0 - smoothstep(0.25, 0.55, nd.x)) * f2;
			vec2 gd = nd.yz * f2;
			rg += mix(tg3 * gd.x + vec3(0.0, gd.y, 0.0), vec3(gd.x, 0.0, gd.y), flat_w);
		}
		// мелкий — только вблизи (вдали не считается)
		float p0 = sl_rock_rough_m.x;
		float f0 = 1.0 - smoothstep(0.12 * p0, 0.4 * p0, pix);
		if (f0 > 0.0) {
			vec3 nd = sl_noise_d(u / p0 + 1.3);
			vec2 gd = nd.yz * f0;
			rg += mix(tg3 * gd.x + vec3(0.0, gd.y, 0.0), vec3(gd.x, 0.0, gd.y), flat_w);
		}
		// крупнейший (тайл макро-слоя): одна выборка, только тон
		float pm = rock_tile * rock_macro_k * sl_rock_anti_scale.y;
		float fm = 1.0 - smoothstep(0.15 * pm, 0.5 * pm, pix);
		if (fm > 0.0) {
			tone += (vnoise(u / pm + 31.0) - 0.5) * 2.0 * fm * 0.6;
		}
		c *= (1.0 + sl_rock_anti * tone * w) * (1.0 + sl_rock_anti_tint * tone * w * vec3(0.5, 0.0, -0.5));
		c = max(c, vec3(0.0));
		c *= 1.0 - sl_rock_crevice * w * crev;
		// глыбы: клетка, тон по хешу (одна выборка), у границы темнее
		float bm = sl_rock_block_m;
		float fb = 1.0 - smoothstep(0.12 * bm, 0.4 * bm, pix);
		if (fb > 0.0) {
			vec2 bu = u / bm;
			vec2 bid = floor(bu);
			vec2 bf = fract(bu);
			float edge = min(min(bf.x, 1.0 - bf.x), min(bf.y, 1.0 - bf.y));
			float bt = hash12(bid + (flat_w > 0.5 ? 0.0 : 91.0)) - 0.5;
			c *= 1.0 + sl_rock_tone * 2.0 * bt * w * fb;
			c *= 1.0 - 0.5 * sl_rock_crevice * w * fb * (1.0 - smoothstep(0.02, 0.12, edge));
			// трещины: линия нулевого уровня шума, вытянута по вертикали; только вблизи
			float fc = 1.0 - smoothstep(0.1 * bm, 0.5 * bm, pix);
			if (fc > 0.0) {
				float cn = vnoise(vec2(u.x / (bm * 0.9), u.y / (bm * 2.5)) + 12.3);
				float cw = 0.02 + pix / (bm * 0.9) * 0.5;
				c *= 1.0 - sl_rock_crack * w * (1.0 - smoothstep(0.0, cw, abs(cn - 0.5))) * fc;
			}
		}
	}
	// конус выноса: склон у угла откоса, выше по склону круче; лопасти вдоль линии падения,
	// у обрыва узкие, дальше шире; выпуклый поперёк (чуть светлее на гребне лопасти)
	float up = smoothstep(sl_fan_above_deg - 8.0, sl_fan_above_deg, slope_up);
	if (up > 0.0 && rs < 0.99) {
		float band = smoothstep(sl_fan_deg.x - 4.0, sl_fan_deg.x, slope_deg)
				* (1.0 - smoothstep(sl_fan_deg.y, sl_fan_deg.y + 4.0, slope_deg));
		if (band > 0.0) {
			vec2 df = length(nc.xz) > 1e-4 ? normalize(nc.xz) : vec2(1.0, 0.0);
			float qx = dot(wp.xz, vec2(-df.y, df.x));
			float qy = dot(wp.xz, df);
			float near = smoothstep(8.0, 30.0, slope_up - slope_deg);
			float lobes = vnoise(vec2(qx / sl_fan_width_m, qy / (sl_fan_width_m * 5.0)) + vec2(3.3, 1.7));
			float thr = mix(0.42, 0.6, near);
			float fan = smoothstep(thr, thr + 0.15, lobes) * band * up * open_w * (1.0 - rs)
					* (0.75 + 0.25 * clamp(cvx, -1.0, 1.0));
			fan *= 1.0 - smoothstep(0.4, 0.9, vnoise(wp.xz / 90.0 + 6.1)) * 0.5;
			fan *= 1.0 - smoothstep(0.15 * sl_fan_width_m, 0.5 * sl_fan_width_m, pix);   // мельче пикселя — к среднему
			if (fan > 0.0) {
				vec3 fc = mix(c, scree_col, 0.5) * sl_fan_light * (0.9 + 0.2 * vnoise(wp.xz / 5.0));
				c = mix(c, fc, fan * sl_fan_strength);
			}
		}
	}
	return c;
}

// Нормаль со шершавостью скал/осыпей (после сборки нормали): rg — мировой градиент из sl_rock_look.
vec3 sl_rock_nrm(vec3 n, vec3 rg, float w) {
	if (!sl_rock_enabled) {
		return n;
	}
	return normalize(n - rg * (sl_rock_bump * w));
}

#endif
// --- SL-15: волны ветра по траве с высоты — блеск по солнцу и оттенок ---
// Под порывом стебли наклоняются по ветру d; поверхность листвы обращена против ветра (−d).
// Блеск — как у половинного вектора h = норм(на солнце + на камеру): наклон к h светлит (серебро изнанки,
// рассеяние вперёд), наклон от h темнит. s = −d·h_xz / |h| ∈ [−1, 1]: знак даёт азимут ветра
// относительно солнца и взгляда, величина — высоту (солнце в зените и камера над головой → 0).
// far — маска порыва grass_wind_far (уже посчитана, 0…~1), base — прежнее равномерное посветление
// wind_far_shade (заменяется направленным, чтобы в тёмной полосе не было «плюс-минус»).
uniform bool sl_grass_wind_sheen_enabled = false;
uniform float sl_grass_wind_sheen_gain = 0.3;    // ±доля яркости при s = ±1 и far = 1
uniform float sl_grass_wind_sheen_tint = 0.6;    // доля сдвига оттенка (светлая полоса к сизо-жёлтому, тёмная к глубокой зелени)

// Знак и сила эффекта (−1…1): wind — ветер xz (м/с), l — на солнце (мир), v — на камеру (мир, единичный).
float sl_wind_sheen_sign(vec2 wind, vec3 l, vec3 v) {
	float spd = length(wind);
	if (spd < 1e-3) {
		return 0.0;
	}
	vec3 h = normalize(l + v);
	return clamp(-dot(wind / spd, h.xz) / max(length(h), 1e-3) * 1.6, -1.0, 1.0);
}

vec3 sl_wind_sheen(vec3 c, float far, float base, vec2 wind, vec3 v) {
	if (!sl_grass_wind_sheen_enabled || far <= 0.0) {
		return c;
	}
	float s = sl_wind_sheen_sign(wind, sl_sun_dir, v);
	float luma = dot(c, SL_LW);
	c /= 1.0 + base * far;    // убрать равномерное посветление
	vec3 lit = mix(c, vec3(luma) * vec3(1.04, 1.0, 0.9) + (c - vec3(luma)) * 0.5, 0.5);   // светлая полоса: серебристо-жёлтоватая, мягче по цвету
	vec3 dark = c * vec3(0.92, 1.0, 0.9);                                                  // тёмная: глубже зелёная
	float a = abs(s) * far * sl_grass_wind_sheen_tint;
	c = mix(c, s > 0.0 ? lit : dark, clamp(a, 0.0, 1.0));
	return c * (1.0 + sl_grass_wind_sheen_gain * s * far);
}

// --- SL-10: свежий снег выше сезонной снеговой линии и ледники (контракт SL-К2 v2; зеркало —
// scripts/terrain/season_look.gd, формулы правятся вместе). Линия: летняя высота по широте (кусочно-
// линейная таблица по узлам sl_snow_lats) минус зимнее опускание по сезонному косинусу с минимумом
// в sl_snow_min_day (конец зимы); южное полушарие — дата +182,5. Дата и широта — на CPU (sl_snow_pre.x =
// высота линии, м; SeasonLook.apply_pre), в пикселе — только сравнение с высотой. ---
uniform bool sl_snow_enabled = false;
uniform vec4 sl_snow_lats = vec4(10.0, 46.0, 60.0, 70.0);            // узлы таблицы линии, градусы широты
uniform vec4 sl_snow_line_summer = vec4(4900.0, 3200.0, 1500.0, 500.0);  // высота линии летом (наивысшая), м
uniform vec4 sl_snow_line_winter_drop = vec4(0.0, 2000.0, 1700.0, 500.0);  // зимнее опускание линии, м
uniform float sl_snow_min_day = 60.0;                // день, когда линия ниже всего (конец зимы)
uniform float sl_snow_fresh_band_m = 300.0;          // полоса плавного перехода выше линии, м
uniform vec2 sl_snow_fresh_slope = vec2(38.0, 55.0); // свежий снег держится до уклона / сползает к уклону, градусы
uniform vec4 sl_snow_pre = vec4(3000.0, 0.0, 0.0, 0.0);  // (высота линии на дату и широту, ...) считает CPU

float sl_snow_interp(vec4 v, float al) {
	float t = clamp(al, sl_snow_lats.x, sl_snow_lats.w);
	float a = mix(v.x, v.y, clamp((t - sl_snow_lats.x) / (sl_snow_lats.y - sl_snow_lats.x), 0.0, 1.0));
	float b = mix(v.y, v.z, clamp((t - sl_snow_lats.y) / (sl_snow_lats.z - sl_snow_lats.y), 0.0, 1.0));
	float c = mix(v.z, v.w, clamp((t - sl_snow_lats.z) / (sl_snow_lats.w - sl_snow_lats.z), 0.0, 1.0));
	return t < sl_snow_lats.y ? a : (t < sl_snow_lats.z ? b : c);
}

// Высота сезонной снеговой линии, м.
float sl_snow_line(float doy, float lat) {
	float al = abs(lat);
	float d = doy + (lat < 0.0 ? 182.5 : 0.0);
	d -= 365.0 * floor(d / 365.0);
	float w = 0.5 * (1.0 + cos(6.2831853 * (d - sl_snow_min_day) / 365.0));
	return sl_snow_interp(sl_snow_line_summer, al) - sl_snow_interp(sl_snow_line_winter_drop, al) * w;
}

// Свежий снег 0…1 на высоте alt: не убывает с высотой, плавный переход в полосе sl_snow_fresh_band_m.
float sl_snow_fresh(float doy, float lat, float alt) {
	if (!sl_snow_enabled) {
		return 0.0;
	}
	float line = sl_snow_line(doy, lat);
	return smoothstep(line, line + sl_snow_fresh_band_m, alt);
}

// То же по подготовленной на CPU линии (рельеф).
float sl_snow_fresh_b(float alt) {
	if (!sl_snow_enabled) {
		return 0.0;
	}
	return smoothstep(sl_snow_pre.x, sl_snow_pre.x + sl_snow_fresh_band_m, alt);
}

#ifndef SL_NO_GROUND   // SL-10 использует vnoise из terrain_common
uniform bool sl_glacier_enabled = false;
uniform vec3 sl_glacier_color = vec3(0.3, 0.31, 0.33);   // грязный лёд/фирн, линейный RGB
uniform float sl_glacier_dirt = 0.7;                     // доля серого цвета на леднике
uniform vec2 sl_glacier_slope_deg = vec2(14.0, 26.0);    // ледник на пологом: полностью до первого, исчезает к второму
uniform vec2 sl_glacier_crevasse_m = vec2(14.0, 45.0);   // шаг трещин поперёк течения, м; период по длине (разломы)
uniform float sl_glacier_crevasse = 0.6;                 // сила трещин, доля

// Свежий снег поверх готового цвета: выше линии на дату и широту, не на крутом (сползает); кромка рваная.
vec3 sl_fresh_snow(vec3 col, vec3 snow_col, vec2 xz, float h, float slope_deg, float forest) {
	float f = sl_snow_fresh_b(h);
	if (f < 0.002) {
		return col;
	}
	float n = vnoise(xz / 70.0 + vec2(5.3, 1.7));
	f = smoothstep(0.0, 1.0, f * 1.6 - 0.3 + 0.7 * (n - 0.5));
	f *= 1.0 - smoothstep(sl_snow_fresh_slope.x, sl_snow_fresh_slope.y, slope_deg);
	f *= 1.0 - 0.5 * forest;
	return mix(col, snow_col * (0.94 + 0.06 * n), f);
}

// Цвет снега класса на леднике (ниже сезонной линии, полого, в вогнутости): грязно-серый, поперёк
// течения (поперёк линии падения) полосы трещин. cv — выпуклость (−1…1, <0 вогнуто), foot — след пикселя, м.
vec3 sl_glacier(vec3 wcol, vec2 xz, vec3 n_class, float slope_deg, float cv, float h, float foot) {
	if (!sl_glacier_enabled) {
		return wcol;
	}
	float g = (1.0 - smoothstep(sl_snow_pre.x, sl_snow_pre.x + sl_snow_fresh_band_m, h))
			* (1.0 - smoothstep(sl_glacier_slope_deg.x, sl_glacier_slope_deg.y, slope_deg))
			* (1.0 - smoothstep(-0.3, 0.05, cv));
	if (g < 0.01) {
		return wcol;
	}
	float dirt = 0.6 + 0.4 * vnoise(xz / 55.0 + vec2(2.1, 8.4));
	vec3 col = mix(wcol, sl_glacier_color * dirt, g * sl_glacier_dirt);
	// трещины: линии вдоль изолиний (u — координата по течению), разорваны по ширине, чаще на уклоне
	vec2 dn = length(n_class.xz) > 1e-4 ? normalize(n_class.xz) : vec2(1.0, 0.0);
	float u = dot(xz, dn) / sl_glacier_crevasse_m.x + 1.6 * vnoise(xz / 35.0);
	float w = dot(xz, vec2(-dn.y, dn.x)) / sl_glacier_crevasse_m.y;
	float line = smoothstep(0.4, 0.46, abs(fract(u) - 0.5));
	float seg = smoothstep(0.45, 0.6, vnoise(vec2(w * 3.0, floor(u) * 1.7)));
	float steep = smoothstep(2.0, 9.0, slope_deg);
	float kf = 1.0 - smoothstep(2.0, 8.0, foot);
	float cr = line * seg * steep * g * sl_glacier_crevasse;
	return mix(col, col * vec3(0.18, 0.24, 0.32), cr * kf) * (1.0 - 0.1 * cr * (1.0 - kf));
}
#endif
