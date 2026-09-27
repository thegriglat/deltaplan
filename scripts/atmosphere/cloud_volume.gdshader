// Объёмное кучевое облако: raymarch внутри своего бокса (MeshInstance3D с BoxMesh).
// Форма: купол с плоской нижней кромкой + эрозия 3D-шумом (клубы Уорли).
// Свет: Бир (поглощение по пути к солнцу), powder-эффект, двулепестковая фаза
// Хеньи — Гринстейна (серебристая кайма против солнца), рассеянный свет неба/земли.
// Стадия жизни — через параметры экземпляра: растущее облако плотное с чёткими клубами,
// распадающееся — рваное, прозрачное, с приподнятой рваной кромкой.
// Работает в Forward+ и Compatibility (глубина сцены — с учётом разных диапазонов NDC).
shader_type spatial;
render_mode unshaded, cull_front, depth_test_disabled, depth_draw_never, blend_premul_alpha, fog_disabled, shadows_disabled;

uniform sampler3D noise_shape : filter_linear_mipmap, repeat_enable;
uniform sampler3D noise_detail : filter_linear_mipmap, repeat_enable;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;

// Солнце (к солнцу) и свет.
uniform vec3 sun_dir = vec3(0.3, 0.77, 0.56);
uniform vec3 sun_color = vec3(1.0, 0.97, 0.92);
uniform float sun_energy = 1.3;
uniform vec3 ambient_top = vec3(0.55, 0.66, 0.85);
uniform vec3 ambient_bottom = vec3(0.32, 0.33, 0.33);
uniform float ambient_energy = 0.9;

// Движение шума: перенос ветром (м) и «кипение».
uniform vec3 wind_offset = vec3(0.0);
uniform float boil = 0.0;

// Масштабы шума (период текстуры, м).
uniform float shape_period_m = 1400.0;
uniform float detail_period_m = 260.0;
uniform float top_period_m = 3000.0;
uniform float shape_tex_size = 96.0;
uniform float detail_tex_size = 64.0;

// Оптика.
uniform float extinction = 0.06;       // 1/м при плотности 1
uniform float light_absorb = 0.7;      // поглощение по пути к солнцу (доля extinction)
uniform float powder_strength = 0.6;
uniform float phase_forward = 0.6;
uniform float phase_back = -0.2;
uniform float phase_mix = 0.25;
uniform float silver = 1.4;            // усиление серебристой каймы
uniform float ms_strength = 0.35;      // вклад многократного рассеяния

// Качество.
uniform int coarse_steps = 48;          // шагов по пустоте через весь бокс
uniform int max_iterations = 160;      // предел выборок на пиксель
uniform float fine_step_per_m = 0.006; // мелкий шаг = расстояние × множитель
uniform float fine_step_min_m = 4.0;
uniform int light_steps = 4;
uniform bool detail_enabled = true;    // мелкая эрозия краёв
uniform float light_step_m = 40.0;
uniform float lod_distance_m = 12000.0;

// Дымка (из WorldEnvironment, экспоненциальная).
uniform vec3 fog_color = vec3(0.66, 0.74, 0.86);
uniform float fog_density = 0.00004;
uniform float fog_sun_scatter = 0.15;

// Параметры облака (на экземпляр).
instance uniform vec4 cloud_shape;  // x: нижняя кромка (м, мир), y: мощность (м), z: полудлина вдоль ветра (м), w: полуширина (м)
instance uniform vec4 cloud_state;  // x: рост 0..1, y: распад 0..1, z: активность термика (подсос) 0..1, w: зерно
instance uniform vec4 cloud_extra;  // x: переразвитие/растекание верха 0..1

float hg(float c, float g) {
	float g2 = g * g;
	return (1.0 - g2) / (4.0 * PI * pow(max(1.0 + g2 - 2.0 * g * c, 1e-4), 1.5));
}

float remap(float v, float lo, float hi, float nlo, float nhi) {
	return nlo + (v - lo) * (nhi - nlo) / max(hi - lo, 1e-4);
}

// Общие для всех выборок одного пикселя величины.
const int TOWERS = 8;

struct Cloud {
	vec3 c;      // центр бокса
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
};

// Уровень мипа по размеру пикселя на расстоянии точки: в raymarch производные текстурных
// координат между соседними лучами бессмысленны, поэтому уровень считаем сами.
float lod_for(Cloud cl, vec3 p, float texel_m) {
	return max(log2(max(distance(p, cl.ro) * cl.pix / texel_m, 1.0)), 0.0);
}

