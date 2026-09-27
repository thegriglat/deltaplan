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
uniform vec3 shrub_color : source_color;
uniform vec3 bare_color : source_color;
uniform vec3 built_color : source_color;
uniform vec3 straw_color : source_color = vec3(0.6, 0.52, 0.3);
uniform float dryness = 0.3;         // сухость лугов по локации и сезону 0..1
uniform float dry_noise = 0.6;       // разброс сухости пятнами
uniform float dry_south_k = 0.3;     // насколько южные склоны суше
uniform float grass_saturation = 1.0;
uniform float rock_slope_deg;
uniform float rock_blend_deg;
uniform vec2 field_size_m;       // размер участка поля (восток × юг), м
uniform float patch_scale_m;
uniform float detail_scale_m;
uniform float detail_strength;
uniform float detail_fade_m;
uniform float canopy_bump;
// --- карта поверхности (VR-4): классы земного покрова, та же, что у Terrain.surface_at ---
// значение текстуры ×255 = класс: 1 лес, 2 луг, 3 пашня, 4 кустарник, 5 скалы/грунт, 6 вода,
// 7 застройка, 8 снег; 0 — нет данных (рисуется как луг)
uniform sampler2D surface_tex : filter_nearest, repeat_disable;
uniform vec2 surface_origin;     // мировые X/Z узла (0,0), м
uniform float surface_spacing = 25.0;
uniform vec2 surface_texels = vec2(1.0);
uniform float surface_edge_noise = 0.7;
uniform float surface_edge_sharpness = 0.35;
// --- маска «деталь 10 м» (T02): R — доля леса в клетке 10 м (WorldCover без моды), G — резерв ---
// Есть только у детального слоя встроенных локаций; нет — лес берётся из карты классов.
uniform bool use_forest_mask = false;
uniform sampler2D forest_mask_tex : filter_linear, repeat_disable;
uniform vec2 forest_mask_origin;       // мировые X/Z узла (0,0) маски, м
uniform float forest_mask_spacing = 10.0;
uniform vec2 forest_mask_texels = vec2(1.0);

// Доля леса по маске 10 м в точке (билинейно между узлами, как Terrain.forest_at).
float forest_mask_r(vec2 xz) {
	vec2 uv = ((xz - forest_mask_origin) / forest_mask_spacing + 0.5) / forest_mask_texels;
	return textureLod(forest_mask_tex, uv, 0.0).r;
}

// Доля воды (реки/ручьи/озёра OSM, T03) по каналу G той же маски 10 м, билинейно.
float forest_mask_g(vec2 xz) {
	vec2 uv = ((xz - forest_mask_origin) / forest_mask_spacing + 0.5) / forest_mask_texels;
	return textureLod(forest_mask_tex, uv, 0.0).g;
}

// Вода вдали (клетка маски мельче пикселя, foot_m — размер пикселя в мире, T03): максимум
// по кресту в окрестности пикселя вместо одной точки — узкие реки/ручьи не пропадают и не
// мерцают одним текселем при движении камеры (без этого — under-sampling тонкой полосы).
float forest_mask_g_aa(vec2 xz, float foot_m) {
	float w0 = forest_mask_g(xz);
	if (foot_m > forest_mask_spacing) {
		float d = min(foot_m, forest_mask_spacing * 6.0) * 0.5;
		float w1 = forest_mask_g(xz + vec2(d, 0.0));
		float w2 = forest_mask_g(xz - vec2(d, 0.0));
		float w3 = forest_mask_g(xz + vec2(0.0, d));
		float w4 = forest_mask_g(xz - vec2(0.0, d));
		w0 = max(w0, max(max(w1, w2), max(w3, w4)));
	}
	return w0;
}

float h_node(ivec2 p) {
	ivec2 m = ivec2(layer_texels) - ivec2(1);
	return texelFetch(height_tex, clamp(p, ivec2(0), m), 0).r;
}

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

// Классы карты поверхности в узле сетки карты.
int surface_node(ivec2 p) {
	ivec2 m = ivec2(surface_texels) - ivec2(1);
	return int(texelFetch(surface_tex, clamp(p, ivec2(0), m), 0).r * 255.0 + 0.5);
}

// Разложение класса по двум vec4: a = (лес, луг, пашня, кустарник), b = (скалы, вода, застройка, снег).
// «Нет данных» (0) идёт в луг.
void surface_onehot(int c, out vec4 a, out vec4 b) {
	a = vec4(float(c == 1), float(c == 2 || c == 0 || c > 8), float(c == 3), float(c == 4));
	b = vec4(float(c == 5), float(c == 6), float(c == 7), float(c == 8));
}

