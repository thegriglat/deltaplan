// Средний план леса (≈ 0,4–2 км): деревья-билборды из атласа импостеров (assets/models/trees/
// trees_impostor_atlas.png). Сетка экземпляров едет за камерой, дерево привязано к мировой клетке;
// есть ли дерево — доля леса по маске 10 м ≥ 0,5 и не вода (канал G < water_max; V02; без маски —
// класс «лес» карты 25 м) и маска просек,
// у опушки гуще и раскидистее; порода — по высотному поясу и
// экспозиции (те же веса, что у моделей, configs/world.json → trees.species). Параметры задаёт
// ForestImpostors (forest_impostors.gd). Дальше — полог в шейдере рельефа, ближе — 3D-модели.
shader_type spatial;
render_mode cull_disabled, diffuse_lambert_wrap, world_vertex_coords, specular_disabled;

#include "res://scripts/terrain/terrain_common.gdshaderinc"
#include "res://scripts/terrain/scene_look.gdshaderinc"
#include "res://scripts/terrain/terrain_wind.gdshaderinc"
#include "res://scripts/terrain/cloud_shadow.gdshaderinc"

uniform sampler2D atlas : source_color, filter_linear_mipmap, repeat_disable;
uniform vec2 atlas_cells = vec2(4.0, 2.0);        // ячеек атласа (столбцы, строки)
uniform vec2 grid_center_cell;
uniform int grid_n;
uniform float spacing_m = 10.0;
uniform float inner_m = 350.0;                    // ближе — 3D-модели (плавный переход до inner_end_m)
uniform float inner_end_m = 500.0;
uniform bool band_mode = false;                   // SL-К4: экземпляр — дерево полосы смены (позиция и признаки из CPU: TreePlacer.imp_buffer)
uniform float band_end_m = 1e9;                   // SL-К4: дальше полоса не рисуется (дальше — сетка 12 м)
uniform float lod_swap_m = 500.0;                 // SL-К4: базовое расстояние смены модель → импостер (trees.radius_m); у дерева × sl_lod_k
uniform float lod_dither_m = 40.0;                // SL-К4: ширина дизеринга смены формы (trees.lod_dither_m)
uniform float outer_m = 2000.0;                   // дальше — только полог рельефа
uniform float dissolve_m = 800.0;                 // полоса у outer_m, где билборды по одному растворяются
uniform float density = 0.85;
uniform float sink_fraction = 0.4;
uniform float edge_sink_fraction = 0.05;
uniform float edge_probe_m = 30.0;
uniform float brightness = 1.15;                  // импостер уже «освещён» при запекании
uniform float edge_band_m = 16.0;                 // опушка: ближе к кромке — гуще и шире
uniform float edge_density = 1.0;
uniform float edge_scale_k = 0.15;
// смягчение вдали (отзыв пилота: билборды с расстояния читаются как резкие контрастные точки):
// снижаем насыщенность/контраст кроны и отпускаем жёсткий альфа-скиссор на мягкий край.
uniform float far_soft_start_m = 300.0;   // ближе — без изменений (стык с 3D-моделями)
uniform float far_soft_full_m = 1200.0;   // дальше — смягчение в полную силу
uniform float far_desaturate = 0.4;       // насколько бледнее крона вдали (0..1)
uniform float far_contrast = 0.35;        // насколько мягче контраст вдали (0..1)
uniform float far_canopy_luma = 0.32;     // характерная средняя яркость полога, к которой тянет контраст
uniform float far_edge_soft_k = 3.0;      // во сколько раз шире сглаживание края альфы вдали
// породы: pine, cedar, larch, birch, spruce
uniform float sp_weight[5];
uniform float sp_min[5];
uniform float sp_max[5];
uniform float sp_aspect[5];
uniform float sp_gain[5];            // SL-14: множитель альбедо породы (trees.albedo_gain), при sl_tree_albedo_enabled