vec3 hash3(float n) {
	return fract(sin(vec3(n, n + 1.7, n + 3.1)) * vec3(43758.5453, 22578.1459, 19642.3490));
}

// Параметры башен — один раз на пиксель (детерминированно от зерна облака).
void init_towers(inout Cloud cl) {
	for (int k = 0; k < TOWERS; k++) {
		vec3 hs = hash3(cl.seed_off.x * 13.1 + float(k) * 7.13);
		bool main_t = k == 0;
		vec2 c = (hs.xy - 0.5) * (main_t ? 0.3 : 1.1);
		// Центральные башни выше, крайние ниже — общий купол из башен.
		float edge = length(c);
		float th = main_t ? 1.0 : mix(0.45, 0.9, hs.z) * (1.0 - 0.4 * edge);
		// Радиус башни согласован с высотой: низкие башни — узкие (без «тарелок» у кромки).
		float rk = main_t ? 0.6 : mix(0.3, 0.5, fract(hs.z * 7.1 + hs.x)) * mix(0.6, 1.0, th);
		cl.tw[k] = vec4(c, th, rk);
	}
}

// Башни кучевого облака: объединение полуэллипсоидов (снизу срезаны плоской кромкой).
// Возвращает «запас» внутри формы: 0 — на поверхности, 1 — в центре, < 0 — снаружи.
float towers(Cloud cl, vec2 uv, float h) {
	float best = -2.0;
	for (int k = 0; k < TOWERS; k++) {
		vec4 t = cl.tw[k];
		// Основание чуть уже «пуза» — облако нависает над кромкой, а не лежит на тарелке.
		float bulge = mix(0.86, 1.0, smoothstep(0.0, 0.5 * t.z, h));
		vec2 q = vec2(length(uv - t.xy) / (t.w * bulge), h / t.z);
		best = max(best, 1.0 - length(q));
	}
	return best;
}

