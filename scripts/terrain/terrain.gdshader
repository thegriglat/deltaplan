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
uniform float canopy_edge_dark = 0.2;         // опушка темнее (тень леса на краю)
uniform vec3 water_color : source_color;
uniform float water_roughness = 0.1;
uniform float roughness_value;
uniform float specular_value;

varying vec3 v_world;
varying vec3 v_normal_world;
varying flat float v_lod_stride;

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

// Фактура луга с высоты: куртины гуще/реже, кочки, тропинки. k — доля детали (гаснет с пикселем).
vec3 meadow_detail(vec2 p, vec3 c, float foot) {
	float k_big = 1.0 - smoothstep(6.0, 25.0, foot);
	float k_mid = 1.0 - smoothstep(1.5, 6.0, foot);
	float k_fine = 1.0 - smoothstep(0.4, 1.5, foot);
	// куртины 20–60 м: гуще (темнее, зеленее) / реже (светлее, суше)
	float cl = fbm(p / 35.0 + vec2(2.3, 7.7), 3);
	c *= mix(1.0, mix(1.18, 0.78, smoothstep(0.3, 0.7, cl)), k_big);
	c = mix(c, c * vec3(0.9, 1.05, 0.85), k_big * smoothstep(0.55, 0.75, cl));
	// кочки и пучки 2–6 м
	float tus = vnoise(p / 3.5) * 0.6 + vnoise(p / 1.3) * 0.4;
	c *= mix(1.0, 0.82 + 0.36 * tus, k_mid);
	// тропинки: извилистые линии ~1,5 м (светлее, к грунту)
	float tr = abs(fbm(p / 260.0 + vec2(9.1, 3.3), 2) - 0.5);
	float path = (1.0 - smoothstep(0.0012, 0.003, tr)) * step(0.62, vnoise(p / 400.0));
	c = mix(c, mix(c, bare_color, 0.6), path * k_mid * 0.6);
	return c * mix(1.0, 0.92 + 0.16 * vnoise(p / 0.5), k_fine);
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
	float slope_deg = degrees(acos(clamp(n_class.y, 0.0, 1.0)));
	float h = wp.y;
	float fade = 1.0 - smoothstep(detail_fade_m * 0.25, detail_fade_m, dist);

	vec4 wa;
	vec4 wb;
	surface_weights(wp.xz, wa, wb);
	float forest = wa.x;
	float crop = wa.z;
	float shrub = wa.w;
	float bare = wb.x;
	float built = wb.z;
	float snow = wb.w;
	float north = northness(n_class);
	float patch2 = meadow_patch(wp.xz);

	// --- луг: сухая трава на южных склонах и пятнами ---
	vec3 gcol = meadow_color(wp.xz, north, patch2);
	float tex_w = fade * texture_strength;

	// --- пашня/поля: прямоугольные участки разного цвета (пашня, всходы, стерня) ---
	vec3 fcol = field_plot_color(wp.xz, gcol);
	vec2 fw_m = fwidth(wp.xz);
	float foot_m = max(fw_m.x, fw_m.y);
	if (crop > 0.01) {
		fcol = field_detail(wp.xz, fcol, gcol, foot_m);
	}
	if (wa.y + wa.w + crop > 0.01) {
		gcol = meadow_detail(wp.xz, gcol, foot_m);
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
	vec2 fw_c = fwidth(wp.xz);
	float foot = max(fw_c.x, fw_c.y);
	float crown_k = 1.0 - smoothstep(0.2 * canopy_cell_m, 0.8 * canopy_cell_m, foot);
	// средняя яркость полога (освещённые кроны + просветы + тени) — к ней сходится детальный вид
	float mean_shade = 0.62;
	vec3 fcolor = fmean * mean_shade;
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
	fcolor *= 1.0 + 0.3 * (fbm(wp.xz / 90.0 + vec2(8.1, 2.2), 3) - 0.5) * 2.0;
	// опушка темнее: тень стены леса и густой подрост
	fcolor *= 1.0 - canopy_edge_dark * (1.0 - smoothstep(0.5, 0.95, forest));
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
	// порода: охра/бурые тона крупными пятнами, светлее/темнее по высоте
	float rtone = fbm(wp.xz / rock_tone_scale_m + vec2(1.3, 8.8), 3);
	vec3 rcol = mix(rock_color, rock_color2, smoothstep(0.3, 0.7, rtone));
	rcol *= 0.75 + 0.5 * fbm(wp.xz / 12.0 + vec2(wp.y / 8.0), 3);
	// горизонтальная слоистость (видна издалека на обрывах)
	float sy = wp.y + 10.0 * (fbm(wp.xz / 250.0, 2) - 0.5) * 2.0;
	float strata = 0.5 + 0.5 * sin(6.2832 * sy / strata_m) * 0.7
			+ 0.3 * sin(6.2832 * sy / (strata_m * 3.7) + 1.3);
	rcol *= 1.0 - strata_strength * strata * (1.0 - smoothstep(0.7, 0.95, n_class.y));
	vec3 rn_add = vec3(0.0);
	if (use_rock_tex) {
		// скалы крутые — текстура по двум вертикальным проекциям (упрощённый triplanar)
		float bx = abs(n_class.x) / max(1e-3, abs(n_class.x) + abs(n_class.z));
		vec3 ta = texture(rock_tex, wp.xy / rock_tex_tile_m).rgb;
		vec3 tb = texture(rock_tex, wp.zy / rock_tex_tile_m).rgb;
		rcol = apply_tex(rcol, mix(ta, tb, bx), rock_tex_avg, tex_w);
		if (use_rock_normal) {
			vec3 na = texture(rock_normal_tex, wp.xy / rock_tex_tile_m).rgb * 2.0 - 1.0;
			vec3 nb = texture(rock_normal_tex, wp.zy / rock_tex_tile_m).rgb * 2.0 - 1.0;
			// касательные возмущения в мировых осях проекций (xy → вдоль x и y, zy → вдоль z и y)
			rn_add = mix(vec3(na.x, na.y, 0.0), vec3(0.0, nb.y, nb.x), bx) * 0.6 * fade;
		}
	}
	// лишайник пятнами на верхних гранях камней
	float lich = smoothstep(0.55, 0.75, fbm(wp.xz / 7.0 + vec2(wp.y / 5.0, 2.7), 3));
	rcol = mix(rcol, lichen_color * (0.8 + 0.4 * rtone), lich * lichen_amount * smoothstep(0.3, 0.8, n_class.y));

	// осыпи: у подножия крутых участков — склон ниже обрыва (выше по склону круче скал)
	float slope_up = 0.0;
	if (slope_deg > scree_min_deg - 4.0 && forest < 0.99) {
		vec2 up_dir = length(n_class.xz) > 1e-3 ? -normalize(n_class.xz) : vec2(0.0);
		vec3 n_up = bilinear_normal(wp.xz + up_dir * scree_probe_m);
		slope_up = degrees(acos(clamp(n_up.y, 0.0, 1.0)));
	}
	float scree = smoothstep(rock_slope_deg - 2.0, rock_slope_deg + 8.0, slope_up)
			* smoothstep(6.0, 14.0, slope_up - slope_deg)
			* smoothstep(scree_min_deg - 4.0, scree_min_deg + 4.0, slope_deg) * 0.8
			* (1.0 - rock) * (wa.y + shrub + bare) / land
			* smoothstep(0.35, 0.6, fbm(wp.xz / 30.0 + vec2(4.4, 0.7), 3) + 0.15);
	vec3 screecol = scree_color * (0.85 + 0.3 * fbm(wp.xz / 6.0, 3));
	if (use_scree_tex) {
		screecol = apply_tex(screecol, texture(scree_tex, wp.xz / scree_tex_tile_m).rgb, scree_color, tex_w);
	}
	col = mix(col, screecol, scree);
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
	float grassy = (wa.y + crop + shrub) * (1.0 - rock);
	// оттенок травы гуляет пятнами 10–30 м
	col = mix(col, col * vec3(1.08, 1.0, 0.8), grassy * fade * smoothstep(0.4, 0.7, d2));
	col *= 1.0 + detail_strength * fade * ((d1 - 0.5) * 1.2 + (d2 - 0.5) * 0.8)
			+ detail_strength * near_fade * (d0 - 0.5) * 1.2;

	n = normalize(n + vec3(grass_bend.x, 0.0, grass_bend.y) + rn_add * rock);
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

	// --- вода (реки) ---
	float water = wb.y;
	float ripple = vnoise(wp.xz / 6.0 + vec2(TIME * 0.3, 0.0)) - 0.5;
	col = mix(col, water_color * (1.0 + 0.1 * ripple * fade), water);
	n = normalize(mix(n, vec3(0.03 * ripple, 1.0, 0.0), water));

	ALBEDO = clamp(col, 0.0, 1.0);
	ROUGHNESS = mix(roughness_value, water_roughness, water);
	SPECULAR = mix(specular_value * (1.0 - forest * 0.7), 0.5, water);
	NORMAL = normalize((VIEW_MATRIX * vec4(n, 0.0)).xyz);
}