uniform vec2 sp_height[5];
uniform float band_blend_m = 200.0;
// доля воды маски 10 м (канал G, реки/озёра OSM), с которой дерева нет (как TreePlacer.water_max)
uniform float water_max = 0.35;
// просеки (WorldClearings): 1 — расчищено
uniform sampler2D clear_tex : filter_nearest, repeat_disable;
uniform bool has_clearings = false;
uniform vec2 clear_origin;
uniform float clear_cell_m = 10.0;
uniform vec2 clear_size = vec2(1.0);

varying vec2 v_uv;
varying float v_tint;
varying float v_dist;
varying float v_lod_t;   // SL-К4: порог дизеринга band-импостера (виден при шум < v_lod_t); у сетки — 2
// тень облаков: множитель прямого солнца (cloud_shadow.gdshaderinc) — в light()
varying float v_cs_sun;
// scene-look (SL-2): средняя яркость ячейки атласа × tint, хвойное (1) / лиственное (0), нормаль склона
varying float v_sl_luma;
varying float v_sl_con;
varying float v_sl_dir;
varying float v_sl_gain;   // SL-14: множитель альбедо породы
// SL-6 сезон: порода (0 — вечнозелёная, 1 — берёза, 2 — лиственница) и состояние (окраска, голое)
varying float v_sl_kind;
varying vec4 v_sl_ss;
const float SL_DECID[5] = float[5](0.0, 0.0, 2.0, 1.0, 0.0); // SL
// хвойные по породам (pine, cedar, larch, birch, spruce — порядок TreePlacer.SPECIES); лиственница
// летом — светлая хвоя, по альбедо ближе к лиственным
const float SL_CONIFER[5] = float[5](1.0, 1.0, 0.0, 0.0, 1.0);

bool is_forest(vec2 xz) {
	if (use_forest_mask) {
		return forest_mask_r(xz) >= 0.5 && forest_mask_g(xz) < water_max;
	}
	return surface_node(ivec2(round((xz - surface_origin) / surface_spacing))) == 1;
}

// доля «не леса» на кольце радиуса r (4 направления)
float open_frac(vec2 xz, float r, float a0) {
	float n = 0.0;
	for (int k = 0; k < 4; k++) {
		float a = 1.5708 * float(k) + a0;
		n += float(!is_forest(xz + vec2(cos(a), sin(a)) * r));
	}
	return n * 0.25;
}

int pick_species(float h, float north, float u) {
	float w[5];
	float total = 0.0;
	for (int k = 0; k < 5; k++) {
		float band = clamp((h - sp_min[k]) / band_blend_m + 0.5, 0.0, 1.0)
				* clamp((sp_max[k] - h) / band_blend_m + 0.5, 0.0, 1.0);
		w[k] = sp_weight[k] * band * max(0.05, 1.0 + sp_aspect[k] * north);
		total += w[k];
	}
	if (total <= 0.0) {
		return -1;
	}
	float t = u * total;
	for (int k = 0; k < 5; k++) {
		t -= w[k];
		if (t <= 0.0) {
			return k;
		}
	}
	return 4;
}

