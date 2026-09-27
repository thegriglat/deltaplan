// Общий код кучевого облака: форма, плотность, свет, проход луча через одно облако.
// Один и тот же текст подключают:
//   - cloud_volume.gdshader (бокс на облако, язык шейдеров Godot; запасной путь для Compatibility);
//   - compute-шейдер буфера пониженного разрешения (GLSL 450, cloud_raymarch.gd).
// Поэтому здесь только общее подмножество GLSL/Godot: функции, struct, const.
// Хост объявляет глобальные: noise_shape, noise_detail (sampler3D) и параметры:
//   sun_dir, sun_color, sun_energy, ambient_top, ambient_bottom, ambient_energy, base_darkness,
//   wind_offset, boil, shape_period_m, detail_period_m, hf_period_m, top_period_m, shape_tex_size,
//   detail_tex_size, curl_strength_m, extinction, light_absorb, powder_strength, phase_forward,
//   phase_back, phase_mix, silver, ms_strength, coarse_steps, max_iterations, fine_step_per_m,
//   fine_step_min_m, light_steps, light_step_m, lod_distance_m, detail_enabled (int).

const int TOWERS = 8;
const float CLOUD_PI = 3.14159265;
// Облако внутри бокса гаснет к его краям (без швов на гранях): радиус и высота в долях.
const float FADE_R0 = 1.35;
const float FADE_R1 = 1.6;
const float FADE_H0 = 1.2;
const float FADE_H1 = 1.35;

struct Cloud {
	vec3 c;      // центр основания (x, кромка, z)
	vec3 ax;     // единичная ось вдоль ветра
	vec3 az;     // единичная ось поперёк
	float base;
	float height;
	float rx;
	float rz;
	float growth;
	float decay;
	float activity;
	vec3 seed_off;
	float spread;
	vec4 tw[TOWERS];   // башни: центр (u, v), высота (доля), радиус (доля)
	vec3 ro;           // камера
	float pix;         // угловой размер пикселя, рад
	float foot;        // текущий шаг луча, м (детали мельче шага не берём — без «искр»)
};

vec3 cloud_hash3(float n) {
	return fract(sin(vec3(n, n + 1.7, n + 3.1)) * vec3(43758.5453, 22578.1459, 19642.3490));
}

float cloud_remap(float v, float lo, float hi, float nlo, float nhi) {
	return nlo + (v - lo) * (nhi - nlo) / max(hi - lo, 1e-4);
}

float cloud_hg(float c, float g) {
	float g2 = g * g;
	return (1.0 - g2) / (4.0 * CLOUD_PI * pow(max(1.0 + g2 - 2.0 * g * c, 1e-4), 1.5));
}

// Башни: центральный широкий купол и 7 боковых пониже. Кучевые хорошей погоды шире, чем
// выше: полуширина купола ~0,8 радиуса облака, а мощность облака задаётся отдельно.
void cloud_init_towers(inout Cloud cl) {
	for (int k = 0; k < TOWERS; k++) {
		vec3 hs = cloud_hash3(cl.seed_off.x * 13.1 + float(k) * 7.13);
		bool main_t = k == 0;
		float ang = hs.x * 6.2831853;
		float rr = main_t ? 0.12 * hs.y : mix(0.25, 0.62, hs.y);
		vec2 c = vec2(cos(ang), sin(ang)) * rr;
		float th = main_t ? 1.0 : mix(0.45, 0.85, hs.z) * (1.0 - 0.45 * rr);
		float rk = main_t ? 0.8 : mix(0.35, 0.55, fract(hs.z * 7.1 + hs.x)) * mix(0.75, 1.0, th);
		cl.tw[k] = vec4(c, th, rk);
	}
}

Cloud cloud_make(vec3 c, vec3 ax, vec4 shape, vec4 state, vec4 extra, vec3 ro, float pix) {
	Cloud cl;
	cl.c = c;
	cl.ax = ax;
	cl.az = vec3(-ax.z, 0.0, ax.x);
	cl.base = shape.x;
	cl.height = max(shape.y, 10.0);
	cl.rx = max(shape.z, 10.0);
	cl.rz = max(shape.w, 10.0);
	cl.growth = state.x;
	cl.decay = state.y;
	cl.activity = state.z;
	float s = state.w;
	cl.seed_off = fract(vec3(s * 0.1031, s * 0.1130, s * 0.0973)) * 7.0;
	cl.spread = extra.x;
	cl.ro = ro;
	cl.pix = pix;
	cl.foot = 0.0;
	cloud_init_towers(cl);
	return cl;
}

