// Средний план леса (≈ 0,4–2 км): деревья-билборды из атласа импостеров (assets/models/trees/
// trees_impostor_atlas.png). Сетка экземпляров едет за камерой, дерево привязано к мировой клетке;
// есть ли дерево — класс «лес» карты поверхности и маска просек, порода — по высотному поясу и
// экспозиции (те же веса, что у моделей, configs/world.json → trees.species). Параметры задаёт
// ForestImpostors (forest_impostors.gd). Дальше — полог в шейдере рельефа, ближе — 3D-модели.
shader_type spatial;
render_mode cull_disabled, diffuse_lambert_wrap, world_vertex_coords, specular_disabled;

#include "res://scripts/terrain/terrain_common.gdshaderinc"
#include "res://scripts/terrain/terrain_wind.gdshaderinc"

uniform sampler2D atlas : source_color, filter_linear_mipmap, repeat_disable;
uniform vec2 atlas_cells = vec2(4.0, 2.0);        // ячеек атласа (столбцы, строки)
uniform vec2 grid_center_cell;
uniform int grid_n;
uniform float spacing_m = 10.0;
uniform float inner_m = 350.0;                    // ближе — 3D-модели (плавный переход до inner_end_m)
uniform float inner_end_m = 500.0;
uniform float outer_m = 2000.0;                   // дальше — только полог рельефа
uniform float density = 0.85;
uniform float sink_fraction = 0.4;
uniform float edge_sink_fraction = 0.05;
uniform float edge_probe_m = 30.0;
uniform float brightness = 1.15;                  // импостер уже «освещён» при запекании
// породы: pine, cedar, larch, birch, spruce
uniform float sp_weight[5];
uniform float sp_min[5];
uniform float sp_max[5];
uniform float sp_aspect[5];
uniform vec2 sp_height[5];
uniform float band_blend_m = 200.0;
// просеки (WorldClearings): 1 — расчищено
uniform sampler2D clear_tex : filter_nearest, repeat_disable;
uniform bool has_clearings = false;
uniform vec2 clear_origin;
uniform float clear_cell_m = 10.0;
uniform vec2 clear_size = vec2(1.0);

varying vec2 v_uv;
varying float v_tint;

bool is_forest(vec2 xz) {
	return surface_node(ivec2(round((xz - surface_origin) / surface_spacing))) == 1;
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
	// переход с 3D-моделями: доля импостеров растёт от inner_m к inner_end_m
	float ring = smoothstep(inner_m, inner_end_m, d) * (1.0 - step(outer_m, d));
	bool present = hash12(cell + 5.7) < density * ring && is_forest(xz);
	if (present && has_clearings) {
		vec2 cu = (xz - clear_origin) / (clear_cell_m * clear_size);
		if (all(greaterThanEqual(cu, vec2(0.0))) && all(lessThan(cu, vec2(1.0)))) {
			present = texture(clear_tex, cu).r < 0.5;
		}
	}
	float h = h_bilinear(xz);
	float e = layer_spacing;
	vec3 n = normalize(vec3(h_bilinear(xz - vec2(e, 0.0)) - h_bilinear(xz + vec2(e, 0.0)), 2.0 * e,
			h_bilinear(xz - vec2(0.0, e)) - h_bilinear(xz + vec2(0.0, e))));
	float horiz = length(n.xz);
	float north = horiz > 1e-4 ? clamp(-n.z / horiz, -1.0, 1.0) * clamp(horiz / n.y / 0.25, 0.0, 1.0) : 0.0;
	int sp = pick_species(h, north, hash12(cell + 4.1));
	if (sp < 0) {
		present = false;
		sp = 0;
	}
	float hh = mix(sp_height[sp].x, sp_height[sp].y, hash12(cell + 2.2));
	// вдали дерево чуть крупнее — чтобы не рябило и сливалось с пологом
	hh *= 1.0 + 0.4 * smoothstep(outer_m * 0.5, outer_m, d);
	float nf = 0.0;
	for (int k = 0; k < 4; k++) {
		float a = 1.5708 * float(k) + 0.785;
		nf += float(is_forest(xz + vec2(cos(a), sin(a)) * edge_probe_m));
	}
	float sink = mix(edge_sink_fraction, sink_fraction, nf / 4.0);
	if (!present) {
		hh = 0.0;
	}
	// цилиндрический билборд: поворот к камере вокруг вертикали
	vec2 to_cam = CAMERA_POSITION_WORLD.xz - xz;
	vec2 fwd = length(to_cam) > 0.01 ? normalize(to_cam) : vec2(0.0, 1.0);
	vec2 right = vec2(fwd.y, -fwd.x);
	float w = hh * 0.5;
	VERTEX = vec3(xz.x + right.x * VERTEX.x * w, h - sink * hh + VERTEX.y * hh,
			xz.y + right.y * VERTEX.x * w);
	NORMAL = normalize(vec3(fwd.x, 1.2, fwd.y));
	vec2 cell_uv = vec2(float(sp % 4), float(sp / 4));
	v_uv = (cell_uv + vec2(UV.x, UV.y)) / atlas_cells;
	v_tint = brightness * (0.85 + 0.3 * hash12(cell + 13.3));
}

void fragment() {
	vec4 c = texture(atlas, v_uv);
	ALBEDO = c.rgb * v_tint;
	ALPHA = c.a;
	ALPHA_SCISSOR_THRESHOLD = 0.5;
}