// Плотность облака 0..1 в точке p (мир).
// quality: 0 — для пути к солнцу (форма + крупные клубы), 1 — полная, 2 — полная с мелкой эрозией.
float density(Cloud cl, vec3 p, int quality) {
	vec3 d = p - cl.c;
	float h = (p.y - cl.base) / cl.height;   // 0 — кромка, 1 — верх
	if (h < -0.02 || h > 1.3) {
		return 0.0;
	}
	vec2 uv = vec2(dot(d, cl.ax) / cl.rx, dot(d, cl.az) / cl.rz);
	if (dot(uv, uv) > 2.6) {
		return 0.0;   // пусто — без выборок текстуры
	}
	float spread_k = 1.0 + cl.spread * smoothstep(0.55, 1.0, h);
	float hh = max(h, 0.0);
	float shape;
	if (quality == 0) {
		shape = towers(cl, uv / spread_k, hh);
	} else {
		// Грубая проверка без искажения: далеко снаружи — сразу ноль, без выборок текстуры.
		if (towers(cl, uv / spread_k, hh) < -0.7) {
			return 0.0;
		}
		// Искажение формы крупным шумом: башни неровные, контур рваный.
		vec3 wp = p / top_period_m + cl.seed_off;
		float lw = lod_for(cl, p, top_period_m / shape_tex_size);
		float w1 = textureLod(noise_shape, wp, lw).r;
		float w2 = textureLod(noise_shape, wp.zxy + vec3(0.37, 0.11, 0.73), lw).r;
		uv += (vec2(w1, w2) - 0.5) * 0.35;
		hh = max(h + (w1 - 0.5) * 0.12 * smoothstep(0.05, 0.3, h), 0.0);
		// Растекание верха (переразвитие): башни шире наверху.
		spread_k = 1.0 + cl.spread * smoothstep(0.55, 1.0, hh);
		shape = towers(cl, uv / spread_k, hh);
	}
	// Распад: башни оседают и расползаются.
	shape -= cl.decay * 0.15;
	shape = clamp(shape / mix(0.6, 0.8, cl.decay), 0.0, 1.0);
	if (shape <= 0.0) {
		return 0.0;
	}
	// Клубы Уорли (кочанная поверхность) двух масштабов, переносятся ветром и «кипят».
	vec3 sp = (p + wind_offset) / shape_period_m + cl.seed_off + vec3(0.0, boil, 0.0);
	float ls = lod_for(cl, p, shape_period_m / shape_tex_size);
	float b1 = smoothstep(0.2, 0.85, 1.0 - textureLod(noise_shape, sp, ls).r);
	float billow = b1;
	if (quality > 0) {
		float b2 = smoothstep(0.2, 0.85, 1.0 - textureLod(noise_shape, sp * 2.7 + vec3(0.5), max(ls - 1.43, 0.0)).r);
		billow = b1 * 0.65 + b2 * 0.35;
	}
	// Плоская кромка: резкая у активного облака, приподнятая и рваная у распадающегося.
	float base_soft = mix(8.0, 120.0, cl.decay) / cl.height;
	float base_lift = cl.decay * 0.3 * (1.0 - billow);
	float base_f = smoothstep(base_lift, base_lift + base_soft, h);
	float dns = shape * base_f;
	if (dns <= 0.0) {
		return 0.0;
	}
	// Эрозия клубами: зрелое — плотно и чётко, молодое и распадающееся — рыхлее.
	float erosion = mix(0.78, 0.95, cl.decay) + (1.0 - cl.growth) * 0.15;
	dns = clamp(remap(dns, erosion * (1.0 - billow), 1.0, 0.0, 1.0), 0.0, 1.0);
	if (quality == 2 && dns > 0.0 && dns < 0.85) {
		vec3 dp = (p + wind_offset * 1.3) / detail_period_m + cl.seed_off * 3.0 + vec3(boil * 3.0);
		float dn = textureLod(noise_detail, dp, lod_for(cl, p, detail_period_m / detail_tex_size)).r;
		// Внизу мелочь «волокнистая», вверху — кочанная.
		float det = mix(dn, 1.0 - dn, smoothstep(0.1, 0.5, h));
		float k = mix(0.42, 0.75, cl.decay);
		dns = clamp(remap(dns, det * k, 1.0, 0.0, 1.0), 0.0, 1.0);
	}
	// Чёткая поверхность у живого облака, мягкая дымка у тающего.
	dns = clamp(dns * mix(2.0, 1.0, cl.decay), 0.0, 1.0);
	// Активный подсос: основание плотнее.
	dns *= 1.0 + cl.activity * 0.6 * (1.0 - smoothstep(0.0, 0.2, h));
	// Молодое облако — клочья, распад — прозрачнее.
	return dns * mix(0.3, 1.0, cl.growth) * mix(1.0, 0.2, cl.decay * cl.decay);
}

void fragment() {
	vec3 ro = CAMERA_POSITION_WORLD;
	vec3 wp = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 rd = normalize(wp - ro);

	Cloud cl;
	vec3 mx = MODEL_MATRIX[0].xyz;
	vec3 my = MODEL_MATRIX[1].xyz;
	vec3 mz = MODEL_MATRIX[2].xyz;
	cl.c = MODEL_MATRIX[3].xyz;
	cl.ax = normalize(mx);
	cl.az = normalize(mz);
	cl.base = cloud_shape.x;
	cl.height = max(cloud_shape.y, 10.0);
	cl.rx = max(cloud_shape.z, 10.0);
	cl.rz = max(cloud_shape.w, 10.0);
	cl.growth = cloud_state.x;
	cl.decay = cloud_state.y;
	cl.activity = cloud_state.z;
	float s = cloud_state.w;
	cl.seed_off = fract(vec3(s * 0.1031, s * 0.1130, s * 0.0973)) * 7.0;
	cl.spread = cloud_extra.x;
	init_towers(cl);
	cl.ro = ro;
	cl.pix = length(fwidth(rd));

	// Пересечение луча с боксом (в осях бокса).
	vec3 dl = ro - cl.c;
	vec3 lo = vec3(dot(dl, mx) / dot(mx, mx), dot(dl, my) / dot(my, my), dot(dl, mz) / dot(mz, mz));
	vec3 ld = vec3(dot(rd, mx) / dot(mx, mx), dot(rd, my) / dot(my, my), dot(rd, mz) / dot(mz, mz));
	vec3 inv = 1.0 / ld;
	vec3 t0 = (vec3(-0.5) - lo) * inv;
	vec3 t1 = (vec3(0.5) - lo) * inv;
	vec3 tmin = min(t0, t1);
	vec3 tmax = max(t0, t1);
	float tn = max(max(max(tmin.x, tmin.y), tmin.z), 0.0);
	float tf = min(min(tmax.x, tmax.y), tmax.z);

	// Глубина сцены: рельеф перед облаком или внутри бокса обрезает луч.
	float depth = texture(depth_tex, SCREEN_UV).r;
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
	vec3 ndc = vec3(SCREEN_UV, depth) * 2.0 - 1.0;
#else
	vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, depth);
