// Рельеф: высоты из текстуры (вершинный шейдер), раскраска по карте поверхности (VR-4: лес,
// луг, пашня, кустарник, скалы/грунт, вода, застройка, снег — та же карта, что у источников
// термиков), по уклону (скалы на крутом) + шум детализации (FR-19). Все параметры задаёт
// terrain_renderer.gd из configs/world.json → terrain_look (числа в шейдере — только технические).
shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

#include "res://scripts/terrain/terrain_common.gdshaderinc"
#include "res://scripts/terrain/terrain_wind.gdshaderinc"

// шаг между вершинами чанка в узлах сетки (1, 2, 4…) — для гладкой нормали вершины
uniform float lod_stride = 1.0;  // свой материал на каждый LOD (instance uniform переполняет Compatibility)
uniform float skirt_depth;      // глубина «юбки», м
// прямоугольник X/Z, где рисует более детальный слой (грубый слой там не рисуется)
uniform vec2 hole_min = vec2(1e9);
uniform vec2 hole_max = vec2(-1e9);
// Необязательные текстуры поверхностей (пути — configs/world.json → terrain_textures).
// Нет текстуры — процедурная раскраска. Текстура видна вблизи и растворяется к detail_fade_m.
uniform sampler2D grass_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D forest_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D rock_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D snow_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform bool use_grass_tex = false;
uniform bool use_forest_tex = false;
uniform bool use_rock_tex = false;
// --- скалы, осыпи, снег в кулуарах ---
uniform sampler2D rock_normal_tex : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform bool use_rock_normal = false;
uniform sampler2D scree_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform bool use_scree_tex = false;
uniform float scree_tex_tile_m = 4.0;
uniform vec3 rock_color2 : source_color = vec3(0.45, 0.36, 0.26);  // охристо-бурая порода
uniform vec3 lichen_color : source_color = vec3(0.5, 0.42, 0.2);   // рыжий/зеленоватый лишайник
uniform vec3 scree_color : source_color = vec3(0.58, 0.55, 0.5);   // светлая щебёнка
uniform float rock_tone_scale_m = 180.0;
uniform float lichen_amount = 0.35;
uniform float strata_m = 7.0;          // шаг слоёв на обрывах, м
uniform float strata_strength = 0.28;
uniform float scree_probe_m = 35.0;    // где искать обрыв выше по склону, м
uniform float scree_min_deg = 18.0;    // осыпь лежит на склоне круче этого (и положе скал)
uniform float gully_snow_line_m = 2500.0;  // ниже снега в кулуарах нет, м
uniform float gully_scale_m = 60.0;    // масштаб ложбин (кривизна), м
uniform float gully_k = 0.08;          // вогнутость (м/м), с которой ложбина полностью в снегу
uniform float gully_north_m = 250.0;   // северные склоны: снег ниже на столько, м
uniform bool use_snow_tex = false;
uniform float grass_tex_tile_m = 4.0;
uniform float forest_tex_tile_m = 8.0;
uniform float rock_tex_tile_m = 6.0;
uniform float snow_tex_tile_m = 6.0;
uniform float texture_strength = 1.0;
// средний цвет каждой текстуры: текстура даёт вблизи рисунок (яркость, пятна),
// а общий цвет остаётся процедурным — без скачка на границе растворения
uniform vec3 grass_tex_avg = vec3(0.5);
uniform vec3 forest_tex_avg = vec3(0.5);
uniform vec3 rock_tex_avg = vec3(0.5);
uniform vec3 snow_tex_avg = vec3(0.5);
uniform float texture_color_mix = 0.3;
uniform float texture_contrast = 0.6; // степень контраста рисунка текстуры (1 — как есть) // доля собственного цвета текстуры (остальное — только её яркость)

// Применить текстуру поверх процедурного цвета c: яркость текстуры относительно средней + немного её цвета.
vec3 apply_tex(vec3 c, vec3 t, vec3 avg, float w) {
	const vec3 L = vec3(0.2126, 0.7152, 0.0722);
	float avg_l = max(dot(avg, L), 1e-3);
	// контраст рисунка ограничен: у тёмных пёстрых текстур светлые пятна не должны «белеть»
	float r = clamp(pow(dot(t, L) / avg_l, texture_contrast), 0.4, 1.7);
	vec3 own = t / avg_l * dot(c, L);
	return mix(c, mix(c * r, own, texture_color_mix), w);
}
// --- полог леса с высоты (кроны-ячейки, их освещение и тени) ---
uniform vec3 sun_dir = vec3(0.0, 1.0, 0.0);   // направление НА солнце (мир), задаёт Terrain
uniform float canopy_cell_m = 6.0;            // шаг крон, м
uniform vec2 canopy_crown_k = vec2(0.55, 0.85); // радиус кроны / шаг, мин/макс
uniform float canopy_gap_dark = 0.35;         // яркость просветов между кронами (тень под пологом)
uniform float canopy_tone_var = 0.22;         // разброс яркости крон
uniform float canopy_shadow = 0.55;           // сила тени от соседних крон
uniform float canopy_height_k = 1.6;          // вытянутость крон (форма нормали: 1 — полусфера)
uniform float canopy_edge_dark = 0.2;         // опушка темнее (тень леса на краю) — только внутри леса
uniform float canopy_edge_depth_m = 25.0;     // ширина тёмной полосы опушки внутрь леса, м
uniform float canopy_far_shade = 0.62;        // средняя яркость полога, когда кроны мельче пикселя
uniform float canopy_stand_var = 0.3;         // разброс яркости древостоев (пятна 50–200 м) вблизи
uniform float canopy_far_var = 0.3;           // то же вдали (кроны мельче пикселя)
uniform float canopy_far_big = 0.0;           // доля крупных пятен (массивы 300–800 м) в разбросе
uniform float canopy_far_sat = 1.0;           // насыщенность среднего тона полога (1 — как цвет пород)
// кромка леса по маске 10 м: порог 0,5 + узкий шум (переход ≤ 1,5 клетки)
uniform float forest_edge_soft = 0.12;        // полуширина порога (доля маски)
uniform float forest_edge_noise = 0.35;       // сдвиг порога шумом (доля маски)
uniform float forest_edge_warp_m = 4.0;       // извилистость кромки (сдвиг выборки), м
// высота крон в DSM (Copernicus): ступенька на опушке; вычитается из уклона на лугу у кромки
uniform float canopy_dsm_height_m = 10.0;
uniform vec3 water_color : source_color;
uniform float water_roughness = 0.1;
uniform float roughness_value;
uniform float specular_value;

