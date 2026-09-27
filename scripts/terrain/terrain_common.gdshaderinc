// Общая часть шейдеров рельефа и деревьев: uniform'ы сетки высот и вида, шум, классификация
// поверхности (лес/поля). Параметры задаёт terrain_renderer.gd из configs/world.json → terrain_look.

// --- сетка высот слоя ---
uniform sampler2D height_tex : filter_nearest, repeat_disable;
uniform vec2 layer_origin;      // мировые X/Z узла (0,0), м
uniform float layer_spacing;    // шаг сетки, м
uniform vec2 layer_texels;      // размер сетки в узлах
// --- вид ---
uniform vec3 grass_color : source_color;
uniform vec3 dry_grass_color : source_color;
uniform vec3 forest_color : source_color;
uniform vec3 birch_color : source_color;
uniform vec3 rock_color : source_color;
uniform vec3 snow_color : source_color;
uniform vec3 field_color : source_color;
uniform float forest_min_m;
uniform float treeline_m;
uniform float forest_cover;
uniform float forest_north_bias;
uniform float forest_max_slope_deg;
uniform float rock_slope_deg;
uniform float rock_blend_deg;
uniform float snowline_m;
uniform float snow_max_slope_deg;
uniform float field_max_slope_deg;
uniform float field_max_height_m;
uniform vec2 field_size_m;       // размер участка поля (восток × юг), м
uniform float patch_scale_m;
uniform float detail_scale_m;
uniform float detail_strength;
uniform float detail_fade_m;
uniform float canopy_bump;

float h_node(ivec2 p) {
	ivec2 m = ivec2(layer_texels) - ivec2(1);
	return texelFetch(height_tex, clamp(p, ivec2(0), m), 0).r;
}

// Маска рек (0..1) на той же сетке, что и высоты; нет маски — has_water = false.
uniform sampler2D water_tex : filter_linear, repeat_disable;
uniform bool has_water = false;

float water_at(vec2 xz) {
	if (!has_water) {
		return 0.0;
	}
	vec2 uv = ((xz - layer_origin) / layer_spacing + 0.5) / layer_texels;
	return texture(water_tex, uv).r;
}

// Поляны без леса вокруг стартовых площадок: xy — центр X/Z, z — радиус, м.
uniform vec4 clearings[8];
uniform int clearing_count = 0;

// Высота в произвольной точке (билинейно, как Terrain.height_at).
float h_bilinear(vec2 xz) {
	vec2 f = (xz - layer_origin) / layer_spacing;
	vec2 i = floor(f);
	vec2 t = f - i;
	ivec2 ij = ivec2(i);
	return mix(mix(h_node(ij), h_node(ij + ivec2(1, 0)), t.x),
			mix(h_node(ij + ivec2(0, 1)), h_node(ij + ivec2(1, 1)), t.x), t.y);
}

// --- шум ---
float hash12(vec2 p) {
	p = mod(p, 4096.0);
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = p - i;
	vec2 u = f * f * (3.0 - 2.0 * f);
	float a = hash12(i);
	float b = hash12(i + vec2(1.0, 0.0));
	float c = hash12(i + vec2(0.0, 1.0));
	float d = hash12(i + vec2(1.0, 1.0));
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

float fbm(vec2 p, int octaves) {
	float sum = 0.0;
	float amp = 0.5;
	float norm = 0.0;
	for (int k = 0; k < octaves; k++) {
		sum += amp * vnoise(p);
		norm += amp;
		p = mat2(vec2(1.6, 1.2), vec2(-1.2, 1.6)) * p + vec2(17.3, 9.1);
		amp *= 0.5;
	}
	return sum / norm;
}

// Классификация поверхности по высоте h, сглаженной нормали n и шуму.
// Возвращает: x — лес (0..1), y — доля хвойных, z — поле (0..1), w — «северность» склона (−1..1);
// patch2 — шум пятен второго масштаба (нужен раскраске).
vec4 biome(vec2 xz, float h, vec3 n, out float patch2) {
	float slope_deg = degrees(acos(clamp(n.y, 0.0, 1.0)));
	float patch = fbm(xz / patch_scale_m, 5);
	patch2 = fbm(xz / (patch_scale_m * 0.37) + vec2(31.7, 11.2), 4);
	// экспозиция: + на северных склонах (нормаль к −Z)
	float horiz = length(n.xz);
	float north = horiz > 1e-4 ? (-n.z / horiz) * smoothstep(3.0, 15.0, slope_deg) : 0.0;
	float field_mask = (1.0 - smoothstep(field_max_slope_deg * 0.6, field_max_slope_deg, slope_deg))
			* (1.0 - smoothstep(field_max_height_m - 60.0, field_max_height_m, h)) * step(0.35, patch);
	float forest_prob = forest_cover + forest_north_bias * north;
	float alt_w = smoothstep(forest_min_m - 80.0, forest_min_m + 80.0, h)
			* (1.0 - smoothstep(treeline_m - 150.0, treeline_m + 50.0, h + 200.0 * (patch - 0.5)));
	float slope_w = 1.0 - smoothstep(forest_max_slope_deg - 6.0, forest_max_slope_deg + 4.0, slope_deg);
	float forest = smoothstep(1.0 - forest_prob - 0.04, 1.0 - forest_prob + 0.04, patch) * alt_w * slope_w;
	forest *= 1.0 - field_mask;
	// у воды — ни леса, ни пашни (пойма)
	float wet = smoothstep(0.05, 0.4, water_at(xz));
	forest *= 1.0 - wet;
	field_mask *= 1.0 - wet;
	for (int k = 0; k < clearing_count; k++) {
		vec4 c = clearings[k];
		forest *= smoothstep(c.z, c.z * 1.6, length(xz - c.xy) + 15.0 * (patch2 - 0.5));
	}
	float conifer = smoothstep(0.35, 0.65, patch2 + 0.3 * north);
	return vec4(forest, conifer, field_mask, north);
}
