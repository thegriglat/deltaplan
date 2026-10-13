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

// Слои разрыва повтора: гладкий шум с периодами, несоизмеримыми с тайлами текстур, гасится
// к среднему, когда период мельче пикселя (дальше мип уже усреднил текстуру).
float sl_rock_break(vec2 u, float period, float pixel_m) {
	float f = 1.0 - smoothstep(0.15 * period, 0.5 * period, pixel_m);
	if (f <= 0.0) {
		return 0.0;
	}
	return (vnoise(u / period) * 0.7 + vnoise(u / (period * 0.37) + 4.7) * 0.3 - 0.5) * 2.0 * f;
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
	if (wr > 0.001 || ws > 0.001) {
		// координаты: на крутом — вдоль горизонтальной касательной и высоты, на пологом — xz
		float flat_w = smoothstep(0.6, 0.9, nc.y);
		vec2 tg = length(nc.xz) > 1e-4 ? normalize(vec2(-nc.z, nc.x)) : vec2(1.0, 0.0);
		vec2 u = mix(vec2(dot(wp.xz, tg), wp.y), wp.xz, flat_w) + vec2(17.3, 5.1);
		float a = 0.0;
		if (wr > 0.001) {
			a = sl_rock_break(u, rock_tile * sl_rock_anti_scale.x, pix) * 0.6
					+ sl_rock_break(u + 31.0, rock_tile * rock_macro_k * sl_rock_anti_scale.y, pix) * 0.4;
		}
		float b = 0.0;
		if (ws > 0.001) {
			b = sl_rock_break(wp.xz + 9.0, scree_tile * sl_rock_anti_scale.z, pix);
		}
		float m = a * wr + b * ws;
		c *= (1.0 + sl_rock_anti * m) * (1.0 + sl_rock_anti_tint * m * vec3(0.5, 0.0, -0.5));
		c = max(c, vec3(0.0));
		float w = clamp(wr + ws, 0.0, 1.0);
		// шершавость: три масштаба шума (нормаль + тень в щелях), глыбы разного тона, трещины
		float hs = 0.5;
		vec3 up_w = vec3(0.0, 1.0, 0.0);
		vec3 tg3 = vec3(tg.x, 0.0, tg.y);
		float e = 0.1;
		float tone_b = 0.0;
		for (int i = 0; i < 3; i++) {
			float per = i == 0 ? sl_rock_rough_m.x : (i == 1 ? sl_rock_rough_m.y : sl_rock_rough_m.z);
			float f = 1.0 - smoothstep(0.12 * per, 0.4 * per, pix);
			if (f > 0.0) {
				vec2 uu = u / per + float(i) * 7.7;
				float v0 = vnoise(uu);
				vec2 gd = vec2(vnoise(uu + vec2(e, 0.0)) - v0, vnoise(uu + vec2(0.0, e)) - v0) / e;
				vec3 gw = mix(tg3 * gd.x + up_w * gd.y, vec3(gd.x, 0.0, gd.y), flat_w);
				rg += gw * f * (i == 2 ? 0.5 : 1.0);
				if (i == 1) {
					hs = v0;
				}
			}
		}
		float per2 = sl_rock_rough_m.y;
		float fm = 1.0 - smoothstep(0.12 * per2, 0.4 * per2, pix);
		c *= 1.0 - sl_rock_crevice * w * fm * (1.0 - smoothstep(0.25, 0.55, hs));
		// глыбы: клетка, тон по хешу, у границы темнее
		float bm = sl_rock_block_m;
		float fb = 1.0 - smoothstep(0.12 * bm, 0.4 * bm, pix);
		vec2 bu = u / bm + (vec2(vnoise(u / (bm * 3.0)), vnoise(u / (bm * 3.0) + 5.0)) - 0.5) * 0.8;
		vec2 bid = floor(bu);
		vec2 bf = fract(bu);
		float edge = min(min(bf.x, 1.0 - bf.x), min(bf.y, 1.0 - bf.y));
		float bt = hash12(bid + (flat_w > 0.5 ? 0.0 : 91.0)) - 0.5;
		c *= 1.0 + sl_rock_tone * 2.0 * bt * w * fb;
		c *= 1.0 - 0.5 * sl_rock_crevice * w * fb * (1.0 - smoothstep(0.02, 0.12, edge));
		// трещины: тонкие линии нулевого уровня шума, вытянуты по вертикали
		float cn = vnoise(vec2(u.x / (bm * 0.9), u.y / (bm * 2.5)) + 12.3);
		float cw = 0.02 + pix / (bm * 0.9) * 0.5;
		c *= 1.0 - sl_rock_crack * w * (1.0 - smoothstep(0.0, cw, abs(cn - 0.5))) * (1.0 - smoothstep(0.1 * bm, 0.5 * bm, pix));
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
