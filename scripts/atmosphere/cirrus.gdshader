// Перистая пелена (VR-28): тонкий высокий слой 7–10 км. Волокна вытянуты по ветру верхнего яруса,
// сплошная пелена при большом покрытии; светлее к солнцу, гало 22° в перисто-слоистых.
// Плоскость движется с камерой, узор привязан к миру (не «плывёт» за камерой), сносится ветром.
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix, shadows_disabled;

uniform sampler2D noise : filter_linear_mipmap, repeat_enable;
uniform float cover = 0.3;
uniform vec2 wind_dir = vec2(1.0, 0.0);
uniform vec2 drift = vec2(0.0);
uniform float flow_period_m = 150000.0;
uniform float flow_bend_m = 20000.0;
uniform float band_period_m = 24000.0;
uniform float band_stretch = 10.0;
uniform float fiber_period_m = 1500.0;
uniform float fiber_stretch = 30.0;
uniform float strand_angle_deg = 4.0;
uniform float strand_length_m = 20000.0;
uniform float end_soft = 0.04;
uniform float veil_period_m = 30000.0;
uniform float opacity = 0.85;
uniform float tau_max = 1.5;
uniform vec3 color = vec3(1.0);
uniform vec3 sun_dir = vec3(0.3, 0.8, 0.5);
uniform float sun_energy = 1.3;
uniform float halo_rad = 0.384;
uniform float halo_strength = 0.35;
uniform float half_size_m = 80000.0;

