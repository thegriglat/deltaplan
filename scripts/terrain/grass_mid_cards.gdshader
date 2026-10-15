// Карточки-пучки средней дистанции травы, режим «angle» (G4 v4, GR-21; наработки GR-7): пучки
// (GrassMidCards) на сетке, привязанной к миру, как пучки grass.gdshader. Положение, класс, высота,
// сезон, скос, посадки, приминание, ветер — тот же расчёт (код повторён: grass.gdshader общий с
// ближним кольцом).
// Угол взгляда к рельефу (G4 v4): α = asin(|dot(направление взгляда, нормаль рельефа)|) в точке пучка.
// Сбоку на скользящем взгляде слои (GrassMidShell) вырождаются в полосы — там нужны вертикальные
// карточки; сверху карточки видны «крышками» с прозрачными просветами — там слои. Доля пучков
// card_share(α): 1 при α ≤ card_angle_full_deg, 0 при α ≥ card_angle_none_deg, между — линейно; пучок
// с рангом выше доли выбрасывается целиком в вершинном шейдере до выборок (как вне кадра). Слои в той
// же полосе гаснут по густоте на долю 1 − card_share (grass_mid_shell.gdshader) — растворение по
// миру, без шва и без мерцания.
// Цвет (как у слоёв, GR-8): пучок — та же трава, что рельеф рисует лугом, поэтому тон берётся из
// кадра рельефа в точке корня пучка (hint_screen_texture: палитра, сезон, сухость, пятна, тени
// деревьев и облаков, свет склона); карточка лишь модулирует его: тон травинок атласа, к корню темнее,
// разброс по пучкам; нормировка card_norm — в среднем по видимым пикселям множитель 1. Корня в кадре
// нет (за краем на небе, за гребнем дальше ожидаемого) — свой цвет луга с освещением.
// Альфа — порог alpha_cut с поправкой покрытия по мипам (mip_alpha_scale): пучок не тает вдали.
shader_type spatial;
// прозрачный проход (нужен кадр рельефа); пиксели непрозрачны (ALPHA 1 или discard) и пишут глубину
render_mode cull_disabled, diffuse_lambert_wrap, world_vertex_coords, specular_disabled, blend_mix, fog_disabled,
		depth_draw_always;

#include "res://scripts/terrain/terrain_common.gdshaderinc"
#include "res://scripts/terrain/terrain_wind.gdshaderinc"
#include "res://scripts/terrain/meadow_look.gdshaderinc"
#include "res://scripts/terrain/scene_look.gdshaderinc" // SL
#include "res://scripts/terrain/cloud_shadow.gdshaderinc"

