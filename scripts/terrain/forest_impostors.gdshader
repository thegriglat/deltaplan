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
#include "res://scripts/terrain/terrain_wind.gdshaderinc"
#include "res://scripts/terrain/cloud_shadow.gdshaderinc"

uniform sampler2D atlas : source_color, filter_linear_mipmap, repeat_disable;
uniform vec2 atlas_cells = vec2(4.0, 2.0);        // ячеек атласа (столбцы, строки)
uniform vec2 grid_center_cell;
uniform int grid_n;
uniform float spacing_m = 10.0;
uniform float inner_m = 350.0;                    // ближе — 3D-модели (плавный переход до inner_end_m)
uniform float inner_end_m = 500.0;
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
// тень облаков: множитель прямого солнца (cloud_shadow.gdshaderinc) — в light()
varying float v_cs_sun;

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
	float d = length(xz - CAMERA_POSITION_WORLD.xz);
	// переход с 3D-моделями: доля импостеров растёт от inner_m к inner_end_m;
	// у outer_m билборды растворяются по одному (порог — хеш клетки), без полосы.
	// Сначала дешёвые проверки; нет дерева — вырожденный квад и выход (без выборок высот).
	float ring = smoothstep(inner_m, inner_end_m, d);
	float fade_out = smoothstep(outer_m - dissolve_m, outer_m, d);
	float u = hash12(cell + 5.7);
	bool present = d < outer_m && u < max(density, edge_density) * ring
			&& hash12(cell + 7.9) >= fade_out && is_forest(xz);
	if (present && has_clearings) {
		vec2 cu = (xz - clear_origin) / (clear_cell_m * clear_size);
		if (all(greaterThanEqual(cu, vec2(0.0))) && all(lessThan(cu, vec2(1.0)))) {
			present = texture(clear_tex, cu).r < 0.5;
		}
	}
	// опушка: ближе к кромке — гуще и шире (стена деревьев)
	float ek = 0.0;
	if (present) {
		ek = min(1.0, 2.0 * max(open_frac(xz, edge_band_m * 0.5, 0.0), 0.5 * open_frac(xz, edge_band_m, 0.785)));
		present = u < mix(density, edge_density, ek) * ring;
	}
	// нет дерева — вырожденный квад (все вершины в одной точке)
	vec3 v = vec3(0.0);
	v_uv = vec2(0.0);
	v_tint = 0.0;
	v_dist = d;
	if (present) {
		float h = h_bilinear(xz);
		float e = layer_spacing;
		vec3 n = normalize(vec3(h_bilinear(xz - vec2(e, 0.0)) - h_bilinear(xz + vec2(e, 0.0)), 2.0 * e,
				h_bilinear(xz - vec2(0.0, e)) - h_bilinear(xz + vec2(0.0, e))));
		float horiz = length(n.xz);
		float north = horiz > 1e-4 ? clamp(-n.z / horiz, -1.0, 1.0) * clamp(horiz / n.y / 0.25, 0.0, 1.0) : 0.0;
		int sp = pick_species(h, north, hash12(cell + 4.1));
		if (sp >= 0) {
			float hh = mix(sp_height[sp].x, sp_height[sp].y, hash12(cell + 2.2));
			// вдали дерево чуть крупнее — чтобы не рябило и сливалось с пологом
			hh *= 1.0 + 0.4 * smoothstep(outer_m * 0.5, outer_m, d);
			// утопление: в глубине леса sink_fraction (кроны в DSM), у кромки меньше — стволы видны
			float sink = mix(edge_sink_fraction, sink_fraction, 1.0 - open_frac(xz, edge_probe_m, 0.785));
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
			v_tint = brightness * (0.85 + 0.3 * hash12(cell + 13.3));
		}
	}
	VERTEX = v;
	v_cs_sun = cloud_sun_at(v);
}

void fragment() {
	vec4 c = texture(atlas, v_uv);
	vec3 rgb = c.rgb * v_tint;
	// вдали крона бледнее и мягче контрастом (реальная дымка тут ещё не действует — расстояние
	// в сотни метров, но собственная контрастность запечённого атласа читается как «резкие точки»)
	float t = smoothstep(far_soft_start_m, far_soft_full_m, v_dist);
	float luma = dot(rgb, vec3(0.299, 0.587, 0.114));
	rgb = mix(rgb, vec3(luma), far_desaturate * t);
	rgb = mix(rgb, vec3(mix(luma, far_canopy_luma, 0.6)), far_contrast * t);
	ALBEDO = rgb;
	// мягкий край силуэта вдали: шире антиалиасинг по производной альфы, скиссор почти отпущен
	float edge = fwidth(c.a) * mix(0.75, far_edge_soft_k, t);
	ALPHA = smoothstep(0.5 - edge, 0.5 + edge, c.a);
	ALPHA_SCISSOR_THRESHOLD = mix(0.5, 0.02, t);
	AO = cloud_sky_ao(v_cs_sun);
}

// Встроенное освещение, прямое солнце — в тени облаков слабее (cloud_shadow.gdshaderinc).
void light() {
	cloud_light(NORMAL, VIEW, LIGHT, LIGHT_COLOR, ATTENUATION, LIGHT_IS_DIRECTIONAL, v_cs_sun,
			ALBEDO, ROUGHNESS, METALLIC, 0.0, vec3(0.0), CS_LAMBERT_WRAP, SPECULAR_AMOUNT,
			DIFFUSE_LIGHT, SPECULAR_LIGHT);
}