varying vec3 v_world;
varying vec3 v_normal_world;
varying flat float v_lod_stride;
// выпуклость рельефа (−лапласиан, м/м) в масштабе outcrop_scale_m — в вершине, дёшево
uniform float outcrop_scale_m = 35.0;         // масштаб кривизны (гребни, бугры), м
varying float v_convex;

void vertex() {
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec2 f = (wp.xz - layer_origin) / layer_spacing;
	ivec2 ij = ivec2(round(f));
	float h = h_node(ij);
	int s = int(max(lod_stride, 1.0));
	float hx0 = h_node(ij - ivec2(s, 0));
	float hx1 = h_node(ij + ivec2(s, 0));
	float hz0 = h_node(ij - ivec2(0, s));
	float hz1 = h_node(ij + ivec2(0, s));
	vec3 n = normalize(vec3(hx0 - hx1, 2.0 * float(s) * layer_spacing, hz0 - hz1));
	// COLOR.r = 1 у вершин «юбки»: опускаем их вниз
	VERTEX.y = h - COLOR.r * skirt_depth;
	NORMAL = n;
	v_world = vec3(wp.x, VERTEX.y, wp.z);
	v_normal_world = n;
	v_lod_stride = lod_stride;
	int k = max(int(round(outcrop_scale_m / layer_spacing)), s);
	float gr = float(k) * layer_spacing;
	v_convex = -(h_node(ij + ivec2(k, 0)) + h_node(ij - ivec2(k, 0)) + h_node(ij + ivec2(0, k))
			+ h_node(ij - ivec2(0, k)) - 4.0 * h) / (4.0 * gr);
}

vec2 canopy_hash2(vec2 c) {
	return vec2(hash12(c * 1.31 + 7.7), hash12(c * 0.77 + 2.9));
}

// Ближайшая крона к точке p: x — нормированное расстояние d/r, y — радиус, zw — вектор от центра.
// id — клетка кроны.
vec4 canopy_nearest(vec2 p, float cell, out vec2 id) {
	vec2 g = floor(p / cell);
	vec4 best = vec4(1e9, 1.0, 0.0, 0.0);
	id = g;
	for (int j = -1; j <= 1; j++) {
		for (int i = -1; i <= 1; i++) {
			vec2 c = g + vec2(float(i), float(j));
			vec2 pt = (c + 0.5 + (canopy_hash2(c) - 0.5) * 0.7) * cell;
			float r = cell * mix(canopy_crown_k.x, canopy_crown_k.y, hash12(c + 1.7));
			vec2 v = p - pt;
			float d = length(v) / r;
			if (d < best.x) {
				best = vec4(d, r, v);
				id = c;
			}
		}
	}
	return best;
}

// Полог леса в точке: shade — множитель яркости (освещение крон, просветы, тени соседей),
// n_c — нормаль кроны (мир), tone — множитель цвета кроны, conifer_p — доля хвойных.
void canopy(vec2 p, float cell, float conifer_p, out float shade, out vec3 n_c, out vec3 tint) {
	vec2 id;
	vec4 c = canopy_nearest(p, cell, id);
	float inside = 1.0 - smoothstep(0.85, 1.05, c.x);
	float z = sqrt(max(1.0 - c.x * c.x, 0.0));
	bool con = hash12(id + 5.5) < conifer_p;
	float hk = con ? canopy_height_k * 1.4 : canopy_height_k;
	n_c = normalize(vec3(c.z, z * c.y * hk + 0.001, c.w));
	n_c = normalize(mix(vec3(0.0, 1.0, 0.0), n_c, inside));
	vec3 sd = normalize(sun_dir);
	float lit = clamp(dot(n_c, sd), 0.0, 1.0) / max(sd.y, 0.2);
	// тень от соседней кроны, стоящей ближе к солнцу
	vec2 toward = sd.xz / max(sd.y, 0.25) * c.y * 0.9;
	vec2 id2;
	vec4 c2 = canopy_nearest(p + toward, cell, id2);
	float shadowed = (1.0 - smoothstep(0.6, 1.0, c2.x)) * (1.0 - 0.8 * z * inside)
			* float(id2 != id);
	shade = mix(canopy_gap_dark, 0.55 + 0.45 * lit, inside) * (1.0 - canopy_shadow * shadowed);
	float tv = 1.0 + canopy_tone_var * (hash12(id + 3.3) - 0.5) * 2.0;
	tint = (con ? forest_color : birch_color) * tv;
}

// --- фактура луга в трёх масштабах (terrain_look: tuft_*, stone_*, band_*, terrace_*, tone_*) ---
uniform float tuft_scale_m = 9.0;             // куртины и кочки 5–20 м
uniform float tuft_strength = 0.3;
uniform float stone_cell_m = 7.0;             // шаг сетки, в клетке которой может лежать камень, м
uniform float stone_density = 0.08;           // доля клеток с камнем на лугу
uniform vec2 stone_size_m = vec2(0.4, 1.3);   // радиус камня мин/макс, м
uniform vec3 stone_color : source_color = vec3(0.44, 0.42, 0.38);
uniform vec2 band_size_m = vec2(28.0, 170.0); // полосы травы: поперёк × вдоль линии падения, м
uniform float band_strength = 0.85;
uniform float terrace_m = 2.2;                // шаг скотобойных тропинок по склону, м
uniform vec2 terrace_deg = vec2(16.0, 28.0);  // тропинки появляются / полностью с этого уклона
uniform float terrace_strength = 0.45;
uniform vec2 tone_scale_m = vec2(380.0, 1500.0); // крупные пятна тона, м
uniform float tone_strength = 0.18;
// --- выходы породы и курумник на гребнях/выпуклостях и крутых лугах ---
uniform float outcrop_convex_k = 0.035;        // выпуклость (м/м), с которой гребень каменистый
uniform vec2 outcrop_slope_deg = vec2(25.0, 36.0); // уклон начала/полной силы выходов породы
uniform float outcrop_patch_m = 45.0;         // размер пятен породы, м
uniform float outcrop_amount = 0.9;
uniform float kurum_share = 0.5;              // доля курумника среди выходов (остальное — коренная порода)
uniform float kurum_block_m = 2.2;            // шаг глыб курумника, м
uniform vec3 kurum_color : source_color = vec3(0.3, 0.29, 0.27);