uniform vec2 grid_center_cell;
uniform float clump_spacing_m = 0.45;
uniform float mid_inner_m = 8.4;
uniform float mid_inner_fade_m = 5.6;
uniform float mid_outer_m = 40.0;
uniform float mid_outer_fade_m = 8.0;
uniform bool angle_mode = true;
uniform float card_angle_full_deg = 15.0;
uniform float card_angle_none_deg = 30.0;
uniform float card_width_m = 0.55;
uniform float card_height_k = 1.1;     // высота карточки / высота травы (кончики в атласе не до верха)
uniform float far_density_min = 0.5;   // доля пучков у внешнего края
uniform float far_width_k = 1.4;       // ширина пучков у внешнего края (компенсация)
// RGB — тон травинки (серый, среднее ≈0,9), A — покрытие; кадры — слои массива (свои мипмапы)
uniform sampler2DArray atlas_tex : filter_linear_mipmap, repeat_disable;
uniform float atlas_cell_px = 128.0;
uniform float alpha_cut = 0.5;
uniform float mip_alpha_scale[8];      // поправка покрытия по мипам (GrassMidCards.coverage_scales)
uniform vec2 card_shade = vec2(0.8, 1.1);   // яркость у корня / у кончика относительно луга
uniform float card_tone = 0.1;         // разброс яркости по пучкам, доля
uniform float card_norm = 1.0;         // 1 / средняя модуляция видимых пикселей карточки
// общие с grass.gdshader (копируются из материала ближнего кольца)
uniform vec2 blade_height_m = vec2(0.25, 0.55);
uniform vec2 crop_height_m = vec2(0.6, 0.9);
uniform float shrub_density = 0.5;
uniform float forest_density = 0.0;
uniform vec2 forest_height_m = vec2(0.12, 0.3);
uniform float forest_shade = 1.0;
uniform float color_variation = 0.15;
uniform vec3 blade_tint = vec3(1.08, 1.0, 0.85);
uniform vec2 blade_shade = vec2(1.25, 1.75);
uniform float sway_hz = 0.8;
uniform float sway_hz_var = 0.0;
uniform float sway_amp = 0.12;
uniform float bend_amp = 0.7;
uniform vec4 mowed[4];
uniform int mowed_count = 0;
uniform vec4 landing_pos[4];
uniform vec4 landing_dir[4];
uniform float landing_hk[4];
uniform int landing_count = 0;
uniform vec3 press_pos = vec3(1e9);
uniform float press_radius_m = 1.5;
uniform float press_agl_full_m = 0.4;
uniform float press_agl_zero_m = 1.2;
uniform sampler2D trample_tex : filter_linear, repeat_disable, hint_default_black;
uniform vec4 trample_rect = vec4(0.0, 0.0, 1.0, 1.0);
uniform float trample_on = 0.0;
uniform float trample_height_k = 0.12;
uniform float trample_lean = 1.3;
uniform vec3 trample_tint = vec3(1.12, 1.0, 0.72);
uniform float height_k = 1.0;
uniform float clump_reach_m = 0.3;
uniform bool cull_enabled = true;
uniform sampler2D screen_tex : hint_screen_texture, filter_linear;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;

varying vec3 v_col;
varying float v_t;
varying vec3 v_n;
varying float v_cs_sun;
varying vec3 v_uv;       // u, v кадра, номер слоя массива
varying vec4 v_root;     // клип-координаты корня пучка (цвет луга под пучком из кадра рельефа)
varying float v_mod;     // разброс яркости пучка

// Высота и уклон в точке — копия h_grad из grass.gdshader (GR-6): уклон билинейной клетки (та же
// нормаль, что у слоёв: угол взгляда у слоёв и карточек считается одинаково).
float h_grad(vec2 xz, out vec2 g) {
	vec2 f = (xz - layer_origin) / layer_spacing;
	vec2 i = floor(f);
	vec2 t = f - i;
	ivec2 ij = ivec2(i);
	float h00 = h_node(ij);
	float h10 = h_node(ij + ivec2(1, 0));
	float h01 = h_node(ij + ivec2(0, 1));
	float h11 = h_node(ij + ivec2(1, 1));
	g = vec2(mix(h10 - h00, h11 - h01, t.y), mix(h01 - h00, h11 - h10, t.x)) / layer_spacing;
	return mix(mix(h00, h10, t.x), mix(h01, h11, t.x), t.y);
}

// Доля карточек по углу взгляда к рельефу (GrassMidCards.card_share): p — точка земли, n — нормаль.
float card_share_at(vec3 p, vec3 n, vec3 cam) {
	float s = abs(dot(normalize(p - cam), n));
	float a = degrees(asin(clamp(s, 0.0, 1.0)));
	return clamp((card_angle_none_deg - a) / max(card_angle_none_deg - card_angle_full_deg, 0.1), 0.0, 1.0);
}