varying vec3 v_world;

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 p = v_world.xz + drift;
	vec2 wd = normalize(wind_dir);
	vec2 q = vec2(dot(p, wd), dot(p, vec2(-wd.y, wd.x)));
	float fp = length(fwidth(v_world.xz));
	// Течение: сдвиг ветра поворачивает ленты — очень крупный шум гнёт координаты поперёк ветра,
	// все ленты рядом изгибаются вместе (не каждая по-своему).
	// Изгиб меняется в основном вдоль ветра: поперёк почти постоянен, иначе полосы складываются в петли.
	float nf = texture(noise, vec2(q.x / flow_period_m, q.y / (flow_period_m * 6.0)) + 0.13, 2.0).r;
	float nf2 = texture(noise, vec2(q.x / (flow_period_m * 0.4), q.y / (flow_period_m * 3.0)) + 0.61, 2.0).r;
	q.y += (nf - 0.5) * flow_bend_m * 2.0 + (nf2 - 0.5) * flow_bend_m * 0.5;
	// Где быть перистым — крупные пятна по покрытию.
	float nv = texture(noise, p / veil_period_m + 0.71).r;
	// Где лента есть, а где кончается — огибающая вдоль ветра (гребни шума дали бы замкнутые петли).
	float ne = texture(noise, vec2(q.x / (band_period_m * band_stretch), q.y / (band_period_m * 1.5)) + 0.91, 2.0).r;
	// Лента обрывается резко (end_soft — полуширина перехода по шуму), а не тает.
	float env = smoothstep(0.52 - end_soft, 0.52 + end_soft, ne);
	// Хвосты-«когти»: у конца ленты координаты загибаются вбок — концы крючком.
	float hook = 1.0 - smoothstep(0.5, 0.62, ne);
	float nh = texture(noise, vec2(q.x / (band_period_m * 1.5), q.y / (band_period_m * 0.6)) + 0.83, 1.0).r;
	vec2 qh = q + vec2(0.0, (nh - 0.5) * band_period_m * 0.25 * hook);
	// Ленты: сглаженный шум, сильно вытянутый вдоль течения — почти параллельные мягкие полосы.
	float nb = texture(noise, vec2(qh.x / (band_period_m * band_stretch * 4.0), qh.y / band_period_m) + 0.29, 2.5).r;
	float nb2 = texture(noise, vec2(qh.x / (band_period_m * band_stretch * 2.0), qh.y / (band_period_m * 0.4)) + 0.47, 1.5).r;
	float rb = pow(1.0 - abs(2.0 * nb - 1.0), 2.0);
	float rb2 = pow(1.0 - abs(2.0 * nb2 - 1.0), 2.5);
	float band = max(smoothstep(0.3, 0.85, rb), 0.7 * smoothstep(0.4, 0.9, rb2)) * env;
	// Шире ядра — там только отдельные нити: край ленты распадается на волокна, а не очерчен.
	float wide = max(smoothstep(0.05, 0.6, rb), 0.7 * smoothstep(0.15, 0.7, rb2)) * smoothstep(0.48 - 2.0 * end_soft, 0.52 + end_soft, ne);
	// Нити: несколько слоёв внахлёст под углами ±strand_angle_deg к ленте, у каждого свои сдвиг
	// и возмущения. Одна нить почти прозрачна; где нахлёстываются — толщина складывается, белеет.
	// Вдоль нити: плотная «голова», редеющий хвост, разрывы (сухая кисть).
	float aa = smoothstep(0.1, 0.35, fp / fiber_period_m);
	float strands = 0.0;
	for (int i = 0; i < 4; i++) {
		float fi = float(i);
		float ang = radians(strand_angle_deg) * (fi / 1.5 - 1.0) + 0.02 * sin(fi * 7.3);
		vec2 r = vec2(cos(ang) * qh.x - sin(ang) * qh.y, sin(ang) * qh.x + cos(ang) * qh.y);
		vec2 o = vec2(0.173, 0.311) * (fi + 1.0);
		// Возмущения: нить слегка гуляет поперёк.
		float nw = texture(noise, vec2(r.x / (band_period_m * 1.2), r.y / (band_period_m * 0.3)) + o * 2.3).r;
		r.y += (nw - 0.5) * fiber_period_m * 2.0;
		float ns = texture(noise, vec2(r.x / (fiber_period_m * fiber_stretch), r.y / fiber_period_m) + o).r;
		float line = mix(pow(1.0 - abs(2.0 * ns - 1.0), 6.0), 0.12, aa);
		// Голова и хвост: фаза вдоль нити, своя у каждой (сдвиг по поперечной координате).
		float ph = texture(noise, vec2(0.37 + fi * 0.21, r.y / (fiber_period_m * 4.0)) + o).r;
		float t = fract(r.x / strand_length_m + ph * 4.0);
		float taper = smoothstep(0.0, 0.04, t) * mix(1.0, 0.1, t);
		// Разрывы вдоль нити.
		float nbk = texture(noise, vec2(r.x / (fiber_period_m * fiber_stretch * 0.3), r.y / (fiber_period_m * 2.0)) + o * 1.7).r;
		float brk = smoothstep(0.35, 0.6, nbk);
		strands += line * mix(0.35, 1.0, taper * brk) * (0.8 + 0.1 * fi);
	}
	float fibers = band * 0.2 + wide * strands * 0.6;
	// Хвосты тоньше ядра.
	fibers *= mix(0.55, 1.0, 1.0 - hook);
	float thr = 1.0 - cover;
	float patch = smoothstep(thr - 0.05, thr + 0.2, nv);
	float veil = smoothstep(0.6, 1.0, cover) * (0.2 + 0.25 * strands);
	float d = max(patch * fibers, veil);
	float n1 = nb;
	// Край плоскости растворяется.
	vec2 rel = v_world.xz - CAMERA_POSITION_WORLD.xz;
	d *= 1.0 - smoothstep(0.55, 0.95, length(rel) / half_size_m);
	// Оптическая толщина: по вертикали tau_max·d, под углом путь в слое длиннее (1/|cos|) —
	// к горизонту пелена густеет. Прозрачность 1 − e^(−τ): тонкое — сквозь видно небо.
	vec3 rd = normalize(v_world - CAMERA_POSITION_WORLD);
	float path = 1.0 / max(abs(rd.y), 0.2);
	float tau = d * tau_max * path;
	float c = dot(rd, sun_dir);
	// Лёд рассеивает вперёд: к солнцу ярче, тем сильнее, чем тоньше (дальше — многократное рассеяние).
	float fwd = pow(max(c, 0.0), 6.0) * 1.2 * exp(-0.5 * tau);
	float ang = acos(clamp(c, -1.0, 1.0));
	float halo = exp(-pow((ang - halo_rad) / 0.035, 2.0)) * (0.6 + 0.4 * n1) * halo_strength * smoothstep(0.5, 0.9, cover);
	// Гало: красноватый внутренний край, голубоватый внешний.
	vec3 halo_col = mix(vec3(1.0, 0.8, 0.6), vec3(0.8, 0.9, 1.0), smoothstep(-0.02, 0.02, ang - halo_rad));
	float thick = 1.0 - exp(-tau);
	vec3 col = color * sun_energy * (0.7 + 0.25 * thick + fwd) + halo_col * halo;
	float alpha = clamp(thick * opacity + halo * d, 0.0, 1.0);
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
	// Как у облаков: Compatibility не переводит этот вывод в sRGB.
	col = mix(col * 12.92, 1.055 * pow(max(col, vec3(0.0)), vec3(1.0 / 2.4)) - 0.055, step(vec3(0.0031308), col));
#endif
	ALBEDO = col;
	ALPHA = alpha;
}