// Анизотропный шум полос вдоль линии падения d (гориз. вектор вниз по склону): три фиксированных
// направления 0/60/120° смешиваются по близости к d — без поворота координат (он рвёт шум
// там, где меняется экспозиция).
float fall_bands(vec2 p, vec2 d) {
	float acc = 0.0;
	float wsum = 1e-4;
	for (int i = 0; i < 3; i++) {
		float a = float(i) * 1.0472;
		vec2 e = vec2(cos(a), sin(a));
		float c2 = dot(d, e);
		float w = max(pow(c2 * c2, 4.0) - 0.03, 0.0);   // малые веса — без выборки, без скачка
		vec2 q = vec2(dot(p, vec2(-e.y, e.x)) / band_size_m.x, dot(p, e) / band_size_m.y);
		if (w > 0.0) {
			acc += w * vnoise(q + float(i) * 17.3);
			wsum += w;
		}
	}
	return acc / wsum;
}

// Фактура луга: 5–20 м (куртины, кочки, камни), 20–200 м (полосы вдоль склона, скотобойные
// тропинки поперёк), 200 м–2 км (пятна тона). foot — след пикселя, м; nc — нормаль (класс);
// stones_k — множитель густоты камней (у выходов породы больше).
vec3 meadow_detail(vec2 p, vec3 c, float foot, float h, vec3 nc, float slope_deg, float stones_k) {
	const vec3 L = vec3(0.2126, 0.7152, 0.0722);
	float k1 = 1.0 - smoothstep(1.5, 7.0, foot);
	float k2 = 1.0 - smoothstep(20.0, 80.0, foot);
	float k_mid = 1.0 - smoothstep(1.5, 6.0, foot);
	float k_fine = 1.0 - smoothstep(0.4, 1.5, foot);
	vec3 c_dry = mix(c, straw_color * (dot(c, L) / max(dot(straw_color, L), 1e-3)) * 1.15, 0.7);
	vec3 c_lush = mix(c, grass_color * (dot(c, L) / max(dot(grass_color, L), 1e-3)), 0.6) * 0.8;
	// 200 м–2 км: крупные пятна тона (не гаснут вдали)
	float tone = vnoise(p / tone_scale_m.x + vec2(6.1, 2.4)) * 0.6
			+ vnoise(p / tone_scale_m.y + vec2(1.7, 8.3)) * 0.4;
	c *= 1.0 + tone_strength * 2.0 * (tone - 0.5) * vec3(1.0, 0.92, 0.65);
	// 20–200 м: полосы выгоревшей/сочной травы вдоль линии падения (на пологом — пятна)
	float sw = smoothstep(4.0, 16.0, slope_deg);
	vec2 dn = length(nc.xz) > 1e-4 ? normalize(nc.xz) : vec2(1.0, 0.0);
	float bw = band_strength * k2;
	if (bw > 0.0) {
		float b = sw < 1.0 ? vnoise(p / (band_size_m.x * 1.6) + vec2(2.3, 7.7)) : 0.5;
		if (sw > 0.0) {
			b = mix(b, fall_bands(p, dn), sw);
		}
		c = mix(c, mix(c_lush, c_dry, smoothstep(0.3, 0.7, b)), bw);
	}
	// скотобойные тропинки: вдоль горизонталей (по высоте), с шагом terrace_m по склону
	float tanv = length(nc.xz) / max(nc.y, 0.05);
	float kt = smoothstep(terrace_deg.x, terrace_deg.y, slope_deg) * terrace_strength;
	// след пикселя в долях шага (≈ fwidth фазы; без производных внутри ветвления)
	float fw = foot / max(terrace_m, 0.01);
	if (kt > 0.0 && fw < 0.6) {
		float per = max(terrace_m * tanv, 0.05);
		float ph = (h + (vnoise(p / 14.0) - 0.5) * 1.6 * per) / per;
		kt *= 1.0 - smoothstep(0.25, 0.6, fw);
		kt *= smoothstep(0.3, 0.5, vnoise(p / 18.0 + vec2(4.2, 9.9)));   // тропинки рвутся
		float fr = fract(ph);
		float path = smoothstep(0.34 - fw, 0.44, abs(fr - 0.5));
		float riser = smoothstep(0.1, 0.25, fr) * (1.0 - smoothstep(0.3, 0.45, fr));
		c = mix(c, mix(c_dry, bare_color, 0.45), path * kt);
		c *= 1.0 - 0.18 * riser * kt;
	}
	// 5–20 м: куртины гуще (темнее, зеленее) / реже (светлее, суше)
	if (k1 > 0.0) {
		float tuft = fbm(p / tuft_scale_m + vec2(2.3, 7.7), 2);
		c = mix(c, mix(c_lush, c_dry, smoothstep(0.3, 0.7, tuft)), tuft_strength * 2.0 * k1);
	}
	// кочки и пучки 2–6 м
	if (k_mid > 0.0) {
		float tus = vnoise(p / 3.5) * 0.6 + vnoise(p / 1.3) * 0.4;
		c *= mix(1.0, 0.82 + 0.36 * tus, k_mid);
		// тропинки: извилистые линии ~1,5 м (светлее, к грунту)
		float tr = abs(fbm(p / 260.0 + vec2(9.1, 3.3), 2) - 0.5);
		float path2 = (1.0 - smoothstep(0.0012, 0.003, tr)) * step(0.62, vnoise(p / 400.0));
		c = mix(c, mix(c, bare_color, 0.6), path2 * k_mid * 0.6);
	}
	if (k_fine > 0.0) {
		c *= mix(1.0, 0.92 + 0.16 * vnoise(p / 0.5), k_fine);
	}
	// камни в траве (одна клетка — один камень или пусто)
	float ks = 1.0 - smoothstep(0.3 * stone_size_m.y, 1.5 * stone_size_m.y, foot);
	if (ks > 0.0) {
		vec2 g = floor(p / stone_cell_m);
		float hs = hash12(g + vec2(41.3, 7.9));
		float dens = stone_density * stones_k * (1.0 + 2.0 * sw);
		if (hs < dens) {
			vec2 ctr = (g + 0.5 + (vec2(hash12(g + 3.1), hash12(g + 8.7)) - 0.5) * 0.5) * stone_cell_m;
			float r = mix(stone_size_m.x, stone_size_m.y, hash12(g + 5.3));
			vec2 v = (p - ctr) / r;
			v.x += 0.3 * sin(atan(v.y, v.x) * 3.0 + hs * 20.0) * length(v) * 0.3;
			float dd = length(v);
			float st = 1.0 - smoothstep(0.8, 1.0 + foot / r, dd);
			float top = sqrt(max(1.0 - dd * dd, 0.0));
			vec3 sc = stone_color * (0.7 + 0.5 * hash12(g + 1.1)) * (0.75 + 0.35 * top);
			float ring = smoothstep(1.0, 1.4, dd) * (1.0 - smoothstep(1.4, 1.8, dd));
			c = mix(c * (1.0 - 0.35 * ring * ks), sc, st * ks);
		}
	}
	return c;
}