#endif
	vec4 vpos = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
	vpos.xyz /= vpos.w;
	float scene_t = length(vpos.xyz);
	tf = min(tf, scene_t);
	if (tf <= tn) {
		discard;
	}

	// Грубые шаги по пустоте, у первой встречи с облаком — шаг назад и мелкие шаги
	// (мелкий шаг растёт с расстоянием) — чёткая поверхность без полос и зерна.
	float dt_coarse = (tf - tn) / float(coarse_steps);
	float ign = fract(52.9829189 * fract(dot(FRAGCOORD.xy, vec2(0.06711056, 0.00583715))));
	float t = tn + dt_coarse * ign;
	float dt_fine = clamp(tn * fine_step_per_m, fine_step_min_m, dt_coarse);
	bool fine = false;

	float cos_t = dot(rd, sun_dir);
	float phase = mix(hg(cos_t, phase_forward) * silver, hg(cos_t, phase_back), phase_mix) * 4.0 * PI;
	vec3 sun_l = sun_color * sun_energy;
	// Меньше шагов к солнцу вдали.
	int lsteps = tn > lod_distance_m ? max(light_steps - 2, 1) : light_steps;

	float trans = 1.0;
	vec3 col = vec3(0.0);
	float t_acc = 0.0;
	float w_acc = 0.0;
	for (int i = 0; i < 512; i++) {
		if (i >= max_iterations || t > tf || trans < 0.01) {
			break;
		}
		vec3 p = ro + rd * t;
		float dns = density(cl, p, fine && detail_enabled ? 2 : 1);
		if (!fine) {
			if (dns > 0.003) {
				fine = true;
				t = max(t - dt_coarse, tn) + dt_fine * ign;
			} else {
				t += dt_coarse;
			}
			continue;
		}
		if (dns > 0.003) {
			float sigma = dns * extinction;
			// Путь к солнцу: несколько выборок с растущим шагом.
			float od = 0.0;
			float ls = light_step_m;
			vec3 lp = p;
			for (int j = 0; j < 8; j++) {
				if (j >= lsteps) {
					break;
				}
				lp += sun_dir * ls;
				od += density(cl, lp, 0) * ls;
				ls *= 1.8;
			}
			// Бир + грубое многократное рассеяние (второй, более пологий член).
			float beer = exp(-od * extinction * light_absorb) + ms_strength * exp(-od * extinction * light_absorb * 0.2);
			float powder = 1.0 - exp(-dns * extinction * 60.0) * powder_strength;
			float hh = clamp((p.y - cl.base) / cl.height, 0.0, 1.0);
			// Рассеянный свет: снизу темнее; активный подсос делает основание ещё темнее и плотнее.
			float amb_occ = mix(0.35 + 0.35 * hh, 1.0, hh) * (1.0 - cl.activity * 0.35 * (1.0 - smoothstep(0.0, 0.3, hh)));
			vec3 amb = mix(ambient_bottom, ambient_top, hh) * ambient_energy * amb_occ;
			vec3 S = (sun_l * beer * phase * powder + amb) * sigma;
			float tr = exp(-sigma * dt_fine);
			vec3 si = (S - S * tr) / max(sigma, 1e-6);
			col += trans * si;
			float wgt = trans * (1.0 - tr);
			t_acc += t * wgt;
			w_acc += wgt;
			trans *= tr;
		}
		t += dt_fine;
	}
	float alpha = 1.0 - trans;
	if (alpha < 0.002) {
		discard;
	}
	// Дымка по средней глубине облака.
	float dist = w_acc > 0.0 ? t_acc / w_acc : tn;
	float fog = 1.0 - exp(-dist * fog_density);
	vec3 fc = fog_color * (1.0 + fog_sun_scatter * pow(max(cos_t, 0.0), 8.0));
	col = col * (1.0 - fog) + fc * alpha * fog;
	ALBEDO = col;
	ALPHA = alpha;
}
