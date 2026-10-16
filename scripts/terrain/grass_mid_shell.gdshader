// Средняя дистанция травы, режим «shell» (G4, GR-7, GR-8): горизонтальные слои сетки-кольца над рельефом
// (GrassMidShell). Слой — доля высоты травы UV.x; во фрагменте шумовая маска (R — высота стебля,
// G — ранг, B — тон) решает, есть ли в этой точке стебель не ниже слоя. Класс поверхности, высота
// класса, скос, посадки, приминание и ветер — как в grass.gdshader (код повторён).
// Цвет (GR-8): слой — это та же трава, что рельеф рисует лугом, только с объёмом. Поэтому тон
// берётся из готового кадра рельефа прямо за слоем (hint_screen_texture: палитра, сезон, сухость,
// пятна, фактура луга, тени деревьев и облаков, освещение склона — всё, что видно у луга в этой
// точке), а слой лишь модулирует его: ворс у корня темнее (тень соседних стеблей), разброс тона
// по куртинам и пятнам 1–5 м. Там, где за слоем не земля рядом (гребень на фоне неба, далёкий
// склон), — свой цвет луга с освещением (meadow_ground_color, как у травинок).
// Края кольца растворяются: густота, высота и модуляция гаснут на [mid_inner_m; +mid_inner_fade_m]
// и [mid_outer_m − mid_outer_fade_m; mid_outer_m], радиус края рваный (шум 1–5 м) — на краю слой
// тождественно равен лугу рельефа, кольца нет ни сбоку, ни сверху.
shader_type spatial;
// прозрачный проход: нужен кадр рельефа за слоем; стебли непрозрачны (ALPHA 1 или discard) и пишут
// глубину — нижние слои, закрытые верхними, отбрасываются тестом глубины (индексы — сверху вниз)
render_mode cull_disabled, diffuse_lambert_wrap, world_vertex_coords, specular_disabled, blend_mix, fog_disabled,
		depth_draw_always;

#include "res://scripts/terrain/terrain_common.gdshaderinc"
#include "res://scripts/terrain/ground_cover.gdshaderinc"   // скалы, выходы породы, осыпь — как у рельефа (GR-25)
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
// анизотропная фильтрация (GR-14): луг на 10–30 м виден под скользящим углом 3–8°, плитка маски
// сжата по глубине в 10–20 раз сильнее, чем поперёк; изотропный мипмап берёт уровень по сжатию вдоль
// взгляда и усредняет куртины (15 см) и поперёк — ворс становится ровным «ковром». Анизотропный
// оставляет куртины и просветы поперёк взгляда.
uniform sampler2D mask_tex : filter_linear_mipmap_anisotropic, repeat_enable;
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
uniform sampler2D screen_tex : hint_screen_texture, filter_linear;  // без мипмапов: выборка 1:1
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;
// ворс (GR-8): яркость у корня / у кончика относительно луга рельефа (тень соседних стеблей; среднее
// по видимым сверху и сбоку стеблям ≈ 1 — диск не темнее и не светлее луга)
uniform vec2 pile_shade = vec2(0.82, 1.1);
uniform float pile_tone = 0.12;        // разброс тона куртин (канал B маски), доля
uniform float patch_m = 3.0;           // пятна густоты/высоты/тона ворса, м (1–5 м)
uniform float patch_density = 0.35;    // разброс густоты пятнами, доля
uniform float patch_height = 0.3;      // разброс высоты пятнами, доля
uniform float patch_tone = 0.06;       // разброс тона пятнами, доля
uniform float edge_jitter_m = 4.0;     // рваность края кольца, м (± половина)
// режим angle (G4 v4, GR-21): угол взгляда к рельефу α = asin(|dot(взгляд, нормаль)|); при α ≤ full —
// только карточки (GrassMidCards), слоёв нет; при α ≥ none — только слои; между густота слоёв — доля
// 1 − card_share(α) (карточки — card_share(α), grass_mid_cards.gdshader). Выключен — слои как в shell.
uniform bool angle_mode = false;
uniform float card_angle_full_deg = 15.0;
uniform float card_angle_none_deg = 30.0;
// вершина с α ниже full на этот запас — вне слоёв целиком (треугольник с ней уже в зоне карточек:
// уклон α по сетке ≤ ~2,5° на диагональ клетки 1,4 м у ближнего края кольца)
const float ANGLE_HIDE_MARGIN_DEG = 4.0;

varying vec3 v_col;
varying vec3 v_n;
varying float v_cs_sun;
varying vec2 v_xz;
varying float v_hh;      // высота травы класса (верх диапазона), м; 0 — травы нет
varying float v_lo;      // низ диапазона высоты / верх
varying float v_share;   // доля стеблей (класс × густота × растворение края)
varying vec2 v_lean;
varying float v_fade;    // растворение края 0..1 (1 — внутри кольца)
varying vec4 v_patch;    // пятна ворса 1–5 м (каналы шума macro_noise_tex)