// как clump_out_of_view в grass.gdshader (GR-3): столбик пучка целиком за плоскостью пирамиды
bool clump_out_of_view(vec2 xz, float h, float d, float width_scale, mat4 proj, mat4 view) {
	if (d < 2.0) {
		return false;
	}
	float h_max = max(max(blade_height_m.y, crop_height_m.y), forest_height_m.y) * height_k * card_height_k;
	float bend_max = 1.0 + max(gust_gain, 0.0);
	for (int k = 0; k < wind_thermal_count; k++) {
		bend_max = max(bend_max, 1.08 * abs(wind_thermals[k].w) * thermal_gain);
	}
	float lean_max = bend_max * abs(bend_amp) + 0.15 + abs(sway_amp);
	lean_max = max(lean_max, max(1.5, abs(trample_lean)));
	float reach = clump_reach_m * width_scale + lean_max * h_max;
	vec3 a = (view * vec4(xz.x, h - 0.02, xz.y, 1.0)).xyz;
	vec3 b = (view * vec4(xz.x, h + h_max, xz.y, 1.0)).xyz;
	if (min(a.z, b.z) > reach) {
		return true;
	}
	mat4 t = transpose(proj);
	vec4 pl[4] = vec4[4](t[3] + t[0], t[3] - t[0], t[3] + t[1], t[3] - t[1]);
	for (int i = 0; i < 4; i++) {
		float inv = inversesqrt(max(dot(pl[i].xyz, pl[i].xyz), 1e-20));
		if (max(dot(pl[i].xyz, a) + pl[i].w, dot(pl[i].xyz, b) + pl[i].w) * inv < -reach) {
			return true;
		}
	}
	return false;
}

