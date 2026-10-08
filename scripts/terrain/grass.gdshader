// Травинки вокруг камеры (VR-17, VR-6): пучки на сетке, привязанной к миру (при движении не
// «прыгают»), MultiMesh без трансформов — положение, высоту и цвет каждого пучка считает шейдер.
// Где трава — решает карта поверхности (луг, пашня — выше, кустарник — реже, лес — реже, ниже и
// темнее, тень полога; скалы, вода, застройка — нет); цвет — цвет земли луга в этой точке (meadow_look.gdshaderinc: палитра,
// влажность, экспозиция, пятна с высоты — как рисует terrain.gdshader). Качание — тем же полем
// ветра, что колышет рельеф (порывы, термики), приминание у ног пилота. Параметры задаёт
// GrassField из configs/vegetation.json → grass.
shader_type spatial;
render_mode cull_disabled, diffuse_lambert_wrap, world_vertex_coords, specular_disabled;

#include "res://scripts/terrain/terrain_common.gdshaderinc"
#include "res://scripts/terrain/terrain_wind.gdshaderinc"
#include "res://scripts/terrain/meadow_look.gdshaderinc"
#include "res://scripts/terrain/cloud_shadow.gdshaderinc"

uniform vec2 grid_center_cell;
uniform float clump_spacing_m = 0.5;
uniform float area_radius_m = 35.0;
uniform vec2 blade_height_m = vec2(0.25, 0.55);   // луг, мин/макс
uniform vec2 crop_height_m = vec2(0.6, 0.9);      // посевы (нива)
uniform float shrub_density = 0.5;
// трава под пологом леса (К2 v2): доля пучков, высота мин/макс, множитель цвета (тень полога)
uniform float forest_density = 0.0;
uniform vec2 forest_height_m = vec2(0.12, 0.3);
uniform float forest_shade = 1.0;
uniform float color_variation = 0.15;
uniform vec3 blade_tint = vec3(1.08, 1.0, 0.85);  // оттенок травинок поверх цвета луга
uniform float dry_clump_share = 0.0;              // доля сухих соломенных пучков (редкие)
uniform vec2 blade_shade = vec2(1.25, 1.75);      // яркость у корня / у кончика, × цвет земли
uniform float sway_hz = 0.8;                      // частота собственного качания, Гц
uniform float sway_hz_var = 0.0;                  // разброс частоты качания по пучкам (±доля)
uniform float sway_amp = 0.12;                    // собственное качание (доля высоты) при полном ветре
uniform float bend_amp = 0.7;                     // наклон по ветру/порыву (доля высоты)
// скошенные места (посадочные площадки, круг — пока не подключены прямоугольники): xy — центр,
// z — радиус, м; w — доля высоты
uniform vec4 mowed[4];
uniform int mowed_count = 0;
// посадки прямоугольником (рекомендация 4, GrassField.set_landing_sites): landing_pos —
// xy центр, z half_len (по оси), w half_width (поперёк); landing_dir — xy ось (курс), zw
// перпендикуляр; landing_hk — доля высоты скошенной травы.
uniform vec4 landing_pos[4];
uniform vec4 landing_dir[4];
uniform float landing_hk[4];
uniform int landing_count = 0;
// приминание у ног пилота
uniform vec3 press_pos = vec3(1e9);
uniform float press_radius_m = 1.5;
uniform float press_agl_full_m = 0.4;   // ноги ниже — приминание полное
uniform float press_agl_zero_m = 1.2;   // ноги выше — приминания нет
// прореживание вдали (рекомендация 1): rank пучка < far_density(d) — виден
uniform float far_density_min = 0.12;
uniform float thin_start_k = 0.1;
uniform float thin_end_k = 0.85;
uniform float far_width_k = 1.7;
// кольца слоёв (ближний — травинки, дальний — крупные редкие пучки): внутренний край
// дальнего слоя проявляется по rank на [inner_radius_m; inner_radius_m + inner_fade_m],
// внешний край ближнего растворяется по rank с xfade_k·area_radius_m; высота гаснет с
// height_fade_k·area_radius_m до area_radius_m.
uniform float inner_radius_m = -1.0;
uniform float inner_fade_m = 0.001;
uniform float xfade_k = 1.0;
uniform float height_fade_k = 0.6;
uniform float height_k = 1.0;   // множитель высоты слоя