// Высота и уклон в точке — копия h_grad из grass.gdshader (GR-6): уклон билинейной клетки (поверхность,
// которую рисует рельеф), те же четыре узла, что у h_bilinear.
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
	vec2 hg;
	float h = h_grad(xz, hg);
	float d = length(xz - CAMERA_POSITION_WORLD.xz);
	// пятна ворса в мировых координатах (не плывут); тот же шум, что у пятен луга (macro_noise_tex)
	vec4 pn = textureLod(macro_noise_tex, xz / (patch_m * MACRO_NOISE_FEATURE) + vec2(0.31, 0.17), 0.0);
	// рваный край: радиус растворения сдвинут шумом (окружности не видно)
	float dj = d + (pn.w - 0.5) * edge_jitter_m;
	float fade = smoothstep(mid_inner_m, mid_inner_m + mid_inner_fade_m, d)
			* (1.0 - smoothstep(mid_outer_m - mid_outer_fade_m, mid_outer_m, dj));
	float h_max = max(max(blade_height_m.y, crop_height_m.y), forest_height_m.y) * height_k;
	float bend_max = 1.0 + max(gust_gain, 0.0);
	for (int k = 0; k < wind_thermal_count; k++) {
		bend_max = max(bend_max, 1.08 * abs(wind_thermals[k].w) * thermal_gain);
	}
	float lean_max = max(bend_max * abs(bend_amp) + 0.15 + abs(sway_amp), max(1.5, abs(trample_lean)));
	bool hidden = fade <= 0.0;
	float shell_k = 1.0;   // доля слоёв по углу взгляда (режим angle)
	if (!hidden && angle_mode) {
		vec3 nv = normalize(vec3(-hg.x, 1.0, -hg.y));
		float sa = abs(dot(normalize(vec3(xz.x, h, xz.y) - CAMERA_POSITION_WORLD), nv));
		float a_deg = degrees(asin(clamp(sa, 0.0, 1.0)));
		shell_k = clamp((a_deg - card_angle_full_deg) / max(card_angle_none_deg - card_angle_full_deg, 0.1), 0.0, 1.0);
		hidden = a_deg < card_angle_full_deg - ANGLE_HIDE_MARGIN_DEG;
	}
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
		v_fade = 0.0;
		v_patch = vec4(0.5);
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
		// уклон — уклон билинейной клетки, как у ближних травинок (h_grad, grass.gdshader)
		vec3 n = normalize(vec3(-hg.x, 1.0, -hg.y));
		// порода рельефа (ground_cover, G2 v2): густота — доля луга
		if (hh > 0.0 && share > 0.0) {
			share *= gc_grass_keep_fast(xz, n, c);
		}
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
		hh *= height_k * mix(0.4, 1.0, fade) * (1.0 + patch_height * 2.0 * (pn.y - 0.5));

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
		v_share = share * coverage * fade * shell_k * clamp(1.0 + patch_density * 2.0 * (pn.x - 0.5), 0.0, 1.0);
		v_fade = fade;
		v_patch = pn;
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

// Тон ближних травинок в среднем (GR-6, grass.gdshader): перепад «край листа темнее середины»
// нормирован (GR-14) — в среднем по ширине множителя нет; кончики суше — к соломе той же яркости на
// верхней трети, средняя по травинкам доля 0,7·tip_dry. Совпадение тона на стыке ближнего и среднего колец (8–14 м).
uniform float across_shade = 0.12;
uniform float tip_dry = 0.25;
vec3 grass_mid_near_tone(vec3 c, float t) {
	const vec3 LT = vec3(0.2126, 0.7152, 0.0722);
	vec3 straw = straw_color * (dot(c, LT) / max(dot(straw_color, LT), 1e-3));
	c = mix(c, straw, 0.7 * tip_dry * smoothstep(0.55, 1.0, t));
	return c;
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
	if (stem - frac < 0.0) {
		discard;
	}
	ALPHA = 1.0;
	// модуляция ворса относительно луга: у корня темнее, тон куртин и пятен; на краю кольца → 1
	float mod_l = mix(pile_shade.x, pile_shade.y, frac)
			* (1.0 + pile_tone * (m.b - 0.5) * 2.0)
			* (1.0 + patch_tone * (v_patch.z - 0.5) * 2.0);
	float mod_k = mix(1.0, mod_l, v_fade);
	// за слоем — земля рядом? Глубина кадра за фрагментом против ожидаемой: луч от слоя высотой y до
	// земли проходит y / sin(угла к горизонту); заметно дальше — за слоем небо или дальний склон
	float zb = texture(depth_tex, SCREEN_UV).r;
	vec4 vb = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, zb, 1.0);
	float gap = -vb.z / vb.w + VERTEX.z;
	float sin_el = abs(normalize((INV_VIEW_MATRIX * vec4(VERTEX, 0.0)).xyz).y);
	float expect = v_hh * frac / max(sin_el, 0.02);
	float own = smoothstep(2.0 * expect + 1.0, 3.0 * expect + 3.0, gap);
	vec3 behind = textureLod(screen_tex, SCREEN_UV, 0.0).rgb;
	EMISSION = behind * mod_k * (1.0 - own);
	vec3 col = v_col * mix(blade_shade.x, blade_shade.y, frac);
	col *= 1.0 + color_variation * (m.b - 0.5) * 2.0;
	ALBEDO = grass_mid_near_tone(col, frac) * own;
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
