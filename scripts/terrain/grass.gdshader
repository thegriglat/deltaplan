// Травинки вокруг камеры (VR-17, VR-6): пучки на сетке, привязанной к миру (при движении не
// «прыгают»), MultiMesh без трансформов — положение, высоту и цвет каждого пучка считает шейдер.
// Где трава — решает карта поверхности (луг, пашня — выше, кустарник — реже; лес, скалы, вода,
// застройка — нет); цвет — та же палитра, что у рельефа (meadow_color). Качание — тем же полем
// ветра, что колышет рельеф (порывы, термики), приминание у ног пилота. Параметры задаёт
// GrassField из configs/world.json → grass.
shader_type spatial;
render_mode cull_disabled, diffuse_lambert_wrap, world_vertex_coords, specular_disabled;

#include "res://scripts/terrain/terrain_common.gdshaderinc"
#include "res://scripts/terrain/terrain_wind.gdshaderinc"

uniform vec2 grid_center_cell;
uniform int grid_n;
uniform float clump_spacing_m = 0.5;
uniform float area_radius_m = 35.0;
uniform vec2 blade_height_m = vec2(0.25, 0.55);   // луг, мин/макс
uniform vec2 crop_height_m = vec2(0.6, 0.9);      // посевы (нива)
uniform float shrub_density = 0.5;
uniform float color_variation = 0.15;
uniform float sway_hz = 0.8;                      // частота собственного качания, Гц
uniform float sway_amp = 0.12;                    // собственное качание (доля высоты) при полном ветре
uniform float bend_amp = 0.7;                     // наклон по ветру/порыву (доля высоты)
// скошенные места (посадочные площадки): xy — центр, z — радиус, м; w — доля высоты
uniform vec4 mowed[4];
uniform int mowed_count = 0;
// приминание у ног пилота
uniform vec3 press_pos = vec3(1e9);
uniform float press_radius_m = 1.5;

varying vec3 v_col;
varying float v_t;
varying vec3 v_n;

void vertex() {
	int id = INSTANCE_ID;
	vec2 cell = grid_center_cell + vec2(float(id % grid_n), float(id / grid_n)) - float(grid_n / 2);
	vec2 jit = vec2(hash12(cell * 1.37 + 3.1), hash12(cell * 0.71 + 11.3)) - 0.5;
	vec2 xz = (cell + 0.5 + jit * 0.9) * clump_spacing_m;
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
	float d = length(xz - CAMERA_POSITION_WORLD.xz);
	hh *= 1.0 - smoothstep(area_radius_m * 0.6, area_radius_m, d);

	// ветер: наклон по полю порывов/термиков + собственное качание
	float t = VERTEX.y;                 // 0 — корень, 1 — кончик
	float wshade;
	vec2 bend;
	grass_wind(xz, d, TIME, wshade, bend);
	float spd = length(wind_vec);
	float amp = smoothstep(0.3, wind_full_ms, spd);
	vec2 dir = spd > 0.05 ? wind_vec / spd : vec2(1.0, 0.0);
	float ph = hash12(cell + 4.4) * 6.2832;
	vec2 lean = bend * bend_amp + dir * amp * (0.15 + sway_amp * sin(TIME * sway_hz * 6.2832 + ph));
	// приминание: пилот стоит/бежит — трава клонится от него и ложится
	vec2 pv = xz - press_pos.xz;
	float pd = length(pv);
	float near_ground = 1.0 - smoothstep(1.5, 3.0, press_pos.y - h);
	float press = near_ground * (1.0 - smoothstep(press_radius_m * 0.4, press_radius_m, pd));
	lean = mix(lean, (pd > 0.01 ? pv / pd : vec2(0.0)) * 1.5, press);
	float l2 = min(dot(lean, lean), 2.0);
	// поворот пучка
	float a = hash12(cell + 6.6) * 6.2832;
	vec2 o = mat2(vec2(cos(a), sin(a)), vec2(-sin(a), cos(a))) * VERTEX.xz;   // м
	float y = t * hh * inversesqrt(1.0 + l2 * t * t);   // стебель не вытягивается при наклоне
	vec2 off = lean * hh * t * t;
	VERTEX = vec3(xz.x + o.x + off.x, h + y - 0.02, xz.y + o.y + off.y);
	if (hh < 0.02) {
		VERTEX = vec3(xz.x, h - 1.0, xz.y);   // нет травы — пучок прячется под землю
	}
	v_n = normalize(n + vec3(lean.x, 0.0, lean.y) * 0.3);

	vec3 base = meadow_color(xz, northness(n), meadow_patch(xz));
	if (c == 3) {
		base = field_plot_color(xz, base);
	}
	base *= 1.0 + color_variation * (hash12(cell + 13.3) - 0.5) * 2.0;
	base *= vec3(1.08, 1.0, 0.85) * (1.0 + wind_shade * wshade);
	v_col = base;
	v_t = t;
}

void fragment() {
	// у корня темнее (затенение в гуще), к кончику светлее
	ALBEDO = v_col * mix(1.25, 1.75, v_t);
	// освещение как у земли под травой (обе стороны травинки)
	NORMAL = normalize((VIEW_MATRIX * vec4(v_n, 0.0)).xyz);
	ROUGHNESS = 0.9;
	BACKLIGHT = vec3(0.25) * v_col;
}