varying vec3 v_col;
varying float v_t;
varying vec3 v_n;
// тень облаков: множитель прямого солнца (cloud_shadow.gdshaderinc) — в light()
varying float v_cs_sun;

void vertex() {
	vec2 cell = grid_center_cell + INSTANCE_CUSTOM.xy;   // смещение клетки в кольце слоя
	vec2 jit = vec2(hash12(cell * 1.37 + 3.1), hash12(cell * 0.71 + 11.3)) - 0.5;
	vec2 xz = (cell + 0.5 + jit * 0.9) * clump_spacing_m;
	float d = length(xz - CAMERA_POSITION_WORLD.xz);
	// прореживание вдали (рекомендация 1): пучок виден, если rank < density(d);
	// дальние пучки шире — компенсируют разрежение (far_width_k, применяется к o ниже).
	float thin_t = clamp(d / max(area_radius_m, 0.001), 0.0, 1.0);
	float thin_s = smoothstep(thin_start_k, thin_end_k, thin_t);
	float density = mix(1.0, far_density_min, thin_s);
	density *= 1.0 - smoothstep(area_radius_m * xfade_k, area_radius_m + 1e-3, d);
	density *= smoothstep(inner_radius_m, inner_radius_m + inner_fade_m, d);
	float rank = hash12(cell + vec2(20.5, 0.0));
	if (rank >= density) {
		VERTEX = vec3(xz.x, -1e4, xz.y);   // пучок скрыт: вырожденные треугольники, без выборок
		v_col = vec3(0.0);
		v_t = 0.0;
		v_n = vec3(0.0, 1.0, 0.0);
	} else {
		float h = h_bilinear(xz);
		// класс — ближайший узел карты (как Terrain.surface_at)
		int c = surface_node(ivec2(round((xz - surface_origin) / surface_spacing)));
		float r = hash12(cell + 2.2);
		float hh = 0.0;
		if (c == 2 || c == 0) {
			hh = mix(blade_height_m.x, blade_height_m.y, r);
		} else if (c == 3) {
			hh = mix(crop_height_m.x, crop_height_m.y, r);
		} else if (c == 4 && hash12(cell + 8.8) < shrub_density) {
			hh = mix(blade_height_m.x, blade_height_m.y, r);
		} else if (c == 1 && hash12(cell + 8.8) < forest_density) {
			hh = mix(forest_height_m.x, forest_height_m.y, r);
		}
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
		// посадки прямоугольником (рекомендация 4): вдоль оси / поперёк, не кругом
		for (int k = 0; k < landing_count; k++) {
			vec2 dv = xz - landing_pos[k].xy;
			float along = dot(dv, landing_dir[k].xy);
			float across = dot(dv, landing_dir[k].zw);
			if (abs(along) <= landing_pos[k].z && abs(across) <= landing_pos[k].w) {
				hh *= landing_hk[k];
			}
		}
		hh *= height_k * (1.0 - smoothstep(area_radius_m * height_fade_k, area_radius_m, d));
		float width_scale = mix(1.0, far_width_k, thin_s);

		// ветер: наклон по полю порывов/термиков + собственное качание
		float t = VERTEX.y;                 // 0 — корень, 1 — кончик
		float wshade;
		vec2 bend;
		grass_wind(xz, d, TIME, wshade, bend);
		float spd = length(wind_vec);
		float amp = smoothstep(0.3, wind_full_ms, spd);
		vec2 dir = spd > 0.05 ? wind_vec / spd : vec2(1.0, 0.0);
		// у каждого пучка своя фаза и немного своя частота — без синхронного «полотна»
		float ph = hash12(cell + 4.4) * 6.2832;
		float fk = 1.0 + sway_hz_var * (2.0 * hash12(cell + 4.9) - 1.0);
		vec2 lean = bend * bend_amp + dir * amp * (0.15 + sway_amp * sin(TIME * sway_hz * fk * 6.2832 + ph));
		// приминание: пилот стоит/бежит — трава клонится от него и ложится
		vec2 pv = xz - press_pos.xz;
		float pd = length(pv);
		float near_ground = 1.0 - smoothstep(press_agl_full_m, press_agl_zero_m, press_pos.y - h);
		float press = near_ground * (1.0 - smoothstep(press_radius_m * 0.4, press_radius_m, pd));
		lean = mix(lean, (pd > 0.01 ? pv / pd : vec2(0.0)) * 1.5, press);
		float l2 = min(dot(lean, lean), 2.0);
		// поворот пучка
		float a = hash12(cell + 6.6) * 6.2832;
		// дальние пучки шире (компенсация прореживания, рекомендация 1)
		vec2 o = mat2(vec2(cos(a), sin(a)), vec2(-sin(a), cos(a))) * VERTEX.xz * width_scale;   // м
		float y = t * hh * inversesqrt(1.0 + l2 * t * t);   // стебель не вытягивается при наклоне
		vec2 off = lean * hh * t * t;
		VERTEX = vec3(xz.x + o.x + off.x, h + y - 0.02, xz.y + o.y + off.y);
		if (hh < 0.02) {
			VERTEX = vec3(xz.x, h - 1.0, xz.y);   // нет травы — пучок прячется под землю
		}
		v_n = normalize(n + vec3(lean.x, 0.0, lean.y) * 0.3);

		// цвет подложки: тот же луг, что рисует рельеф под травой (включая пятна с высоты)
		vec4 rel = relief_at(xz);
		float wet = rel.r * 2.0 - 1.0;
		vec3 base = meadow_ground_color(xz, northness(n), meadow_patch(xz), wet, rel.b * 2.0 - 1.0);
		base = meadow_macro(xz, base, 0.05, wet, d, 0.0);
		if (c == 3) {
			base = field_plot_color(xz, base);
		} else if (c == 1) {
			base *= forest_shade;   // под пологом темнее
		}
		// редкие сухие пучки — солома той же яркости (основной тон — из палитры луга: сухо там,
		// где сухо по локации, южным склонам и пятнам)
		const vec3 LB = vec3(0.2126, 0.7152, 0.0722);
		if (hash12(cell + 17.9) < dry_clump_share) {
			base = straw_color * (dot(base, LB) / max(dot(straw_color, LB), 1e-3)) * 1.15;
		}
		base *= 1.0 + color_variation * (hash12(cell + 13.3) - 0.5) * 2.0;
		base *= blade_tint * (1.0 + wind_shade * wshade);
		v_col = base;
		v_t = t;
	}
	v_cs_sun = cloud_sun_at(VERTEX);
}