// Уровень мипа по размеру пикселя на расстоянии точки (в raymarch производные бессмысленны).
float cloud_lod(Cloud cl, vec3 p, float texel_m) {
	float fp = max(distance(p, cl.ro) * cl.pix, cl.foot);
	return max(log2(max(fp / texel_m, 1.0)), 0.0);
}

// Объединение полуэллипсоидов (снизу срезаны кромкой): 0 — поверхность, 1 — центр, < 0 — снаружи.
float cloud_towers(Cloud cl, vec2 uv, float h) {
	float best = -2.0;
	for (int k = 0; k < TOWERS; k++) {
		vec4 t = cl.tw[k];
		vec2 q = vec2(length(uv - t.xy) / t.w, h / t.z);
		best = max(best, 1.0 - length(q));
	}
	return best;
}

// Верх облака над точкой (uv) в долях мощности — по башням (без шума).
float cloud_top_at(Cloud cl, vec2 uv) {
	float top = 0.0;
	for (int k = 0; k < TOWERS; k++) {
		vec4 t = cl.tw[k];
		float q = length(uv - t.xy) / t.w;
		if (q < 1.0) {
			top = max(top, t.z * sqrt(1.0 - q * q));
		}
	}
	return top;
}

// Грубая оболочка облака (без шума): > 0 — где-то рядом может быть плотность.
// По ней ищем вход в облако — детерминированно, без «искр» от случайно пойманных клочьев.
float cloud_envelope(Cloud cl, vec3 p) {
	float h = (p.y - cl.base) / cl.height;
	if (h < 0.0 || h > FADE_H1) {
		return -1.0;
	}
	vec3 d = p - cl.c;
	vec2 uv = vec2(dot(d, cl.ax) / cl.rx, dot(d, cl.az) / cl.rz);
	float spread_k = 1.0 + cl.spread * smoothstep(0.55, 1.0, h);
	// Запас на искажение шумом (±0,15 по uv) и оседание при распаде.
	return cloud_towers(cl, uv / spread_k, h) + 0.35;
}