// Фактура поля: направление обработки по участку, полосы и колеи техники, межи.
vec3 field_detail(vec2 p, vec3 c, vec3 meadow, float foot) {
	vec2 q = p / field_size_m + vec2(floor(p.y / (field_size_m.y * 6.0)) * 0.37, 0.0);
	vec2 cell = floor(q);
	vec2 f = q - cell;
	float h = hash12(cell + 19.1);
	vec2 dir = h < 0.5 ? vec2(1.0, 0.0) : vec2(0.0, 1.0);   // полосы вдоль длинной/короткой стороны
	float along = dot(p, vec2(dir.y, dir.x));
	float k_mid = 1.0 - smoothstep(2.0, 8.0, foot);
	float k_big = 1.0 - smoothstep(8.0, 30.0, foot);
	// борозды ~3 м
	c *= mix(1.0, 0.9 + 0.2 * (0.5 + 0.5 * sin(along * 6.2832 / 3.0)), k_mid);
	// технологические колеи каждые 18 м (тёмные двойные линии)
	float tram = abs(fract(along / 18.0) - 0.5) * 18.0;
	c *= 1.0 - 0.25 * (1.0 - smoothstep(0.3, 0.9, tram)) * k_mid;
	// спелость пятнами по полю
	c *= mix(1.0, 0.88 + 0.24 * fbm(p / 45.0 + h * 13.0, 2), k_big);
	// межа: полоса травы по краю участка ~3 м
	vec2 e = min(f, 1.0 - f) * field_size_m;
	float edge = 1.0 - smoothstep(1.5, 3.0, min(e.x, e.y));
	return mix(c, meadow * 0.9, edge * k_big);
}

// Нормаль по билинейной поверхности в точке (градиент внутри клетки сетки).
vec3 bilinear_normal(vec2 xz) {
	vec2 f = (xz - layer_origin) / layer_spacing;
	vec2 i = floor(f);
	vec2 t = f - i;
	ivec2 ij = ivec2(i);
	float a = h_node(ij);
	float b = h_node(ij + ivec2(1, 0));
	float c = h_node(ij + ivec2(0, 1));
	float d = h_node(ij + ivec2(1, 1));
	float dhdx = mix(b - a, d - c, t.y) / layer_spacing;
	float dhdz = mix(c - a, d - b, t.x) / layer_spacing;
	return normalize(vec3(-dhdx, 1.0, -dhdz));
}