void vertex() {
	vec2 cell = grid_center_cell + INSTANCE_CUSTOM.xy;
	vec2 jit = vec2(hash12(cell * 1.37 + 3.1), hash12(cell * 0.71 + 11.3)) - 0.5;
	vec2 xz = (cell + 0.5 + jit * 0.9) * clump_spacing_m;
	float d = length(xz - CAMERA_POSITION_WORLD.xz);
	// реже к внешнему краю (ширина компенсирует), растворение краёв кольца по рангу
	float thin_s = smoothstep(mid_inner_m, mid_outer_m, d);
	float density = mix(1.0, far_density_min, thin_s);
	density *= smoothstep(mid_inner_m, mid_inner_m + mid_inner_fade_m, d);
	density *= 1.0 - smoothstep(mid_outer_m - mid_outer_fade_m, mid_outer_m, d);
	float rank = hash12(cell + vec2(20.5, 0.0));
	float width_scale = mix(1.0, far_width_k, thin_s);
	float h = 0.0;
	vec2 hg = vec2(0.0);
	vec3 n = vec3(0.0, 1.0, 0.0);
	bool hidden = rank >= density;
	if (!hidden) {
		h = h_grad(xz, hg);
		n = normalize(vec3(-hg.x, 1.0, -hg.y));
		// угол взгляда: сверху (α ≥ none) пучка нет — весь пучок до выборок цвета
		if (angle_mode) {
			hidden = rank >= density * card_share_at(vec3(xz.x, h, xz.y), n, CAMERA_POSITION_WORLD);
		}
	}
	if (!hidden) {
		hidden = cull_enabled && clump_out_of_view(xz, h, d, width_scale, PROJECTION_MATRIX, VIEW_MATRIX);
	}
	if (hidden) {
		VERTEX = vec3(xz.x, -1e4, xz.y);
		v_col = vec3(0.0);
		v_t = 0.0;
		v_n = vec3(0.0, 1.0, 0.0);
		v_cs_sun = 1.0;
		v_uv = vec3(0.0);
		v_root = vec4(0.0, 0.0, 0.0, 1.0);
		v_mod = 1.0;
	} else {
		float sl_rel; vec4 sl_ss = sl_season_b(h, sl_rel); // SL
		int c = surface_node(ivec2(round((xz - surface_origin) / surface_spacing)));
		float r = hash12(cell + 2.2);
		float hh = 0.0;
		if (c == 2 || c == 0) {
			hh = mix(blade_height_m.x, blade_height_m.y, r);
		} else if (c == 3) {
			hh = mix(crop_height_m.x, crop_height_m.y, r) * sl_field_height(xz, sl_rel); // SL
		} else if (c == 4 && hash12(cell + 8.8) < shrub_density) {
			hh = mix(blade_height_m.x, blade_height_m.y, r);
		} else if (c == 1 && hash12(cell + 8.8) < forest_density) {
			hh = mix(forest_height_m.x, forest_height_m.y, r);
		}
		float slope_deg = degrees(acos(clamp(n.y, 0.0, 1.0)));
		hh *= 1.0 - smoothstep(rock_slope_deg - 4.0, rock_slope_deg + 2.0, slope_deg);
		for (int k = 0; k < mowed_count; k++) {
			if (length(xz - mowed[k].xy) < mowed[k].z) {
				hh *= mowed[k].w;
			}
		}
		for (int k = 0; k < landing_count; k++) {
			vec2 dv = xz - landing_pos[k].xy;
			if (abs(dot(dv, landing_dir[k].xy)) <= landing_pos[k].z
					&& abs(dot(dv, landing_dir[k].zw)) <= landing_pos[k].w) {
				hh *= landing_hk[k];
			}
		}
		float tr = 0.0;
		if (trample_on > 0.5) {
			vec2 tuv = (xz - trample_rect.xy) * trample_rect.zw;
			if (tuv.x >= 0.0 && tuv.y >= 0.0 && tuv.x < 1.0 && tuv.y < 1.0) {
				tr = textureLod(trample_tex, tuv, 0.0).r;
			}
		}
		hh *= mix(1.0, trample_height_k, tr);
		// у краёв ниже — растворение вместе с рангом
		float edge = smoothstep(mid_inner_m, mid_inner_m + mid_inner_fade_m, d)
				* (1.0 - smoothstep(mid_outer_m - mid_outer_fade_m, mid_outer_m, d));
		hh *= height_k * card_height_k * mix(0.5, 1.0, edge);

		float t = VERTEX.y;
		float wshade;
		vec2 bend;
		grass_wind(xz, d, TIME, wshade, bend);
		float spd = length(wind_vec);
		float amp = smoothstep(0.3, wind_full_ms, spd);
		vec2 dir = spd > 0.05 ? wind_vec / spd : vec2(1.0, 0.0);
		float ph = hash12(cell + 4.4) * 6.2832;
		float fk = 1.0 + sway_hz_var * (2.0 * hash12(cell + 4.9) - 1.0);
		vec2 lean = bend * bend_amp + dir * amp * (0.15 + sway_amp * sin(TIME * sway_hz * fk * 6.2832 + ph));
		vec2 pv = xz - press_pos.xz;
		float pd = length(pv);
		float near_ground = 1.0 - smoothstep(press_agl_full_m, press_agl_zero_m, press_pos.y - h);
		float press = near_ground * (1.0 - smoothstep(press_radius_m * 0.4, press_radius_m, pd));
		lean = mix(lean, (pd > 0.01 ? pv / pd : vec2(0.0)) * 1.5, press);
		float ta = hash12(cell + 9.3) * 6.2832;
		lean = mix(lean, vec2(cos(ta), sin(ta)) * trample_lean, tr * 0.85);
		float l2 = min(dot(lean, lean), 2.0);
		float a = hash12(cell + 6.6) * 6.2832;
		vec2 o = mat2(vec2(cos(a), sin(a)), vec2(-sin(a), cos(a))) * VERTEX.xz * card_width_m * width_scale;
		float y = t * hh * inversesqrt(1.0 + l2 * t * t);
		vec2 off = lean * hh * t * t;
		VERTEX = vec3(xz.x + o.x + off.x, h + y - 0.02, xz.y + o.y + off.y);
		if (hh < 0.02) {
			VERTEX = vec3(xz.x, -1e4, xz.y);
		}
		v_n = normalize(n + vec3(lean.x, 0.0, lean.y) * 0.3);
		// кадр по пучку; зеркально — по чётности ещё одного хеша (вдвое больше вариантов)
		float u = hash12(cell + 7.7) < 0.5 ? UV.x : 1.0 - UV.x;
		v_uv = vec3(u, UV.y, floor(hash12(cell + 5.5) * 3.999));
		v_root = PROJECTION_MATRIX * (VIEW_MATRIX * vec4(xz.x, h, xz.y, 1.0));
		v_mod = 1.0 + card_tone * (hash12(cell + 13.3) - 0.5) * 2.0;

		vec4 rel = relief_at(xz);
		float wet = rel.r * 2.0 - 1.0;
		vec3 base = meadow_ground_color(xz, northness(n), meadow_patch(xz), wet, rel.b * 2.0 - 1.0);
		base = meadow_macro(xz, base, 0.05, wet, d, 0.0);
		base = sl_meadow_season(base, sl_ss); // SL
		if (c == 3) {
			base = sl_field_season(field_plot_color(xz, base), xz, sl_rel); // SL
		} else if (c == 1) {
			base *= forest_shade;
		}
		base *= 1.0 + color_variation * (hash12(cell + 13.3) - 0.5) * 2.0;
		base *= blade_tint * (1.0 + wind_shade * wshade);
		base *= mix(vec3(1.0), trample_tint, tr);
		v_col = base;
		v_t = t;
		v_cs_sun = cloud_sun_at(VERTEX);
	}
}

