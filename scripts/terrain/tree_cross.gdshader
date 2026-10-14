// LOD2-кресты деревьев в вершинном шейдере (SL-18, SL-К4 v2, SL-К5): кольцо клеток 8 м вокруг камеры
// (смещение клетки — INSTANCE_CUSTOM.xy, как у травы grass.gdshader), дерево в клетке — общий хеш
// tree_cell.gdshaderinc (тот же, что у ближних CPU-моделей TreeCell): есть ли, где, порода, вариант,
// высота, поворот. Нет дерева — вырожденный крест (без выборок высот). Стык: ближе r_near·k — модель
// (tree_model.gdshader, дополняющая маска), дальше r_far·k — импостеры; k = sl_lod_k(дерево).
// Вид — как у креста LOD2 модели (tree_model.gdshader): текстура варианта (массив), альбедо породы
// (SL-14, второе число trees.albedo_gain), сезон (SL-6), просвет (SL-7), смягчение вдали; без теней.
// Параметры задаёт TreeCrosses (tree_crosses.gd).
shader_type spatial;
render_mode cull_disabled, diffuse_burley, world_vertex_coords;

#include "res://scripts/terrain/terrain_common.gdshaderinc"
#include "res://scripts/terrain/scene_look.gdshaderinc" // SL
#include "res://scripts/terrain/cloud_shadow.gdshaderinc"
#include "res://scripts/terrain/tree_cell.gdshaderinc"

const int MAX_LAYERS = 64;   // порода × вариант (TreeCrosses.MAX_LAYERS)

uniform sampler2DArray cross_tex : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform ivec2 grid_center_cell;      // клетка камеры
uniform float cell_m = 8.0;          // trees.cell_m (SL-К5)
uniform int variants = 8;
// (ширина креста, высота креста, высота модели LOD0) по слою sp * variants + вариант, м
uniform vec3 layer_dims[MAX_LAYERS];
uniform float r_near = 180.0;        // конец LOD1 моделей (trees.lod_distances_m[1]); 0 — моделей нет, кресты до камеры
uniform float r_far = 1100.0;        // радиус крестов (trees.cross_radius_m, по пресету)
uniform float lod_dither_m = 40.0;   // trees.lod_dither_m
uniform int dens8 = 204;             // round(trees.density · 255)
uniform int water8 = 89;             // round(trees.water_max · 255)
uniform float sink_fraction = 0.4;
uniform float edge_sink_fraction = 0.05;
uniform float edge_probe_m = 30.0;
uniform float color_variation = 0.15;
uniform float alpha_threshold = 0.5;
uniform float band_blend_m = 200.0;
// породы: pine, cedar, larch, birch, spruce (TreePlacer.SPECIES)
uniform float sp_weight[5];
uniform float sp_min[5];
uniform float sp_max[5];
uniform float sp_aspect[5];
uniform vec2 sp_height[5];
uniform float sp_gain[5];            // SL-14: второе число trees.albedo_gain (крест)
uniform float sp_backlight[5];       // SL-7: trees.backlight
// просеки (WorldClearings): 1 — расчищено
uniform sampler2D clear_tex : filter_nearest, repeat_disable;
uniform bool has_clearings = false;
uniform vec2 clear_origin;
uniform float clear_cell_m = 10.0;
uniform vec2 clear_size = vec2(1.0);
// смягчение вдали — как у моделей (tree_model.gdshader)
uniform float far_soft_start_m = 300.0;
uniform float far_soft_full_m = 1200.0;
uniform float far_desaturate = 0.4;
uniform float far_contrast = 0.35;
uniform float far_canopy_luma = 0.32;
uniform float far_edge_soft_k = 3.0;

const float SL_KIND[5] = float[5](0.0, 0.0, 2.0, 1.0, 0.0); // SL-6: TerrainTreeModels.season_kind

varying vec3 v_color;
varying float v_dist;
varying float v_cs_sun;
varying vec2 v_win;      // окно шума [x, y), где крест виден (стык с моделью и импостером)
varying flat int v_layer;
varying float v_gain;
varying float v_backlight;
varying float v_kind;
varying vec4 v_sl_ss;

