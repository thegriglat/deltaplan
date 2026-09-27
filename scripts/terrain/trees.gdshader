// Деревья рядом с камерой (GPU-инстансинг, MultiMesh). Сетка экземпляров едет вместе с
// камерой, каждое дерево привязано к мировой клетке → при движении деревья не «прыгают».
// Деревья стоят только на классе «лес» карты поверхности (та же surface_weights, что красит рельеф).
// Высоты — из той же текстуры, что у детального слоя рельефа.
shader_type spatial;
render_mode cull_back, diffuse_burley, world_vertex_coords;

#include "res://scripts/terrain/terrain_common.gdshaderinc"

uniform vec2 grid_center_cell;      // мировая клетка под камерой
uniform int grid_n;                 // экземпляров по стороне сетки
uniform float tree_spacing_m;       // шаг сетки деревьев, м
uniform float area_radius_m;        // радиус зоны деревьев вокруг камеры, м
uniform vec2 conifer_height_m;      // мин/макс высота хвойного, м
uniform vec2 birch_height_m;        // мин/макс высота лиственного, м
uniform float conifer_radius_ratio; // радиус кроны у основания / высота
uniform float birch_radius_ratio;   // радиус кроны / высота
uniform float sink_fraction;        // доля высоты, утопленная в поверхность (DSM уже включает кроны)
uniform float density;              // доля клеток леса с деревом
uniform float color_variation;      // разброс яркости крон

varying vec3 v_col;
varying float v_t;

void vertex() {
	int id = INSTANCE_ID;
	vec2 cell = grid_center_cell + vec2(float(id % grid_n), float(id / grid_n)) - float(grid_n / 2);
	vec2 jit = vec2(hash12(cell * 1.37 + 3.1), hash12(cell * 0.71 + 11.3)) - 0.5;
	vec2 xz = (cell + 0.5 + jit * 0.8) * tree_spacing_m;
	float h = h_bilinear(xz);
	float e = layer_spacing;
	vec3 n = normalize(vec3(h_bilinear(xz - vec2(e, 0.0)) - h_bilinear(xz + vec2(e, 0.0)), 2.0 * e,
			h_bilinear(xz - vec2(0.0, e)) - h_bilinear(xz + vec2(0.0, e))));
	vec4 wa;
	vec4 wb;
	surface_weights(xz, wa, wb);
	float patch2 = fbm(xz / (patch_scale_m * 0.12) + vec2(31.7, 11.2), 4);
	bool present = hash12(cell + 5.7) < smoothstep(0.5, 0.9, wa.x) * density;
	bool con = hash12(cell + 9.1) < conifer_share(patch2, northness(n));
	float k = hash12(cell + 2.2);
	float hh = con ? mix(conifer_height_m.x, conifer_height_m.y, k) : mix(birch_height_m.x, birch_height_m.y, k);
	float d = length(xz - CAMERA_POSITION_WORLD.xz);
	hh *= 1.0 - smoothstep(area_radius_m * 0.4, area_radius_m, d);
	if (!present) {
		hh = 0.0;
	}
	float t = VERTEX.y;              // 0 — низ кроны, 1 — макушка
	vec2 dir = VERTEX.xz;            // единичное направление по окружности
	float rad = con ? (1.0 - t) * conifer_radius_ratio : sin(PI * clamp(t * 0.9 + 0.1, 0.0, 1.0)) * birch_radius_ratio;
	VERTEX = vec3(xz.x + dir.x * rad * hh, h - sink_fraction * hh + t * hh, xz.y + dir.y * rad * hh);
	NORMAL = normalize(vec3(dir.x, con ? conifer_radius_ratio * 2.0 : (0.5 - t) * 1.5, dir.y));
	float v = 1.0 + color_variation * (hash12(cell + 13.3) - 0.5) * 2.0;
	v_col = (con ? forest_color : birch_color) * v;
	v_t = t;
}

void fragment() {
	ALBEDO = v_col * mix(0.55, 1.1, v_t);
	ROUGHNESS = 0.95;
	SPECULAR = 0.1;
}