void vertex() {
	int id = INSTANCE_ID;
	vec2 cell = grid_center_cell + vec2(float(id % grid_n), float(id / grid_n)) - float(grid_n / 2);
	vec2 jit = vec2(hash12(cell * 1.37 + 3.1), hash12(cell * 0.71 + 11.3)) - 0.5;
	vec2 xz = (cell + 0.5 + jit * 0.8) * spacing_m;
	if (band_mode) {
		xz = MODEL_MATRIX[3].xz;
		cell = floor(xz);
	}
	float d = length(xz - CAMERA_POSITION_WORLD.xz);
	v_lod_t = 2.0;
	// переход с 3D-моделями: доля импостеров растёт от inner_m к inner_end_m;
	// у outer_m билборды растворяются по одному (порог — хеш клетки), без полосы.
	// Сначала дешёвые проверки; нет дерева — вырожденный квад и выход (без выборок высот).
	float ring = smoothstep(inner_m, inner_end_m, d);
	float fade_out = smoothstep(outer_m - dissolve_m, outer_m, d);
	float u = hash12(cell + 5.7);
	bool present = d < outer_m && u < max(density, edge_density) * ring
			&& hash12(cell + 7.9) >= fade_out && is_forest(xz);
	if (band_mode) {
		// дерево полосы смены: есть всегда (лес, просеки и опушку учёл TreePlacer); доля — по личной границе
		v_lod_t = sl_lod_swap_t(d, lod_swap_m * sl_lod_k(xz), lod_dither_m);
		present = v_lod_t > 0.0 && d < band_end_m;
	}
	if (present && has_clearings && !band_mode) {
		vec2 cu = (xz - clear_origin) / (clear_cell_m * clear_size);
		if (all(greaterThanEqual(cu, vec2(0.0))) && all(lessThan(cu, vec2(1.0)))) {
			present = texture(clear_tex, cu).r < 0.5;
		}
	}
	// опушка: ближе к кромке — гуще и шире (стена деревьев)
	float ek = band_mode ? INSTANCE_CUSTOM.z : 0.0;
	if (present && !band_mode) {
		ek = min(1.0, 2.0 * max(open_frac(xz, edge_band_m * 0.5, 0.0), 0.5 * open_frac(xz, edge_band_m, 0.785)));
		present = u < mix(density, edge_density, ek) * ring;
	}
	// нет дерева — вырожденный квад (все вершины в одной точке)
	vec3 v = vec3(0.0);
	v_uv = vec2(0.0);
	v_tint = 0.0;
	v_dist = d;
	v_sl_luma = 0.0;
	v_sl_con = 1.0;
	v_sl_dir = 1.0;
	v_sl_gain = 1.0;
	v_sl_kind = 0.0;
	v_sl_ss = vec4(0.0);
	if (present) {
		float h = h_bilinear(xz);
		float e = layer_spacing;
		vec3 n = normalize(vec3(h_bilinear(xz - vec2(e, 0.0)) - h_bilinear(xz + vec2(e, 0.0)), 2.0 * e,
				h_bilinear(xz - vec2(0.0, e)) - h_bilinear(xz + vec2(0.0, e))));
		float horiz = length(n.xz);
		float north = horiz > 1e-4 ? clamp(-n.z / horiz, -1.0, 1.0) * clamp(horiz / n.y / 0.25, 0.0, 1.0) : 0.0;
		int sp = band_mode ? int(INSTANCE_CUSTOM.y + 0.5) : pick_species(h, north, hash12(cell + 4.1));
		if (sp >= 0) {
			float hh = band_mode ? INSTANCE_CUSTOM.x : mix(sp_height[sp].x, sp_height[sp].y, hash12(cell + 2.2));
			// вдали дерево чуть крупнее — чтобы не рябило и сливалось с пологом
			hh *= 1.0 + 0.4 * smoothstep(outer_m * 0.5, outer_m, d);
			// утопление: в глубине леса sink_fraction (кроны в DSM), у кромки меньше — стволы видны
			float sink = band_mode ? COLOR.r : mix(edge_sink_fraction, sink_fraction, 1.0 - open_frac(xz, edge_probe_m, 0.785));
			// цилиндрический билборд: поворот к камере вокруг вертикали
			vec2 to_cam = CAMERA_POSITION_WORLD.xz - xz;
			vec2 fwd = length(to_cam) > 0.01 ? normalize(to_cam) : vec2(0.0, 1.0);
			vec2 right = vec2(fwd.y, -fwd.x);
			float w = hh * 0.5 * (1.0 + edge_scale_k * ek);   // у опушки крона шире
			v = vec3(xz.x + right.x * VERTEX.x * w, h - sink * hh + VERTEX.y * hh,
					xz.y + right.y * VERTEX.x * w);
			NORMAL = normalize(vec3(fwd.x, 1.2, fwd.y));
			vec2 cell_uv = vec2(float(sp % 4), float(sp / 4));
			v_uv = (cell_uv + vec2(UV.x, UV.y)) / atlas_cells;
			v_tint = brightness * (0.85 + 0.3 * (band_mode ? INSTANCE_CUSTOM.w : hash12(cell + 13.3)));
			v_sl_kind = SL_DECID[sp]; // SL
			v_sl_gain = sl_tree_gain(sp_gain[sp]); // SL-14
			if (v_sl_kind > 0.5) v_sl_ss = sl_season_sp(v_sl_kind, h); // SL
			if (sl_light_enabled) {
				// средний цвет ячейки: мип, где ячейка — один тексель (прозрачное в атласе чёрное:
				// среднее rgb / среднее альфы = среднее по кроне)
				float lod = log2(float(textureSize(atlas, 0).x) / atlas_cells.x);
				vec4 mc = textureLod(atlas, (cell_uv + 0.5) / atlas_cells, lod);
				v_sl_luma = dot(mc.rgb, SL_LW) / max(mc.a, 1e-3) * v_tint * v_sl_gain;
				v_sl_con = SL_CONIFER[sp];
				// полог вдали: видимая доля освещённых крон по солнцу и взгляду (как у полога
				// рельефа); на билборд постоянна — в вершине
				v_sl_dir = sl_canopy_direct(n, normalize(CAMERA_POSITION_WORLD - v), sl_canopy_far(d));
			}
		}
	}
	VERTEX = v;
	v_cs_sun = cloud_sun_at(v);
}