bool tc_forest_px(vec2 xz) {
	if (use_forest_mask) {
		return forest_mask_r(xz) >= 0.5 && forest_mask_g(xz) < float(water8) / 255.0;
	}
	return surface_node(ivec2(round((xz - surface_origin) / surface_spacing))) == 1;
}

// d8 в точке (центр клетки; в позиции дерева — проверка леса): тексель маски, содержащий точку (без фильтрации), без маски — класс узла 25 м.
int cell_d8(vec2 xz) {
	if (use_forest_mask) {
		ivec2 t = ivec2(floor((xz - forest_mask_origin) / forest_mask_spacing + 0.5));
		ivec2 n = ivec2(forest_mask_texels);
		if (any(lessThan(t, ivec2(0))) || any(greaterThanEqual(t, n))) {
			return 0;
		}
		vec4 m = texelFetch(forest_mask_tex, t, 0);
		return tc_d8(int(round(m.r * 255.0)), int(round(m.g * 255.0)), water8, dens8);
	}
	return surface_node(ivec2(round((xz - surface_origin) / surface_spacing))) == 1 ? dens8 : 0;
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
	ivec2 c = grid_center_cell + ivec2(INSTANCE_CUSTOM.xy);
	uvec2 h = tc_hash(c);
	vec2 p = tc_pos(c, h, cell_m);
	float d = length(p - CAMERA_POSITION_WORLD.xz);
	v_win = tc_cross_window(d, sl_lod_k(p), r_near, r_far, lod_dither_m);
	v_dist = d;
	v_color = vec3(1.0);
	v_cs_sun = 1.0;
	v_layer = 0;
	v_gain = 1.0;
	v_backlight = 0.0;
	v_kind = 0.0;
	v_sl_ss = vec4(0.0);
	// дешёвое сначала: окно пусто или нет дерева — вырожденный крест (под землю, без выборок высот)
	bool present = v_win.x < v_win.y && tc_present(h, cell_d8((vec2(c) + 0.5) * cell_m));
	vec2 lo = layer_origin;
	vec2 hi = layer_origin + (layer_texels - 1.0) * layer_spacing;
	present = present && all(greaterThanEqual(p, lo)) && all(lessThanEqual(p, hi));
	// лес и в позиции дерева (тексель маски в p, те же пороги) — у кромки и воды не вылезает (как TreeCell)
	present = present && cell_d8(p) > 0;
	if (present && has_clearings) {
		ivec2 ct = ivec2(floor((p - clear_origin) / clear_cell_m));
		if (all(greaterThanEqual(ct, ivec2(0))) && all(lessThan(ct, ivec2(clear_size)))) {
			present = texelFetch(clear_tex, ct, 0).r < 0.5;
		}
	}
	int sp = -1;
	float hgt = 0.0;
	if (present) {
		// порода — по высоте и «северности» (вперёд разностями, как TreePlacer)
		hgt = h_bilinear(p);
		float e = layer_spacing;
		float gx = (h_bilinear(p + vec2(e, 0.0)) - hgt) / e;
		float gz = (h_bilinear(p + vec2(0.0, e)) - hgt) / e;
		float grad = sqrt(gx * gx + gz * gz);
		float north = grad > 1e-4 ? clamp(gz / grad, -1.0, 1.0) * clamp(grad / 0.25, 0.0, 1.0) : 0.0;
		sp = pick_species(hgt, north, tc_species_u(h));
	}
	if (sp < 0) {
		VERTEX = vec3(p.x, -1e5, p.y);
		v_win = vec2(1.0, 0.0);
	} else {
		uvec2 h2 = tc_hash2(h);
		int layer = sp * variants + tc_variant(h, variants);
		vec3 dims = layer_dims[min(layer, MAX_LAYERS - 1)];
		float hh = mix(sp_height[sp].x, sp_height[sp].y, tc_height_t(h2));
		float s = hh / max(dims.z, 0.1);
		// утопление: у кромки леса меньше (доля не-леса на кольце edge_probe_m, как у импостеров)
		float open = 0.0;
		for (int k = 0; k < 4; k++) {
			float a = 1.5708 * float(k) + 0.785;
			open += float(!tc_forest_px(p + vec2(cos(a), sin(a)) * edge_probe_m));
		}
		float sink = mix(edge_sink_fraction, sink_fraction, 1.0 - open * 0.25);
		float y = hgt - sink * hh;
		float an = tc_angle(h);
		float ca = cos(an);
		float sa = sin(an);
		// крест единичного размера (TreeCrosses.cross_mesh) → размер варианта × масштаб, поворот как у
		// моделей (строки базиса: x' = c·x + s·z, z' = −s·x + c·z)
		vec3 l = VERTEX * vec3(dims.x, dims.y, dims.x) * s;
		VERTEX = vec3(p.x + ca * l.x + sa * l.z, y + l.y, p.y - sa * l.x + ca * l.z);
		NORMAL = vec3(ca * NORMAL.x + sa * NORMAL.z, NORMAL.y, -sa * NORMAL.x + ca * NORMAL.z);
		v_layer = layer;
		v_color = vec3(1.0 + color_variation * (tc_color_t(h2) - 0.5) * 2.0);
		v_gain = sl_tree_gain(sp_gain[sp]);
		v_backlight = sp_backlight[sp];
		v_kind = SL_KIND[sp];
		v_sl_ss = v_kind > 0.5 ? sl_season_sp(v_kind, y) : vec4(0.0); // SL
		v_cs_sun = cloud_sun_at(vec3(p.x, y, p.y));
	}
}