// Тон ближних травинок в среднем (GR-6, grass.gdshader): кончики суше — к соломе той же яркости на
// верхней трети, средняя по травинкам доля 0,7·tip_dry (свой цвет, когда корня в кадре нет).
uniform float across_shade = 0.12;
uniform float tip_dry = 0.25;
vec3 grass_mid_near_tone(vec3 c, float t) {
	const vec3 LT = vec3(0.2126, 0.7152, 0.0722);
	vec3 straw = straw_color * (dot(c, LT) / max(dot(straw_color, LT), 1e-3));
	c = mix(c, straw, 0.7 * tip_dry * smoothstep(0.55, 1.0, t));
	return c;
}

void fragment() {
	vec4 tex = texture(atlas_tex, v_uv);
	// мипмапы усредняют альфу тонких травинок — покрытие тает вдали; поправка по уровню мипа
	vec2 px = v_uv.xy * atlas_cell_px;
	float lod = clamp(0.5 * log2(max(max(dot(dFdx(px), dFdx(px)), dot(dFdy(px), dFdy(px))), 1e-8)), 0.0, 7.0);
	int l0 = int(floor(lod));
	int l1 = min(l0 + 1, 7);
	float s = mix(mip_alpha_scale[l0], mip_alpha_scale[l1], lod - float(l0));
	if (tex.a * s <= alpha_cut) {
		discard;
	}
	ALPHA = 1.0;
	float m = card_norm * (tex.r / 0.9) * mix(card_shade.x, card_shade.y, v_t) * v_mod;
	// корень пучка в кадре рельефа: глубина кадра там — земля у корня (или ближе: закрыто травинками,
	// камнем — цвет всё равно луговой); заметно дальше — корень за краем кадра на небе, свой цвет
	vec2 ruv = v_root.xy / max(v_root.w, 1e-4) * 0.5 + 0.5;
	vec2 cuv = clamp(ruv, vec2(0.002), vec2(0.998));
	float zb = texture(depth_tex, cuv).r;
	vec4 vb = INV_PROJECTION_MATRIX * vec4(cuv * 2.0 - 1.0, zb, 1.0);
	float d_scr = -vb.z / vb.w;
	float d_root = v_root.w;
	float own = smoothstep(1.0 + 0.1 * d_root, 3.0 + 0.3 * d_root, d_scr - d_root);
	vec3 ground = textureLod(screen_tex, cuv, 0.0).rgb;
	EMISSION = ground * m * (1.0 - own);
	ALBEDO = grass_mid_near_tone(v_col * (tex.rgb / 0.9) * mix(blade_shade.x, blade_shade.y, v_t), v_t) * own;
	NORMAL = normalize((VIEW_MATRIX * vec4(v_n, 0.0)).xyz);
	ROUGHNESS = 0.9;
	BACKLIGHT = vec3(0.85) * v_col * own;
	AO = cloud_sky_ao(v_cs_sun);
}

void light() {
	cloud_light(NORMAL, VIEW, LIGHT, LIGHT_COLOR, ATTENUATION, LIGHT_IS_DIRECTIONAL, v_cs_sun,
			ALBEDO, ROUGHNESS, METALLIC, 0.0, BACKLIGHT, CS_LAMBERT_WRAP, SPECULAR_AMOUNT,
			DIFFUSE_LIGHT, SPECULAR_LIGHT);
}