// Доли классов в точке: ближайший узел карты (как Terrain.surface_at). Доли четырёх соседних
// узлов интерполируются билинейно и обрезаются по уровню 0.5 (изолиния — плавная кривая, а не
// «лесенка» клеток); порог слегка сдвигается шумом — извилистые границы (surface_edge_noise).
// surface_edge_sharpness — полуширина размытия границы (доля клетки).
void surface_weights(vec2 xz, out vec4 wa, out vec4 wb) {
	float sc = surface_spacing * 1.5;
	vec2 warp = vec2(fbm(xz / sc, 3), fbm(xz / sc + vec2(7.3, 1.9), 3)) - 0.5;
	vec2 f = (xz + warp * surface_edge_noise * surface_spacing - surface_origin) / surface_spacing;
	vec2 i = floor(f);
	vec2 t = f - i;
	ivec2 ij = ivec2(i);
	vec4 a00, b00, a10, b10, a01, b01, a11, b11;
	surface_onehot(surface_node(ij), a00, b00);
	surface_onehot(surface_node(ij + ivec2(1, 0)), a10, b10);
	surface_onehot(surface_node(ij + ivec2(0, 1)), a01, b01);
	surface_onehot(surface_node(ij + ivec2(1, 1)), a11, b11);
	vec4 la = mix(mix(a00, a10, t.x), mix(a01, a11, t.x), t.y);
	vec4 lb = mix(mix(b00, b10, t.x), mix(b01, b11, t.x), t.y);
	float e = max(surface_edge_sharpness, 1e-3);
	vec4 sa = smoothstep(vec4(0.5 - e), vec4(0.5 + e), la);
	vec4 sb = smoothstep(vec4(0.5 - e), vec4(0.5 + e), lb);
	float sum = dot(sa, vec4(1.0)) + dot(sb, vec4(1.0));
	// там, где сходятся 3–4 класса и ни один не набрал половины, — мягкое смешивание
	float k = smoothstep(0.05, 0.3, sum);
	wa = mix(la, sa / max(sum, 1e-4), k);
	wb = mix(lb, sb / max(sum, 1e-4), k);
}

// «Северность» склона −1..1 (нормаль к −Z), на пологом — 0.
float northness(vec3 n) {
	float slope_deg = degrees(acos(clamp(n.y, 0.0, 1.0)));
	float horiz = length(n.xz);
	return horiz > 1e-4 ? (-n.z / horiz) * smoothstep(3.0, 15.0, slope_deg) : 0.0;
}

// Доля хвойных в лесу (0..1): пятнами, больше на северных склонах. patch2 — шум пятен.
float conifer_share(float patch2, float north) {
	return smoothstep(0.35, 0.65, patch2 + 0.3 * north);
}

// Цвет луга (та же палитра, что у рельефа и травинок): сухость по локации/сезону + пятна +
// южные склоны суше. north — «северность» склона, patch2 — шум пятен (fbm, см. рельеф).
// dry_add — добавка сухости (рельеф: ложбины влажнее, гребни и южные склоны суше; 0 — нет).
vec3 meadow_color_dry(vec2 xz, float north, float patch2, float dry_add) {
	float big = fbm(xz / patch_scale_m + vec2(4.7, 9.3), 3);
	float dry = clamp(dryness + dry_noise * ((patch2 - 0.5) + 0.8 * (big - 0.5))
			- dry_south_k * north + dry_add, 0.0, 1.0);
	vec3 c = dry < 0.5 ? mix(grass_color, dry_grass_color, dry * 2.0)
			: mix(dry_grass_color, straw_color, dry * 2.0 - 1.0);
	return mix(vec3(dot(c, vec3(0.2126, 0.7152, 0.0722))), c, grass_saturation);
}

vec3 meadow_color(vec2 xz, float north, float patch2) {
	return meadow_color_dry(xz, north, patch2, 0.0);
}

float meadow_patch(vec2 xz) {
	return fbm(xz / (patch_scale_m * 0.12) + vec2(31.7, 11.2), 4);
}

// Цвет участка поля (пашня, всходы, стерня) — прямоугольные участки field_size_m.
vec3 field_plot_color(vec2 xz, vec3 meadow) {
	vec2 cell = floor(xz / field_size_m + vec2(floor(xz.y / (field_size_m.y * 6.0)) * 0.37, 0.0));
	float fh = hash12(cell);
	vec3 c = mix(field_color, mix(meadow, dry_grass_color, fh), step(0.45, fh));
	return c * (0.85 + 0.3 * hash12(cell + 7.0));
}