void fragment() {
	// у корня темнее (затенение в гуще), к кончику светлее
	ALBEDO = v_col * mix(blade_shade.x, blade_shade.y, v_t);
	// освещение как у земли под травой (обе стороны травинки): нормаль явная и одна и та же
	// для лица и изнанки (render_mode cull_disabled, без FRONT_FACING-переворота — иначе
	// изнанка темнеет); тонкий стебель просвечивает — BACKLIGHT держит изнанку не темнее
	// лица против солнца (VR-6, S1 yaw+180).
	NORMAL = normalize((VIEW_MATRIX * vec4(v_n, 0.0)).xyz);
	ROUGHNESS = 0.9;
	BACKLIGHT = vec3(0.85) * v_col;
	AO = cloud_sky_ao(v_cs_sun);
}

// Встроенное освещение, прямое солнце — в тени облаков слабее (cloud_shadow.gdshaderinc).
void light() {
	cloud_light(NORMAL, VIEW, LIGHT, LIGHT_COLOR, ATTENUATION, LIGHT_IS_DIRECTIONAL, v_cs_sun,
			ALBEDO, ROUGHNESS, METALLIC, 0.0, BACKLIGHT, CS_LAMBERT_WRAP, SPECULAR_AMOUNT,
			DIFFUSE_LIGHT, SPECULAR_LIGHT);
}