void fragment() {
	if (v_lod_t < 1.5 && sl_lod_noise(FRAGCOORD.xy) >= v_lod_t) {
		discard;   // SL-К4: дизеринг смены формы — дополнение к модели (она видна при шум ≥ t)
	}
	vec4 c = texture(atlas, v_uv);
	vec3 rgb = c.rgb * v_tint * v_sl_gain; // SL-14: альбедо → (смягчение) → сезон
	// вдали крона бледнее и мягче контрастом (реальная дымка тут ещё не действует — расстояние
	// в сотни метров, но собственная контрастность запечённого атласа читается как «резкие точки»)
	float t = smoothstep(far_soft_start_m, far_soft_full_m, v_dist);
	float luma = dot(rgb, vec3(0.299, 0.587, 0.114));
	if (sl_light_enabled) {
		rgb = sl_tree_tone(rgb, v_sl_luma, v_sl_con, v_dist, t, far_contrast);
	} else {
		rgb = mix(rgb, vec3(luma), far_desaturate * t);
		rgb = mix(rgb, vec3(mix(luma, far_canopy_luma, 0.6)), far_contrast * t);
	}
	if (v_sl_kind > 0.5) rgb = sl_tree_season(rgb, v_sl_ss, v_sl_kind); // SL
	ALBEDO = rgb;
	// мягкий край силуэта вдали: шире антиалиасинг по производной альфы, скиссор почти отпущен
	float edge = fwidth(c.a) * mix(0.75, far_edge_soft_k, t);
	ALPHA = smoothstep(0.5 - edge, 0.5 + edge, c.a);
	if (v_sl_kind > 0.5 && sl_leaf_gone(v_sl_ss.w, fract(52.9829189 * fract(dot(FRAGCOORD.xy, vec2(0.06711056, 0.00583715)))))) discard; // SL
	ALPHA_SCISSOR_THRESHOLD = mix(0.5, 0.02, t);
	AO = cloud_sky_ao(v_cs_sun);
	v_sl_ny = (INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).y;
	v_sl_ao = AO;
	v_sl_sun = v_cs_sun;
}

// Встроенное освещение, прямое солнце — в тени облаков слабее (cloud_shadow.gdshaderinc).
void light() {
	cloud_light(NORMAL, VIEW, LIGHT, LIGHT_COLOR, ATTENUATION, LIGHT_IS_DIRECTIONAL,
			v_cs_sun * v_sl_dir, ALBEDO, ROUGHNESS, METALLIC, 0.0, vec3(0.0), CS_LAMBERT_WRAP,
			SPECULAR_AMOUNT, DIFFUSE_LIGHT, SPECULAR_LIGHT);
	sl_ground_light(DIFFUSE_LIGHT, LIGHT_COLOR, LIGHT_IS_DIRECTIONAL, ALBEDO, v_sl_ny, v_sl_ao, v_sl_sun);
}