void fragment() {
	// стык форм: один шум экрана с моделями (tree_model.gdshader) — дополняющие маски
	float n = sl_lod_noise(FRAGCOORD.xy);
	if (n < v_win.x || n >= v_win.y) {
		discard;
	}
	vec4 c = texture(cross_tex, vec3(UV, float(v_layer)));
	vec3 rgb = c.rgb * v_color * v_gain; // SL-14: альбедо → сезон → просвет
	if (v_kind > 0.5) {  // SL
		rgb = sl_tree_season(rgb, v_sl_ss, v_kind);
		if (sl_leaf_gone(v_sl_ss.w, n)) discard;
	}
	float ft = smoothstep(far_soft_start_m, far_soft_full_m, v_dist);
	float luma = dot(rgb, vec3(0.299, 0.587, 0.114));
	if (sl_light_enabled) {
		// SL-24: как у импостеров — вдали к своей средней (= альбедо полога породы, множитель gain его
		// выставил), а не к общим 0,32 (ALBEDO линейный: 0,32 вдвое-втрое светлее хвои 0,05 → «седые» кресты)
		float con = v_kind < 0.5 ? 1.0 : 0.0;
		rgb = sl_tree_tone(rgb, mix(sl_canopy_albedo.y, sl_canopy_albedo.x, con), con, v_dist, ft, far_contrast);
	} else {
		rgb = mix(rgb, vec3(luma), far_desaturate * ft);
		rgb = mix(rgb, vec3(mix(luma, far_canopy_luma, 0.6)), far_contrast * ft);
	}
	ALBEDO = rgb;
	// нормали креста — как у карточек кроны: изнанка светится так же
	NORMAL = FRONT_FACING ? NORMAL : -NORMAL;
	float edge = fwidth(c.a) * mix(0.75, far_edge_soft_k, ft);
	ALPHA = smoothstep(alpha_threshold - edge, alpha_threshold + edge, c.a);
	ALPHA_SCISSOR_THRESHOLD = mix(alpha_threshold, alpha_threshold * 0.05, ft);
	ROUGHNESS = 0.9;
	SPECULAR = 0.0;
	BACKLIGHT = vec3(v_backlight) * ALBEDO;
	AO = cloud_sky_ao(v_cs_sun);
}

void light() {
	cloud_light(NORMAL, VIEW, LIGHT, LIGHT_COLOR, ATTENUATION, LIGHT_IS_DIRECTIONAL, v_cs_sun,
			ALBEDO, ROUGHNESS, METALLIC, 0.0, BACKLIGHT, CS_BURLEY, SPECULAR_AMOUNT,
			DIFFUSE_LIGHT, SPECULAR_LIGHT);
}