// Плотность 0..1 в точке p (мир).
// quality: 0 — путь к солнцу (форма + крупные клубы), 1 — полная, 2 — + мелкая эрозия краёв.
float cloud_density(Cloud cl, vec3 p, int quality) {
	float h = (p.y - cl.base) / cl.height;
	// Ниже кромки облака нет вовсе.
	if (h < 0.0 || h > FADE_H1) {
		return 0.0;
	}
	vec3 d = p - cl.c;
	vec2 uv = vec2(dot(d, cl.ax) / cl.rx, dot(d, cl.az) / cl.rz);
	float r_box = length(uv);
	if (r_box > FADE_R1) {
		return 0.0;
	}
	float box_fade = (1.0 - smoothstep(FADE_R0, FADE_R1, r_box)) * (1.0 - smoothstep(FADE_H0, FADE_H1, h));
	float spread_k = 1.0 + cl.spread * smoothstep(0.55, 1.0, h);
	float shape;
	if (quality == 0) {
		shape = cloud_towers(cl, uv / spread_k, h);
	} else {
		if (cloud_towers(cl, uv / spread_k, h) < -0.7) {
			return 0.0;
		}
		// Крупное искажение: башни неровные, контур не круглый.
		vec3 wp = p / top_period_m + cl.seed_off;
		float lw = cloud_lod(cl, p, top_period_m / shape_tex_size);
		float w1 = textureLod(noise_shape, wp, lw).r;
		float w2 = textureLod(noise_shape, wp.zxy + vec3(0.37, 0.11, 0.73), lw).r;
		uv += (vec2(w1, w2) - 0.5) * 0.3;
		float hh = max(h + (w1 - 0.5) * 0.12 * smoothstep(0.1, 0.35, h), 0.0);
		spread_k = 1.0 + cl.spread * smoothstep(0.55, 1.0, hh);
		shape = cloud_towers(cl, uv / spread_k, hh);
	}
	// Распад: башни оседают и расползаются.
	shape -= cl.decay * 0.15;
	shape = clamp(shape / mix(0.55, 0.8, cl.decay), 0.0, 1.0);
	if (shape <= 0.0) {
		return 0.0;
	}
	// Клубы Уорли двух масштабов, переносятся ветром и «кипят».
	vec3 sp = (p + wind_offset) / shape_period_m + cl.seed_off + vec3(0.0, boil, 0.0);
	float ls = cloud_lod(cl, p, shape_period_m / shape_tex_size);
	float b1 = smoothstep(0.2, 0.85, 1.0 - textureLod(noise_shape, sp, ls).r);
	float billow = b1;
	if (quality > 0) {
		float b2 = smoothstep(0.2, 0.85, 1.0 - textureLod(noise_shape, sp * 2.7 + vec3(0.5), max(ls - 1.43, 0.0)).r);
		billow = b1 * 0.6 + b2 * 0.4;
	}
	// Плоская кромка: резкая у живого облака, приподнятая и рваная у тающего.
	float base_soft = mix(10.0, 120.0, cl.decay) / cl.height;
	// Основание не идеально плоское: лёгкий рельеф клубов (у тающего — сильно рваное).
	float base_lift = (base_relief_m / cl.height + cl.decay * 0.3) * (1.0 - billow);
	float dns = shape * smoothstep(base_lift, base_lift + base_soft, h);
	if (dns <= 0.0) {
		return 0.0;
	}
	float erosion = mix(0.75, 0.93, cl.decay) + (1.0 - cl.growth) * 0.15;
	dns = clamp(cloud_remap(dns, erosion * (1.0 - billow), 1.0, 0.0, 1.0), 0.0, 1.0);
	if (quality == 2 && detail_enabled != 0 && dns > 0.0 && dns < 0.9) {
		// Мелкие края: искажение («завихрения») + две октавы мелкого шума.
		vec3 dp = (p + wind_offset * 1.3) / detail_period_m + cl.seed_off * 3.0 + vec3(boil * 3.0);
		float ld = cloud_lod(cl, p, detail_period_m / detail_tex_size);
		vec3 cw = vec3(textureLod(noise_detail, dp * 0.37, ld).r,
				textureLod(noise_detail, dp.yzx * 0.37 + vec3(0.3), ld).r,
				textureLod(noise_detail, dp.zxy * 0.37 + vec3(0.6), ld).r) - 0.5;
		vec3 pw = p + cw * curl_strength_m * (1.0 + cl.decay);
		vec3 dq = (pw + wind_offset * 1.3) / detail_period_m + cl.seed_off * 3.0;
		float dn = textureLod(noise_detail, dq, ld).r;
		float lh = cloud_lod(cl, p, hf_period_m / detail_tex_size);
		float hf = textureLod(noise_detail, (pw + wind_offset * 1.5) / hf_period_m + cl.seed_off, lh).r;
		float det = dn * 0.65 + hf * 0.35;
		// Внизу — волокна, вверху — кочаны.
		det = mix(det, 1.0 - det, smoothstep(0.1, 0.5, h));
		float k = mix(0.4, 0.75, cl.decay);
		dns = clamp(cloud_remap(dns, det * k, 1.0, 0.0, 1.0), 0.0, 1.0);
	}
	// Чёткая поверхность у живого облака, мягкая дымка у тающего.
	// Живое облако: плотность набирается за несколько метров — чёткая кочанная поверхность;
	// у тающего переход длинный — рваная дымка.
	dns = smoothstep(0.0, mix(surface_sharpness, 1.0, cl.decay), dns);
	return dns * box_fade * mix(0.3, 1.0, cl.growth) * mix(1.0, 0.2, cl.decay * cl.decay);
}

