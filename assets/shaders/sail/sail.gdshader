// Парус дельтаплана (docs/models.md → «Шейдер паруса»): просвечивание на солнце, карта нормалей
// (латы, швы, ламинат), двусторонний; вершинная анимация по параметрам полёта.
// Маска анимации — вторая UV меша Sail (tools/blender/build_gliders.py):
//   UV2.x — вес пролёта между латами (0 на лате), UV2.y — доля хорды (0 — передняя кромка,
//   1 — задняя), у нижней обшивки UV2.y + 2. Смещение — вдоль +Y модели (вверх по крылу), м.
// Значения по умолчанию совпадают с assets/shaders/sail/sail_params.json (их ставит SailMaterial).
shader_type spatial;
// shadows_disabled — парус не принимает тени (свою тоже): тень верхней обшивки иначе гасит
// просвечивание нижней. Отбрасывает тень как обычно (на землю и пилота, VR-6).
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx, shadows_disabled;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap_anisotropic;
uniform sampler2D trans_tex : hint_default_white, filter_linear_mipmap;
uniform vec4 albedo_tint : source_color = vec4(1.0);
// Перекраска (боты, configs/bots.json → sail_schemes): поворот цветового тона вокруг серой оси
// (белое и серое не меняются), насыщенность и яркость. По умолчанию — исходная раскраска.
uniform float hue_shift_rad = 0.0;
uniform float sat_scale = 1.0;
uniform float value_scale = 1.0;
uniform float roughness : hint_range(0.0, 1.0) = 0.72;
uniform float normal_strength = 0.8;
uniform float translucency : hint_range(0.0, 3.0) = 0.8;  // сила света насквозь
uniform vec3 transmit_tint : source_color = vec3(1.0, 0.97, 0.9);

// параметры полёта — выставляет код (GliderVisual) каждый кадр
uniform float airspeed_ms = 10.0;
uniform float stall_amount : hint_range(0.0, 1.0) = 0.0;
uniform float turbulence : hint_range(0.0, 1.0) = 0.0;
uniform float time_override = -1.0;  // ≥ 0 — своё время (стенд, повторяемые кадры)

// «мягкий» парус на малой скорости: колышется между латами
uniform float billow_amp_m = 0.05;
uniform float billow_hz = 0.8;
uniform float soft_speed_ms = 8.0;   // ниже — полная амплитуда
uniform float firm_speed_ms = 14.0;  // выше — парус натянут
// сваливание: неровный трепет всей задней половины
uniform float stall_amp_m = 0.07;
uniform float stall_hz = 3.5;
// турбулентность: медленные волны
uniform float turb_amp_m = 0.03;
uniform float turb_hz = 1.6;
// трепет задней кромки на большой скорости (VR-19)
uniform float flutter_amp_m = 0.02;
uniform float flutter_start_ms = 14.0;
uniform float flutter_full_ms = 25.0;
uniform float flutter_hz_per_ms = 0.6;   // частота = k · V
uniform float flutter_wavelength_m = 0.45;
uniform float lower_surface_factor = 0.35;

const float TAU_ = 6.28318530718;

void vertex() {
	float bay = UV2.x;
	float low = step(1.5, UV2.y);
	float t = UV2.y - 2.0 * low;
	float x = VERTEX.x;
	float tm = time_override >= 0.0 ? time_override : TIME;
	float body = bay * smoothstep(0.15, 0.75, t);
	float soft = 1.0 - smoothstep(soft_speed_ms, firm_speed_ms, airspeed_ms);
	float billow = billow_amp_m * soft * sin(TAU_ * billow_hz * tm + x * 1.3 + t * 2.0);
	float st = stall_amp_m * stall_amount * sin(TAU_ * stall_hz * tm + x * 3.1 + t * 5.0)
			* (0.55 + 0.45 * sin(TAU_ * stall_hz * 0.37 * tm + x * 1.1));
	float tb = turb_amp_m * turbulence * sin(TAU_ * turb_hz * tm + x * 0.9 + t * 2.0)
			* sin(TAU_ * turb_hz * 0.61 * tm + x * 2.3 + 1.0);
	float te = smoothstep(0.8, 1.0, t) * (0.3 + 0.7 * bay);
	float fl_amp = flutter_amp_m * smoothstep(flutter_start_ms, flutter_full_ms, airspeed_ms)
			+ 0.5 * stall_amp_m * stall_amount;
	float fl = fl_amp * sin(TAU_ * (flutter_hz_per_ms * max(airspeed_ms, 1.0) * tm
			- x / flutter_wavelength_m));
	float d = body * (billow + st + tb) + te * fl;
	d *= mix(1.0, lower_surface_factor, low);
	VERTEX.y += d;
}

void fragment() {
	vec4 a = texture(albedo_tex, UV) * albedo_tint;
	if (hue_shift_rad != 0.0 || sat_scale != 1.0 || value_scale != 1.0) {
		float g = dot(a.rgb, vec3(1.0 / 3.0));
		vec3 c = a.rgb - vec3(g);
		vec3 k = vec3(0.57735027);
		c = c * cos(hue_shift_rad) + cross(k, c) * sin(hue_shift_rad);
		a.rgb = clamp((vec3(g) + c * sat_scale) * value_scale, 0.0, 1.0);
	}
	ALBEDO = a.rgb;
	ROUGHNESS = roughness;
	SPECULAR = 0.35;
	NORMAL_MAP = texture(normal_tex, UV).rgb;
	NORMAL_MAP_DEPTH = normal_strength;
	float tr = texture(trans_tex, UV).r;
	BACKLIGHT = a.rgb * transmit_tint * tr * translucency;
}