void fragment() {
	vec3 wp = v_world;
	if (all(greaterThan(wp.xz, hole_min)) && all(lessThan(wp.xz, hole_max))) {
		discard;
	}
	float dist = length(wp - CAMERA_POSITION_WORLD);
	// Нормаль вершины — сглаженная (центральные разности по узлам): по ней классифицируем
	// поверхность (уклон, экспозиция), чтобы ступеньки DSM на опушках не красились в скалы.
	vec3 n_class = normalize(v_normal_world);
	vec3 n = n_class;
	// У грубых LOD вершины редкие: добавляем освещению детали из сетки (нормаль билинейной
	// поверхности), пока клетка сетки крупнее пикселя — иначе мерцание.
	if (v_lod_stride > 1.5) {
		vec2 fw = fwidth(wp.xz);
		float footprint = max(fw.x, fw.y);
		float fine_w = 1.0 - smoothstep(0.3 * layer_spacing, layer_spacing, footprint);
		if (fine_w > 0.0) {
			n = normalize(mix(n, bilinear_normal(wp.xz), fine_w));
		}
	}
	float h = wp.y;
	float fade = 1.0 - smoothstep(detail_fade_m * 0.25, detail_fade_m, dist);
	vec2 fw_m = fwidth(wp.xz);
	float foot_m = max(fw_m.x, fw_m.y);

	vec4 wa;
	vec4 wb;
	surface_weights(wp.xz, wa, wb);
	// глубина внутри леса 0..1 (затемнение опушки — только внутри)
	float forest_in = smoothstep(0.5, 0.95, wa.x);
	// Лес — по маске 10 м: резкий порог 0,5 с узким шумом; вдали (клетка мельче пикселя) —
	// карта классов 25 м (и без выборок из большой маски — дёшево). Остальные классы делят долю
	// «не лес» в прежней пропорции.
	float k10 = use_forest_mask
			? 1.0 - smoothstep(forest_mask_spacing, 2.5 * forest_mask_spacing, foot_m) : 0.0;
	if (k10 > 0.0) {
		vec2 q = wp.xz;
		vec2 jit = vec2(vnoise(q / 9.0), vnoise(q / 9.0 + vec2(5.2, 1.3))) - 0.5;
		float r0 = forest_mask_r(q + jit * forest_edge_warp_m);
		float nz = vnoise(q / 3.0 + vec2(1.7, 9.2)) - 0.5;
		float f10 = smoothstep(0.5 - forest_edge_soft, 0.5 + forest_edge_soft,
				r0 + nz * forest_edge_noise);
		// окрестность ±d (шаг нормали вершины): ступенька крон DSM и глубина в лесу
		float d = max(layer_spacing * v_lod_stride, canopy_edge_depth_m);
		float rx1 = forest_mask_r(q + vec2(d, 0.0));
		float rx0 = forest_mask_r(q - vec2(d, 0.0));
		float rz1 = forest_mask_r(q + vec2(0.0, d));
		float rz0 = forest_mask_r(q - vec2(0.0, d));
		float fnew = mix(wa.x, f10, k10);
		float rest = 1.0 - wa.x;
		float kr = (1.0 - fnew) / max(rest, 0.02);
		wa.yzw *= kr;
		wb *= kr;
		wa.y += (1.0 - fnew) - rest * kr;   // под «не лес» в лесной клетке 25 м — луг
		wa.x = fnew;
		float r_min = min(min(rx0, rx1), min(rz0, rz1));
		forest_in = mix(forest_in, smoothstep(0.3, 0.9, min(r_min, r0 + 0.3)), k10);
		// Уклон земли у кромки — без ступеньки крон: градиент DSM минус H·градиент маски.
		// Лес освещается по DSM (кроны), луг и классы по уклону — по «земле».
		vec2 g = k10 * canopy_dsm_height_m * vec2(rx1 - rx0, rz1 - rz0) / (2.0 * d);
		vec2 gc = n_class.xz / max(n_class.y, 0.05) + g;
		n_class = normalize(vec3(gc.x, 1.0, gc.y));
		vec2 gn = n.xz / max(n.y, 0.05) + g * (1.0 - wa.x);
		n = normalize(vec3(gn.x, 1.0, gn.y));
	}
	float slope_deg = degrees(acos(clamp(n_class.y, 0.0, 1.0)));
	float forest = wa.x;
	float crop = wa.z;
	float shrub = wa.w;
	float bare = wb.x;
	float built = wb.z;
	float snow = wb.w;
	float north = northness(n_class);
	float patch2 = meadow_patch(wp.xz);

	// --- выходы породы и курумник: гребни/бугры (выпуклость по сетке высот) и крутые луга ---
	float outcrop = 0.0;
	float kurum = 0.0;
	float open_w = wa.y + shrub + bare;
	if (open_w > 0.01 && outcrop_amount > 0.0) {
		float convex = smoothstep(0.25, 1.0, v_convex / outcrop_convex_k);
		float steep = smoothstep(outcrop_slope_deg.x, outcrop_slope_deg.y, slope_deg);
		float drv = max(convex, steep);
		if (drv > 0.01) {
			// пятна породы рваные: крупный шум + дробление 3–10 м (гаснет, когда мельче пикселя)
			float kf = 1.0 - smoothstep(2.0, 8.0, foot_m);
			float brk = vnoise(wp.xz / (outcrop_patch_m * 0.18));
			if (kf > 0.0) {
				brk = mix(brk, brk * 0.6 + vnoise(wp.xz / (outcrop_patch_m * 0.06) + vec2(3.7, 0.4)) * 0.4, kf);
			}
			float pn = fbm(wp.xz / outcrop_patch_m + vec2(12.7, 3.1), 2) + 0.2 * (brk - 0.5);
			outcrop = smoothstep(0.5, 0.56, pn + 0.2 * (drv - 1.0)) * smoothstep(0.0, 0.3, drv)
					* outcrop_amount;
			kurum = clamp(smoothstep(0.35, 0.65, vnoise(wp.xz / 160.0 + vec2(3.3, 1.1))
					+ kurum_share - 0.5) + 0.35 * (steep - convex), 0.0, 1.0);
		}
	}

	// --- луг: сухая трава на южных склонах и пятнами ---
	vec3 gcol = meadow_color(wp.xz, north, patch2);
	float tex_w = fade * texture_strength;

	// --- пашня/поля: прямоугольные участки разного цвета (пашня, всходы, стерня) ---
	vec3 fcol = field_plot_color(wp.xz, gcol);
	if (crop > 0.01) {
		fcol = field_detail(wp.xz, fcol, gcol, foot_m);
	}
	if (wa.y + wa.w + crop > 0.01) {
		gcol = meadow_detail(wp.xz, gcol, foot_m, h, n_class, slope_deg, 1.0 + 6.0 * outcrop);
	}

	// --- кустарник: пятнистая тёмная зелень на траве ---
	float bush = smoothstep(0.35, 0.65, fbm(wp.xz / (detail_scale_m * 3.0), 3));
	vec3 scol = mix(gcol, shrub_color, mix(0.6, 1.0, bush * fade + (1.0 - fade) * 0.5));

	vec3 col = gcol * wa.y + fcol * crop + scol * shrub;
	if (use_grass_tex) {
		col = apply_tex(col, texture(grass_tex, wp.xz / grass_tex_tile_m).rgb, grass_tex_avg,
				tex_w * (wa.y + crop + shrub));
	}

	// --- ветер (VR-17): волны порывов по траве и ниве, закрученный подсос над термиками ---
	float sway_w = wa.y + 1.3 * crop + 0.5 * shrub;
	vec2 grass_bend = vec2(0.0);
	if (sway_w > 0.01) {
		float wshade;
		grass_wind(wp.xz, dist, TIME, wshade, grass_bend);
		col *= 1.0 + wind_shade * wshade * sway_w;
		grass_bend *= wind_bend * sway_w;
	}

	// --- голый грунт / осыпи ---
	vec3 bcol = bare_color * (0.8 + 0.4 * fbm(wp.xz / 25.0 + vec2(3.3, 8.1), 3));
	// --- застройка: кварталы (крыши, дворы, дороги) ---
	vec2 blk = floor(wp.xz / 18.0);
	float bh = hash12(blk + 3.3);
	vec3 ucol = built_color * (0.7 + 0.6 * bh);
	ucol = mix(ucol, gcol * 0.9, step(0.72, bh));   // дворы, сады
	// --- снег ---
	vec3 wcol = snow_color;
	if (use_snow_tex) {
		wcol = apply_tex(wcol, texture(snow_tex, wp.xz / snow_tex_tile_m).rgb, snow_tex_avg, tex_w);
	}
	col += bcol * bare + ucol * built + wcol * snow;

	// --- лес: полог из крон (ячейки canopy_cell_m) с освещением и тенями; вдали — средний тон ---
	float con_p = conifer_share(patch2, north);
	vec3 fmean = mix(birch_color, forest_color, con_p);
	float foot = foot_m;
	float crown_k = 1.0 - smoothstep(0.2 * canopy_cell_m, 0.8 * canopy_cell_m, foot);
	// средний тон полога вдали: смесь крон и теней под ними приглушает цвет (по фото (a) стенда T01)
	// (плавно по следу пикселя 1–4 шага крон — без кольца на границе детального полога)
	float far_k = smoothstep(0.8 * canopy_cell_m, 2.5 * canopy_cell_m, foot_m);
	vec3 fcolor = mix(fmean * 0.62, mix(vec3(dot(fmean, vec3(0.2126, 0.7152, 0.0722))), fmean,
			canopy_far_sat) * canopy_far_shade, far_k);
	vec3 crown_n = vec3(0.0, 1.0, 0.0);
	// куртины (группы крон, ×3 шага) — видны до нескольких км, когда отдельные кроны уже мельче пикселя
	float grp_cell = canopy_cell_m * 3.0;
	float grp_k = 1.0 - smoothstep(0.2 * grp_cell, 0.8 * grp_cell, foot);
	if (forest > 0.01 && grp_k > 0.0) {
		float gs;
		vec3 gn;
		vec3 gt;
		canopy(wp.xz + vec2(3.7, 1.3), grp_cell, con_p, gs, gn, gt);
		fcolor = mix(fcolor, fcolor * (0.55 + 0.75 * gs), grp_k * 0.8);
		crown_n = normalize(mix(crown_n, gn, grp_k * 0.5));
	}
	if (forest > 0.01 && crown_k > 0.0) {
		float cs;
		vec3 cn;
		vec3 ctint;
		canopy(wp.xz, canopy_cell_m, con_p, cs, cn, ctint);
		fcolor = mix(fcolor, ctint * cs, crown_k);
		crown_n = normalize(mix(crown_n, cn, crown_k));
	}
	// древостои: светлее/темнее пятнами 50–200 м (возраст, состав, густота)
	// + крупнее (массивы 300–800 м) — видны с 2 км, когда отдельные кроны и куртины уже мельче пикселя
	if (forest > 0.01) {
		float stands = fbm(wp.xz / 90.0 + vec2(8.1, 2.2), 3) - 0.5
				+ canopy_far_big * (fbm(wp.xz / 450.0 + vec2(2.6, 7.4), 2) - 0.5) * (1.0 - crown_k);
		float sv = mix(canopy_far_var, canopy_stand_var, crown_k);
		fcolor *= clamp(1.0 + sv * stands * 2.0, 0.25, 2.0);
		// опушка темнее (тень стены леса, густой подрост) — только внутри леса, луг у кромки не трогаем
		fcolor *= 1.0 - canopy_edge_dark * (1.0 - forest_in);
	}
	if (use_forest_tex) {
		fcolor = apply_tex(fcolor, texture(forest_tex, wp.xz / forest_tex_tile_m).rgb, forest_tex_avg, tex_w);
	}
	col += fcolor * forest;
	// цвет суши без доли воды (вода смешивается ниже со своим блеском)
	float land = max(1.0 - wb.y, 1e-3);
	col /= land;

	// --- скалы: крутые склоны без леса (луг, кустарник, грунт на крутизне — выходы породы) ---
	float rnoise = fbm(wp.xz / 40.0 + vec2(5.1, 2.3), 3);
	float rock = smoothstep(rock_slope_deg - rock_blend_deg * 0.5, rock_slope_deg + rock_blend_deg * 0.5,
			slope_deg + 10.0 * (rnoise - 0.5)) * (wa.y + crop + shrub + bare) / land;
	// цвет породы — только там, где есть скалы или выходы породы (текстуры — с производными,
	// посчитанными до ветвления)
	vec3 rcol = rock_color;
	vec3 rn_add = vec3(0.0);
	vec2 uv_xy = wp.xy / rock_tex_tile_m;
	vec2 uv_zy = wp.zy / rock_tex_tile_m;
	vec2 uv_xz = wp.xz / rock_tex_tile_m;
	vec4 dxy = vec4(dFdx(uv_xy), dFdy(uv_xy));
	vec4 dzy = vec4(dFdx(uv_zy), dFdy(uv_zy));
	vec4 dxz = vec4(dFdx(uv_xz), dFdy(uv_xz));
	if (rock > 0.001) {
		// порода: охра/бурые тона крупными пятнами, светлее/темнее по высоте
		float rtone = fbm(wp.xz / rock_tone_scale_m + vec2(1.3, 8.8), 3);
		rcol = mix(rock_color, rock_color2, smoothstep(0.3, 0.7, rtone));
		rcol *= 0.75 + 0.5 * fbm(wp.xz / 12.0 + vec2(wp.y / 8.0), 3);
		// горизонтальная слоистость (видна издалека на обрывах)
		float sy = wp.y + 10.0 * (fbm(wp.xz / 250.0, 2) - 0.5) * 2.0;
		float strata = 0.5 + 0.5 * sin(6.2832 * sy / strata_m) * 0.7
				+ 0.3 * sin(6.2832 * sy / (strata_m * 3.7) + 1.3);
		rcol *= 1.0 - strata_strength * strata * (1.0 - smoothstep(0.7, 0.95, n_class.y));
		if (use_rock_tex) {
			// скалы крутые — текстура по двум вертикальным проекциям (упрощённый triplanar)
			// (+ проекция сверху — для выходов породы на пологих гребнях)
			float bx = abs(n_class.x) / max(1e-3, abs(n_class.x) + abs(n_class.z));
			vec3 ta = textureGrad(rock_tex, uv_xy, dxy.xy, dxy.zw).rgb;
			vec3 tb = textureGrad(rock_tex, uv_zy, dzy.xy, dzy.zw).rgb;
			float by = smoothstep(0.75, 0.92, n_class.y);
			vec3 tsum = mix(ta, tb, bx);
			if (by > 0.0) {
				tsum = mix(tsum, textureGrad(rock_tex, uv_xz + 0.37, dxz.xy, dxz.zw).rgb, by);
			}
			rcol = apply_tex(rcol, tsum, rock_tex_avg, tex_w);
			if (use_rock_normal) {
				vec3 na = textureGrad(rock_normal_tex, uv_xy, dxy.xy, dxy.zw).rgb * 2.0 - 1.0;
				vec3 nb = textureGrad(rock_normal_tex, uv_zy, dzy.xy, dzy.zw).rgb * 2.0 - 1.0;
				// касательные возмущения в мировых осях проекций (xy → вдоль x и y, zy → вдоль z и y)
				rn_add = mix(vec3(na.x, na.y, 0.0), vec3(0.0, nb.y, nb.x), bx) * 0.6 * fade;
			}
		}
		// лишайник пятнами на верхних гранях камней
		float lich = smoothstep(0.55, 0.75, fbm(wp.xz / 7.0 + vec2(wp.y / 5.0, 2.7), 3));
		rcol = mix(rcol, lichen_color * (0.8 + 0.4 * rtone), lich * lichen_amount * smoothstep(0.3, 0.8, n_class.y));
	}

	// осыпи: у подножия крутых участков — склон ниже обрыва (выше по склону круче скал)
	float slope_up = 0.0;
	if (slope_deg > scree_min_deg - 4.0 && forest < 0.99) {
		vec2 up_dir = length(n_class.xz) > 1e-3 ? -normalize(n_class.xz) : vec2(0.0);
		vec2 pu = wp.xz + up_dir * scree_probe_m;
		vec3 n_up = bilinear_normal(pu);
		if (k10 > 0.0) {
			// ступенька крон выше по склону — не обрыв
			float e = layer_spacing * 0.5;
			vec2 g = k10 * canopy_dsm_height_m / (2.0 * e) * vec2(
					forest_mask_r(pu + vec2(e, 0.0)) - forest_mask_r(pu - vec2(e, 0.0)),
					forest_mask_r(pu + vec2(0.0, e)) - forest_mask_r(pu - vec2(0.0, e)));
			vec2 gu = n_up.xz / max(n_up.y, 0.05) + g;
			n_up = normalize(vec3(gu.x, 1.0, gu.y));
		}
		slope_up = degrees(acos(clamp(n_up.y, 0.0, 1.0)));
	}
	float scree = smoothstep(rock_slope_deg - 2.0, rock_slope_deg + 8.0, slope_up)
			* smoothstep(6.0, 14.0, slope_up - slope_deg)
			* smoothstep(scree_min_deg - 4.0, scree_min_deg + 4.0, slope_deg) * 0.8
			* (1.0 - rock) * (wa.y + shrub + bare) / land
			* smoothstep(0.35, 0.6, fbm(wp.xz / 30.0 + vec2(4.4, 0.7), 3) + 0.15);
	vec2 uv_sc = wp.xz / scree_tex_tile_m;
	vec4 dsc = vec4(dFdx(uv_sc), dFdy(uv_sc));
	if (scree > 0.001) {
		vec3 screecol = scree_color * (0.85 + 0.3 * fbm(wp.xz / 6.0, 3));
		if (use_scree_tex) {
			screecol = apply_tex(screecol, textureGrad(scree_tex, uv_sc, dsc.xy, dsc.zw).rgb,
					scree_color, tex_w);
		}
		col = mix(col, screecol, scree);
	}
	// выходы породы: коренная порода (rcol) или курумник — глыбы с тёмными щелями
	float ocw = outcrop * open_w / land * (1.0 - rock);
	if (ocw > 0.001) {
		float onz = vnoise(wp.xz / 9.0 + vec2(1.9, 4.4));
		vec3 kcol = kurum_color * (0.85 + 0.3 * onz);
		float kb = 1.0 - smoothstep(0.12 * kurum_block_m, 0.4 * kurum_block_m, foot_m);
		if (kb > 0.0 && kurum > 0.01) {
			// одна глыба на клетку (без поиска соседей): центр чуть сдвинут, радиус 0.4–0.5 клетки
			vec2 bid = floor(wp.xz / kurum_block_m);
			vec2 bv = wp.xz - (bid + 0.5 + (canopy_hash2(bid) - 0.5) * 0.2) * kurum_block_m;
			float br = kurum_block_m * mix(0.4, 0.5, hash12(bid + 1.7));
			float bd = length(bv) / br;
			float inside = 1.0 - smoothstep(0.85, 1.0, bd);
			float top = sqrt(max(1.0 - bd * bd, 0.0));
			vec3 bn = normalize(vec3(bv.x / br, top + 0.001, bv.y / br));
			vec3 sd = normalize(sun_dir);
			float lit = 0.6 + 0.6 * clamp(dot(bn, sd), 0.0, 1.0);
			float blk = mix(0.45, lit * (0.75 + 0.5 * hash12(bid + 2.2)), inside);
			// среднее по пятну ≈ 1: без скачка яркости при растворении глыб вдали
			kcol *= mix(1.0, blk / 0.95, kb);
		}
		if (use_scree_tex) {
			kcol = apply_tex(kcol, textureGrad(scree_tex, uv_sc / 1.6, dsc.xy / 1.6, dsc.zw / 1.6).rgb,
					scree_color, tex_w * 0.7);
		}
		// коренная порода: плиты с тёмными трещинами и тенями уступов (видно с сотен метров)
		// (дешёвый цвет породы: тон пятнами + текстура вблизи; полный rcol — только у скал)
		float rt = vnoise(wp.xz / rock_tone_scale_m + vec2(1.3, 8.8));
		vec3 bed = mix(rock_color, rock_color2, smoothstep(0.3, 0.7, rt)) * (0.7 + 0.6 * onz);
		bed = mix(bed, lichen_color * (0.8 + 0.4 * rt),
				lichen_amount * 0.6 * smoothstep(0.55, 0.75, onz) * smoothstep(0.3, 0.8, n_class.y));
		float kc = 1.0 - smoothstep(0.3, 1.2, foot_m);
		if (kc > 0.0) {
			if (use_rock_tex) {
				bed = apply_tex(bed, textureGrad(rock_tex, uv_xz + 0.37, dxz.xy, dxz.zw).rgb,
						rock_tex_avg, tex_w * kc);
			}
			float crack = 1.0 - smoothstep(0.0, 0.06 + 0.05 * foot_m,
					abs(vnoise(wp.xz / 7.0 + 2.2) - 0.5));
			bed *= 1.0 - 0.45 * crack * kc;
		}
		vec3 ocol = mix(bed, kcol, kurum);
		col = mix(col, ocol, ocw);
	}
	col = mix(col, rcol, rock);

	// снег в кулуарах и ложбинах высоких гор (по высоте, вогнутости, экспозиции), а не шапкой
	float gd = max(gully_scale_m, 2.0 * layer_spacing);
	float lap = -1.0;
	if (h > gully_snow_line_m - gully_north_m - 200.0 && forest < 0.99) {
		lap = (h_bilinear(wp.xz + vec2(gd, 0.0)) + h_bilinear(wp.xz - vec2(gd, 0.0))
			+ h_bilinear(wp.xz + vec2(0.0, gd)) + h_bilinear(wp.xz - vec2(0.0, gd))
			- 4.0 * h_bilinear(wp.xz)) / (4.0 * gd);
	}
	float gully = smoothstep(0.0, gully_k, lap + 0.02 * (rnoise - 0.5));
	float gsnow = gully * smoothstep(gully_snow_line_m - 100.0, gully_snow_line_m + 150.0,
			h + gully_north_m * max(north, 0.0) + 120.0 * (patch2 - 0.5))
			* (1.0 - smoothstep(48.0, 58.0, slope_deg)) * (1.0 - forest);
	col = mix(col, snow_color * (0.9 + 0.1 * fbm(wp.xz / 9.0, 2)), gsnow);

	// --- мелкая детализация (кочки, пятна) ---
	float d1 = fbm(wp.xz / detail_scale_m, 3);
	float d2 = vnoise(wp.xz / (detail_scale_m * 8.0));
	// самый мелкий масштаб (пучки травы, камни) — только совсем рядом
	float near_fade = 1.0 - smoothstep(detail_fade_m * 0.02, detail_fade_m * 0.1, dist);
	float d0 = vnoise(wp.xz / (detail_scale_m * 0.25)) * 0.6 + vnoise(wp.xz / (detail_scale_m * 0.05)) * 0.4;
	float grassy = (wa.y + crop + shrub) * (1.0 - rock) * (1.0 - outcrop);
	// оттенок травы гуляет пятнами 10–30 м
	// (на лугу пятна 20–200 м рисует meadow_detail — здесь слабее, без «камуфляжа»)
	float d2k = 1.0 - 0.6 * wa.y;
	col = mix(col, col * vec3(1.08, 1.0, 0.8), grassy * fade * d2k * smoothstep(0.4, 0.7, d2));
	col *= 1.0 + detail_strength * fade * ((d1 - 0.5) * 1.2 + (d2 - 0.5) * 0.8 * d2k)
			+ detail_strength * near_fade * (d0 - 0.5) * 1.2;

	n = normalize(n + vec3(grass_bend.x, 0.0, grass_bend.y) + rn_add * max(rock, outcrop * (1.0 - kurum)));
	// нормали крон (освещение полога)
	n = normalize(mix(n, normalize(n + vec3(crown_n.x, 0.0, crown_n.z) * 1.5), forest * crown_k * 0.6));
	// возмущение нормали шумом (кроны/кочки), чтобы вблизи поверхность не была «пластиковой»
	if (fade > 0.0) {
		float e = detail_scale_m * 0.5;
		vec2 q = wp.xz / (detail_scale_m * 1.6);
		float c0 = fbm(q, 3);
		float cx = fbm(q + vec2(e / (detail_scale_m * 1.6), 0.0), 3);
		float cz = fbm(q + vec2(0.0, e / (detail_scale_m * 1.6)), 3);
		float amp = fade * mix(0.25, canopy_bump, forest);
		vec3 bump = vec3(-(cx - c0), 0.0, -(cz - c0)) * amp;
		n = normalize(n + bump);
	}

	// --- вода (реки, ручьи, озёра): класс «вода» WorldCover (карта 25 м) или маска 10 м (T03,
	// OSM — точнее по форме и не мигает с шагом карты классов); максимум из двух ---
	float water_g = use_forest_mask ? forest_mask_g_aa(wp.xz, foot_m) : 0.0;
	float water = max(wb.y, water_g);
	// берег: тонкая полоса мокрого грунта/гальки у кромки воды маски 10 м (не на самой воде)
	float bank = use_forest_mask
			? smoothstep(0.02, 0.22, water_g) * (1.0 - smoothstep(0.22, 0.4, water_g))
			: 0.0;
	vec3 bank_color = mix(bare_color, rock_color, 0.3) * 0.55;
	col = mix(col, bank_color, bank * (1.0 - water));
	float ripple = vnoise(wp.xz / 6.0 + vec2(TIME * 0.3, 0.0)) - 0.5;
	col = mix(col, water_color * (1.0 + 0.1 * ripple * fade), water);
	n = normalize(mix(n, vec3(0.03 * ripple, 1.0, 0.0), water));

	ALBEDO = clamp(col, 0.0, 1.0);
	ROUGHNESS = mix(roughness_value, water_roughness, water);
	SPECULAR = mix(specular_value * (1.0 - forest * 0.7), 0.5, water);
	NORMAL = normalize((VIEW_MATRIX * vec4(n, 0.0)).xyz);
}
