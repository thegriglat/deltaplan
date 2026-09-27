// Колыхание травы, посевов и деревьев от ветра (VR-17, VR-0): ветер и термики — из атмосферы.
// Параметры задаёт TerrainWind (scripts/terrain/terrain_wind.gd) из configs/world.json → wind_visual
// и из Atmosphere (mean_wind_at у земли, thermals_near). Числа здесь — только технические (хеши).

uniform vec2 wind_vec = vec2(0.0);         // средний ветер у земли (10 м AGL), м/с, X/Z мира
// накопленное на CPU смещение рисунка порывов (offset += wind · dt, TerrainWind.advance, T05):
// заменяет TIME · wind — смена направления ветра не сдвигает рисунок задним числом (нет скачка).
uniform vec2 wind_offset = vec2(0.0);
uniform float wind_gust_scale_m = 60.0;    // размер пятна порыва, м
uniform float wind_gust_speed_k = 1.2;     // скорость бега порывов / скорость ветра
uniform float wind_wave_len_m = 9.0;       // длина волны «ряби» по траве вдоль ветра, м
uniform float wind_full_ms = 8.0;          // при таком ветре колыхание полное, м/с
uniform float wind_shade = 0.16;           // сила изменения яркости травы (изнанка листьев), доля
uniform float wind_bend = 0.35;            // наклон нормали травы по ветру
uniform float wind_fade_m = 3000.0;        // дальше этого расстояния колыхания не видно, м
// порывистость атмосферы (T05): |air_velocity_at − mean_wind_at| у земли, сглаженная TerrainWind
// экспонентой (gust_tau_s) — усиливает амплитуду пятен, когда атмосфера реально порывиста.
uniform float wind_gust_ms = 0.0;          // сглаженная порывистость, м/с
uniform float gust_full_ms = 2.0;          // порывистость, при которой усиление насыщается, м/с
uniform float gust_gain = 0.6;             // добавка к амплитуде пятен при полной порывистости, доля
// термики у земли: xy — ось X/Z, z — радиус, м; w — сила 0..1 (огибающая × сила / норма)
uniform vec4 wind_thermals[8];
uniform int wind_thermal_count = 0;
uniform float thermal_reach = 2.5;         // зона подсоса вокруг термика, радиусов
uniform float thermal_ring_m = 14.0;       // шаг «колец» сходящейся к центру волны, м
uniform float thermal_arms = 3.0;          // число рукавов закрутки
uniform float thermal_inflow_hz = 0.35;    // частота бега волны к центру, Гц
uniform float thermal_gain = 1.6;          // усиление колыхания над термиком

float wind_hash(vec2 p) {
	p = mod(p, 4096.0);
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float wind_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = p - i;
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(wind_hash(i), wind_hash(i + vec2(1.0, 0.0)), u.x),
			mix(wind_hash(i + vec2(0.0, 1.0)), wind_hash(i + vec2(1.0, 1.0)), u.x), u.y);
}

// Поле колыхания травы в точке xz: shade — добавка яркости (−1..1, × wind_shade),
// bend — горизонтальный наклон стеблей (для нормали / смещения), в долях.
// dist — расстояние до камеры (гасит мелкую рябь вдали), t — время, с.
void grass_wind(vec2 xz, float dist, float t, out float shade, out vec2 bend) {
	shade = 0.0;
	bend = vec2(0.0);
	if (dist > wind_fade_m) {
		return;
	}
	float spd = length(wind_vec);
	vec2 d = spd > 0.05 ? wind_vec / spd : vec2(1.0, 0.0);
	float amp = smoothstep(0.3, wind_full_ms, spd);
	amp *= 1.0 + gust_gain * smoothstep(0.0, gust_full_ms, wind_gust_ms);
	// порывы: пятна бегут по ветру — смещение накоплено на CPU (wind_offset), не TIME · wind,
	// чтобы смена направления не двигала рисунок задним числом (нет скачка при повороте ветра).
	vec2 p = xz - wind_offset * wind_gust_speed_k;
	float g = wind_noise(p / wind_gust_scale_m) * 0.65 + wind_noise(p / (wind_gust_scale_m * 0.4)) * 0.35;
	g = smoothstep(0.35, 0.8, g);
	// рябь поперёк ветра (волны по ниве), гаснет, когда волна мельче пикселя
	float along = dot(p, d);
	float ripple = sin(6.2832 * along / wind_wave_len_m + 7.0 * wind_noise(p / 31.0))
			* smoothstep(0.25, 0.75, wind_noise(p / 17.0 + 5.3));
	float fine = 1.0 - smoothstep(wind_fade_m * 0.15, wind_fade_m * 0.5, dist);
	float w = amp * g * (0.55 + 0.45 * ripple * fine);
	shade = w;
	bend = d * w;
	// термики: сходящаяся к центру закрученная волна и усиление колыхания
	for (int k = 0; k < wind_thermal_count; k++) {
		vec4 th = wind_thermals[k];
		vec2 v = xz - th.xy;
		float r = length(v);
		float s = r / max(th.z, 1.0);
		if (s > thermal_reach) {
			continue;
		}
		float env = th.w * (1.0 - smoothstep(thermal_reach * 0.5, thermal_reach, s))
				* smoothstep(0.05, 0.35, s);
		float ang = atan(v.y, v.x);
		// волна бежит к оси, закручена и изломана шумом — не ровные круги, а сходящиеся «струи»
		float wob = wind_noise(v / 25.0 + vec2(float(k) * 7.1, t * 0.2));
		float ph = r / thermal_ring_m + t * thermal_inflow_hz + ang * thermal_arms / 6.2832
				+ 2.5 * wob;
		float wave = (0.5 + 0.5 * sin(6.2832 * ph)) * smoothstep(0.2, 0.7, wind_noise(v / 11.0 + 3.7 + t * 0.3));
		float tw = env * (0.45 + 0.55 * wave * mix(0.6, 1.0, fine)) * thermal_gain;
		vec2 inward = r > 0.1 ? -v / r : vec2(0.0);
		// стебли клонятся к оси и чуть по закрутке
		vec2 swirl = vec2(-inward.y, inward.x);
		shade = max(shade, tw);
		bend = mix(bend, (inward + 0.4 * swirl) * tw, clamp(env, 0.0, 1.0));
	}
}
