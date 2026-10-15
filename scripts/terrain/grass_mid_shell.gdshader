// Средняя дистанция травы, режим «shell» (G4, GR-7): горизонтальные слои сетки-кольца над рельефом
// (GrassMidShell). Слой — доля высоты травы UV.x; во фрагменте шумовая маска (R — высота стебля,
// G — ранг, B — тон) решает, есть ли в этой точке стебель не ниже слоя. Класс поверхности, высота
// класса, сезон, скос, посадки, приминание, цвет луга и ветер — как в grass.gdshader (код повторён:
// grass.gdshader общий с ближним кольцом и в этой задаче не меняется). Ветер сдвигает верхние слои
// (∝ доле²) — ворс клонится. Края кольца растворяются: густота и высота гаснут на
// [mid_inner_m; +mid_inner_fade_m] и [mid_outer_m − mid_outer_fade_m; mid_outer_m].
shader_type spatial;
render_mode cull_disabled, diffuse_lambert_wrap, world_vertex_coords, specular_disabled;

#include "res://scripts/terrain/terrain_common.gdshaderinc"
#include "res://scripts/terrain/terrain_wind.gdshaderinc"
#include "res://scripts/terrain/meadow_look.gdshaderinc"
#include "res://scripts/terrain/scene_look.gdshaderinc" // SL
#include "res://scripts/terrain/cloud_shadow.gdshaderinc"

uniform vec2 grid_origin;              // мировые X/Z начала сетки (клетка камеры × шаг), м
uniform float mesh_step_m = 1.0;
uniform float mid_inner_m = 8.4;
uniform float mid_inner_fade_m = 5.6;
uniform float mid_outer_m = 40.0;
uniform float mid_outer_fade_m = 8.0;
uniform sampler2D mask_tex : filter_linear_mipmap, repeat_enable;
uniform float mask_tile_m = 4.0;       // плитка маски, м
uniform float coverage = 1.0;          // густота (density_pct/100, не больше 1)
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
uniform bool cull_enabled = true;

varying vec3 v_col;
varying vec3 v_n;
varying float v_cs_sun;
varying vec2 v_xz;
varying float v_hh;      // высота травы класса (верх диапазона), м; 0 — травы нет
varying float v_lo;      // низ диапазона высоты / верх
varying float v_share;   // доля стеблей (класс × густота × растворение края)
varying vec2 v_lean;

// Вершина вне пирамиды камеры: столбик от земли до h_max радиусом reach целиком за плоскостью
// или позади камеры (как clump_out_of_view в grass.gdshader). reach включает 1,5 шага сетки:
// треугольник, у которого хоть одна вершина отсечена, целиком вне кадра.
bool vert_out_of_view(vec2 xz, float h, float h_max, float reach, mat4 proj, mat4 view) {
	vec3 a = (view * vec4(xz.x, h - 0.05, xz.y, 1.0)).xyz;
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
	float frac = UV.x;
	vec2 xz = grid_origin + VERTEX.xz;
	float h = h_bilinear(xz);
	float d = length(xz - CAMERA_POSITION_WORLD.xz);
	float fade = smoothstep(mid_inner_m, mid_inner_m + mid_inner_fade_m, d)
			* (1.0 - smoothstep(mid_outer_m - mid_outer_fade_m, mid_outer_m, d));
	float h_max = max(max(blade_height_m.y, crop_height_m.y), forest_height_m.y) * height_k;
	float bend_max = 1.0 + max(gust_gain, 0.0);
	for (int k = 0; k < wind_thermal_count; k++) {
		bend_max = max(bend_max, 1.08 * abs(wind_thermals[k].w) * thermal_gain);
	}
	float lean_max = max(bend_max * abs(bend_amp) + 0.15 + abs(sway_amp), max(1.5, abs(trample_lean)));
	bool hidden = fade <= 0.0;
	if (!hidden && cull_enabled) {
		hidden = vert_out_of_view(xz, h, h_max, 1.5 * mesh_step_m + lean_max * h_max, PROJECTION_MATRIX,
				VIEW_MATRIX);
	}
	v_xz = xz;
	if (hidden) {
		// положение — внутри столбика (треугольники с этой вершиной вне кадра), без выборок цвета
		VERTEX = vec3(xz.x, h - 0.05, xz.y);
		v_hh = 0.0;
		v_lo = 1.0;
		v_share = 0.0;
		v_lean = vec2(0.0);
		v_col = vec3(0.0);
		v_n = vec3(0.0, 1.0, 0.0);
		v_cs_sun = 1.0;
	} else {
		float sl_rel; vec4 sl_ss = sl_season_b(h, sl_rel); // SL
		int c = surface_node(ivec2(round((xz - surface_origin) / surface_spacing)));
		vec2 hr = vec2(0.0);
		float share = 1.0;
		if (c == 2 || c == 0) {
			hr = blade_height_m;
		} else if (c == 3) {
			hr = crop_height_m * sl_field_height(xz, sl_rel); // SL
		} else if (c == 4) {
			hr = blade_height_m;
			share = shrub_density;
		} else if (c == 1) {
			hr = forest_height_m;
			share = forest_density;
		} else {
			share = 0.0;
		}
		float hh = hr.y;
		float e = layer_spacing;
		vec3 n = normalize(vec3(h_bilinear(xz - vec2(e, 0.0)) - h_bilinear(xz + vec2(e, 0.0)), 2.0 * e,
				h_bilinear(xz - vec2(0.0, e)) - h_bilinear(xz + vec2(0.0, e))));
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
		// приминание у ног пилота (пилот может стоять в кольце при виде со стороны)
		vec2 pv = xz - press_pos.xz;
		float pd = length(pv);
		float near_ground = 1.0 - smoothstep(press_agl_full_m, press_agl_zero_m, press_pos.y - h);
		float press = near_ground * (1.0 - smoothstep(press_radius_m * 0.4, press_radius_m, pd));
		hh *= mix(1.0, 0.35, press);
		// растворение краёв: высота гаснет вместе с густотой
		hh *= height_k * mix(0.4, 1.0, fade);

		// ветер: тот же наклон, что у травинок; фаза качания — плавный шум по месту (без «полотна»)
		float wshade;
		vec2 bend;
		grass_wind(xz, d, TIME, wshade, bend);
		float spd = length(wind_vec);
		float amp = smoothstep(0.3, wind_full_ms, spd);
		vec2 dir = spd > 0.05 ? wind_vec / spd : vec2(1.0, 0.0);
		float ph = vnoise(xz * 0.35) * 12.566;
		vec2 lean = bend * bend_amp + dir * amp * (0.15 + sway_amp * sin(TIME * sway_hz * 6.2832 + ph));
		lean = mix(lean, (pd > 0.01 ? pv / pd : vec2(0.0)) * 1.5, press);
		float ta = vnoise(xz * 0.7 + 9.3) * 12.566;
		lean = mix(lean, vec2(cos(ta), sin(ta)) * trample_lean, tr * 0.85);
		float l2 = min(dot(lean, lean), 2.0);
		float y = frac * hh * inversesqrt(1.0 + l2 * frac * frac);
		VERTEX = vec3(xz.x, h + y - 0.02, xz.y);
		v_hh = hh;
		v_lo = hr.y > 0.0 ? hr.x / hr.y : 1.0;
		v_share = share * coverage * fade;
		v_lean = lean;
		v_n = normalize(n + vec3(lean.x, 0.0, lean.y) * 0.3);

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
		base *= blade_tint * (1.0 + wind_shade * wshade);
		base *= mix(vec3(1.0), trample_tint, tr);
		v_col = base;
		v_cs_sun = cloud_sun_at(VERTEX);
	}
}