// Проход луча через одно облако на отрезке [tn, tf]; накапливает цвет (с премультипликацией),
// пропускание и взвешенную глубину (для дымки и апскейла).
void cloud_march(Cloud cl, vec3 ro, vec3 rd, float tn, float tf, float ign,
		inout float trans, inout vec3 col, inout float t_acc, inout float w_acc) {
	// Дальние облака мельче на экране — им хватает меньше грубых шагов.
	float lod_k = clamp(tn / lod_distance_m, 0.0, 1.0);
	float n_coarse = mix(float(coarse_steps), max(float(coarse_steps) * 0.25, 8.0), lod_k);
	float dt_coarse = (tf - tn) / n_coarse;
	float t = tn + dt_coarse * ign;
	float dt_fine = clamp(tn * fine_step_per_m, fine_step_min_m, dt_coarse);
	bool fine = false;
	bool entered = false;
	float cos_t = dot(rd, sun_dir);
	float phase = mix(cloud_hg(cos_t, phase_forward) * silver, cloud_hg(cos_t, phase_back), phase_mix) * 4.0 * CLOUD_PI;
	vec3 sun_l = sun_color * sun_energy;
	int lsteps = tn > lod_distance_m ? max(light_steps - 2, 1) : light_steps;
	for (int i = 0; i < 512; i++) {
		if (i >= max_iterations || t > tf || trans < 0.01) {
			break;
		}
		vec3 p = ro + rd * t;
		if (!fine) {
			if (cloud_envelope(cl, p) > 0.0) {
				fine = true;
				// Шаг назад — только при первом входе (иначе вход/выход по кругу съедает шаги).
				if (!entered) {
					entered = true;
					t = max(t - dt_coarse, tn) + dt_fine * ign;
				}
			} else {
				t += dt_coarse;
			}
			continue;
		}
		// Мелкий шаг растёт с расстоянием; вне оболочки — снова грубые шаги.
		dt_fine = clamp(t * fine_step_per_m, fine_step_min_m, dt_coarse);
		cl.foot = dt_fine * 0.5;
		float dns = cloud_density(cl, p, 2);
		if (dns <= 0.003 && cloud_envelope(cl, p) <= 0.0) {
			fine = false;
			t += dt_coarse;
			continue;
		}
		if (dns > 0.003) {
			float sigma = dns * extinction;
			float od = 0.0;
			float lstep = light_step_m;
			vec3 lp = p;
			for (int j = 0; j < 8; j++) {
				if (j >= lsteps) {
					break;
				}
				lp += sun_dir * lstep;
				od += cloud_density(cl, lp, 0) * lstep;
				lstep *= light_step_growth;
			}
			// Бир + пологий член многократного рассеяния, powder у краёв.
			float beer = exp(-od * extinction * light_absorb) + ms_strength * exp(-od * extinction * light_absorb * 0.2);
			float powder = 1.0 - exp(-dns * extinction * 60.0) * powder_strength;
			float hh = clamp((p.y - cl.base) / cl.height, 0.0, 1.0);
			// Рассеянный свет неба гаснет по толщине облака над точкой: основание под толстой
			// серединой темнее, чем у тонких краёв; над живым термиком — ещё темнее (подсос).
			vec3 dc = p - cl.c;
			vec2 uvc = vec2(dot(dc, cl.ax) / cl.rx, dot(dc, cl.az) / cl.rz);
			float above_m = max(cloud_top_at(cl, uvc) - hh, 0.0) * cl.height;
			float core = cl.activity * (1.0 - smoothstep(0.0, 0.7, length(uvc)));
			float sky = exp(-above_m / sky_occlusion_m) * mix(1.0, 0.6, core);
			// Снизу — отражённый землёй свет (основание серое, не чёрное), сверху — небо.
			float up_w = smoothstep(0.0, 0.5, hh);
			vec3 amb = (ambient_top * mix(sky, 1.0, up_w * 0.5) + ambient_bottom * base_darkness * (1.0 - up_w)) * ambient_energy;
			vec3 S = (sun_l * beer * phase * powder + amb) * sigma;
			float tr = exp(-sigma * dt_fine);
			col += trans * (S - S * tr) / max(sigma, 1e-6);
			float wgt = trans * (1.0 - tr);
			t_acc += t * wgt;
			w_acc += wgt;
			trans *= tr;
		}
		t += dt_fine;
	}
}
