// Перистая пелена (VR-28): тонкий высокий слой 7–10 км. Волокна вытянуты по ветру верхнего яруса,
// сплошная пелена при большом покрытии; светлее к солнцу, гало 22° в перисто-слоистых.
// Плоскость движется с камерой, узор привязан к миру (не «плывёт» за камерой), сносится ветром.
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix, shadows_disabled;

uniform sampler2D noise : filter_linear_mipmap, repeat_enable;
uniform float cover = 0.3;
uniform vec2 wind_dir = vec2(1.0, 0.0);
uniform vec2 drift = vec2(0.0);
uniform float streak_period_m = 9000.0;
uniform float streak_stretch = 6.0;
uniform float veil_period_m = 30000.0;
uniform float opacity = 0.85;
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
	// Изгиб волокон крупным шумом: пряди, «крючья», а не ровный «гребень».
	vec2 wq = vec2(texture(noise, p / (veil_period_m * 0.6) + 0.13).r,
			texture(noise, p / (veil_period_m * 0.45) + 0.57).r) - 0.5;
	q += wq * vec2(streak_period_m * 0.8, streak_period_m * 0.3);
	// Волокна: вытянутый по ветру шум двух масштабов; пелена — крупный шум.
	float n1 = texture(noise, vec2(q.x / (streak_period_m * streak_stretch), q.y / streak_period_m)).r;
	float n2 = texture(noise, vec2(q.x / (streak_period_m * streak_stretch * 0.3), q.y / (streak_period_m * 0.25)) + 0.37).r;
	float nv = texture(noise, p / veil_period_m + 0.71).r;
	// Волокна-«когти»: гребни шума (1 − |2n − 1|) — тонкие яркие нити, загнутые изгибом координат.
	float ridge1 = pow(1.0 - abs(2.0 * n1 - 1.0), 10.0);
	float ridge2 = pow(1.0 - abs(2.0 * n2 - 1.0), 14.0);
	// Нити тянутся по ветру, на концах — мягкий «хвост» (ослабление по второму шуму).
	float fibers = max(ridge1 * smoothstep(0.2, 0.6, n2), ridge2 * 0.6);
	// Где быть прядям — крупный шум (пятна), при большом покрытии — сплошная пелена.
	float thr = 1.0 - cover;
	float patch = smoothstep(thr, thr + 0.2, nv);
	float veil = smoothstep(0.6, 1.0, cover) * (0.35 + 0.3 * n1);
	float d = max(patch * fibers, veil);
	// Край плоскости растворяется.
	vec2 rel = v_world.xz - CAMERA_POSITION_WORLD.xz;
	d *= 1.0 - smoothstep(0.55, 0.95, length(rel) / half_size_m);
	vec3 rd = normalize(v_world - CAMERA_POSITION_WORLD);
	float c = dot(rd, sun_dir);
	float fwd = pow(max(c, 0.0), 8.0) * 0.8;
	float ang = acos(clamp(c, -1.0, 1.0));
	float halo = exp(-pow((ang - halo_rad) / 0.035, 2.0)) * (0.6 + 0.4 * n1) * halo_strength * smoothstep(0.5, 0.9, cover);
	// Гало: красноватый внутренний край, голубоватый внешний.
	vec3 halo_col = mix(vec3(1.0, 0.8, 0.6), vec3(0.8, 0.9, 1.0), smoothstep(-0.02, 0.02, ang - halo_rad));
	vec3 col = color * sun_energy * (0.8 + fwd) + halo_col * halo;
	float alpha = clamp(d * opacity + halo * d, 0.0, 1.0);
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
	// Как у облаков: Compatibility не переводит этот вывод в sRGB.
	col = mix(col * 12.92, 1.055 * pow(max(col, vec3(0.0)), vec3(1.0 / 2.4)) - 0.055, step(vec3(0.0031308), col));
#endif
	ALBEDO = col;
	ALPHA = alpha;
}