// Тон ближних травинок в среднем (GR-6, grass.gdshader): край листа темнее середины — среднее по
// ширине 1 − across_shade/3; кончики суше — к соломе той же яркости на верхней трети, средняя по
// травинкам доля 0,7·tip_dry. Совпадение тона на стыке ближнего и среднего колец (8–14 м).
uniform float across_shade = 0.12;
uniform float tip_dry = 0.25;
vec3 grass_mid_near_tone(vec3 c, float t) {
	const vec3 LT = vec3(0.2126, 0.7152, 0.0722);
	vec3 straw = straw_color * (dot(c, LT) / max(dot(straw_color, LT), 1e-3));
	c = mix(c, straw, 0.7 * tip_dry * smoothstep(0.55, 1.0, t));
	return c * (1.0 - across_shade / 3.0);
}

void fragment() {
	float frac = UV.x;
	if (v_hh < 0.02 || v_share <= 0.0) {
		discard;
	}
	// ворс клонится: верхний слой берёт маску из точки, сдвинутой против наклона
	vec2 p = v_xz - v_lean * v_hh * frac * frac;
	vec4 m = texture(mask_tex, p / mask_tile_m);
	// стебель есть, если ранг < доли; издали (мипмапы) ранг усреднён — редкая трава ниже, без мерцания
	float keep = clamp((v_share - m.g) * 6.0 + 0.5, 0.0, 1.0);
	// высота стебля в долях верха класса: R 0..1 → [низ; верх] диапазона; R = 0 — просвет
	float stem = m.r > 0.0 ? mix(v_lo, 1.0, m.r) * smoothstep(0.0, 0.1, m.r) : 0.0;
	stem *= keep;
	float edge = stem - frac;
	ALPHA = clamp(edge / max(fwidth(edge), 1e-4) + 0.5, 0.0, 1.0);
	ALPHA_SCISSOR_THRESHOLD = 0.5;
	ALPHA_ANTIALIASING_EDGE = 0.3;
	vec3 col = v_col * mix(blade_shade.x, blade_shade.y, frac);
	col *= 1.0 + color_variation * (m.b - 0.5) * 2.0;
	ALBEDO = grass_mid_near_tone(col, frac);
	NORMAL = normalize((VIEW_MATRIX * vec4(v_n, 0.0)).xyz);
	ROUGHNESS = 0.9;
	BACKLIGHT = vec3(0.85) * v_col;
	AO = cloud_sky_ao(v_cs_sun);
}

void light() {
	cloud_light(NORMAL, VIEW, LIGHT, LIGHT_COLOR, ATTENUATION, LIGHT_IS_DIRECTIONAL, v_cs_sun,
			ALBEDO, ROUGHNESS, METALLIC, 0.0, BACKLIGHT, CS_LAMBERT_WRAP, SPECULAR_AMOUNT,
			DIFFUSE_LIGHT, SPECULAR_LIGHT);
}
