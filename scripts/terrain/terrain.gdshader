// Рельеф: высоты из текстуры (вершинный шейдер), раскраска по карте поверхности (VR-4: лес,
// луг, пашня, кустарник, скалы/грунт, вода, застройка, снег — та же карта, что у источников
// термиков), по уклону (скалы на крутом) + шум детализации (FR-19). Все параметры задаёт
// terrain_renderer.gd из configs/world.json → terrain_look (числа в шейдере — только технические).
shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

#include "res://scripts/terrain/terrain_common.gdshaderinc"

// шаг между вершинами чанка в узлах сетки (1, 2, 4…) — для гладкой нормали вершины
instance uniform float lod_stride = 1.0;
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
	float patch2 = fbm(wp.xz / (patch_scale_m * 0.12) + vec2(31.7, 11.2), 4);

	// --- луг: сухая трава на южных склонах и пятнами ---
	float dry = clamp(0.5 + 0.8 * (patch2 - 0.5) - 0.35 * north, 0.0, 1.0);
	vec3 gcol = mix(grass_color, dry_grass_color, dry * 0.55);
	float tex_w = fade * texture_strength;

	// --- пашня/поля: прямоугольные участки разного цвета (пашня, всходы, стерня) ---
	vec2 cell = floor(wp.xz / field_size_m + vec2(floor(wp.z / (field_size_m.y * 6.0)) * 0.37, 0.0));
	float fh = hash12(cell);
	vec3 fcol = mix(field_color, mix(grass_color, dry_grass_color, fh), step(0.45, fh));
	fcol *= 0.85 + 0.3 * hash12(cell + 7.0);

	// --- кустарник: пятнистая тёмная зелень на траве ---
	float bush = smoothstep(0.35, 0.65, fbm(wp.xz / (detail_scale_m * 3.0), 3));
	vec3 scol = mix(gcol, shrub_color, mix(0.6, 1.0, bush * fade + (1.0 - fade) * 0.5));

	vec3 col = gcol * wa.y + fcol * crop + scol * shrub;
	if (use_grass_tex) {
		col = apply_tex(col, texture(grass_tex, wp.xz / grass_tex_tile_m).rgb, grass_tex_avg,
				tex_w * (wa.y + crop + shrub));
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

	// --- лес ---
	vec3 fcolor = mix(birch_color, forest_color, conifer_share(patch2, north));
	// кроны деревьев: мелкий шум, тёмные просветы
	float crowns = fbm(wp.xz / (detail_scale_m * 1.6), 3);
	fcolor *= mix(1.0, 0.55 + 0.9 * crowns, fade);
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
	vec3 rcol = rock_color * (0.75 + 0.5 * fbm(wp.xz / 12.0 + vec2(wp.y / 8.0), 3));
	if (use_rock_tex) {
		// скалы крутые — текстура по двум вертикальным проекциям (упрощённый triplanar)
		vec3 ta = texture(rock_tex, wp.xy / rock_tex_tile_m).rgb;
		vec3 tb = texture(rock_tex, wp.zy / rock_tex_tile_m).rgb;
		rcol = apply_tex(rcol, mix(ta, tb, abs(n_class.x) / max(1e-3, abs(n_class.x) + abs(n_class.z))), rock_tex_avg, tex_w);
	}
	col = mix(col, rcol, rock);

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

	// возмущение нормали шумом (кроны/кочки), чтобы вблизи поверхность не была «пластиковой»
	if (fade > 0.0) {
		float e = detail_scale_m * 0.5;
		vec2 q = wp.xz / (detail_scale_m * 1.6);
		float c0 = fbm(q, 3);
		float cx = fbm(q + vec2(e / (detail_scale_m * 1.6), 0.0), 3);
		float cz = fbm(q + vec2(0.0, e / (detail_scale_m * 1.6)), 3);
		float amp = fade * mix(0.25, canopy_bump * 3.0, forest);
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
