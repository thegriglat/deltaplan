// Дымка слоя перемешивания (VR-3) и воздушная перспектива чистого воздуха (FR-20).
// Полноэкранный квад: по глубине кадра восстанавливается точка сцены, оптическая толщина
// считается аналитически вдоль луча камера → точка.
// Два вещества, у каждого своё спектральное ослабление (R, G, B относительно 550 нм):
//   чистый воздух (рэлеевское, синее сильнее) — по всей длине луча до рельефа; в небе — только
//     у горизонта: путь как в экспоненциальной атмосфере с высотой clear_sky_height_m
//     (min(длина, H/sin угла)), чтобы у горизонта небо по цвету сходилось с дальним рельефом
//     (иначе край рельефа читался резкой зубчатой «ступенькой» поверх неба);
//   мутный слой под инверсией (аэрозоль, почти серый) — плотность постоянна до top_msl
//     и линейно спадает до нуля в переходе top_transition_m; небо — луч до max_distance.
// Свет от дымки (in-scatter) = Σ τᵢ·цветᵢ / Σ τᵢ · (1 − e^(−τ)) по каналам: на коротком пути он
// голубой и тёмный (насыщается только синий), на длинном — светлый, к цвету горизонта.
// Пропускание сцены — по зелёному каналу (яркостный контраст), смешение premultiplied.
// Фаза: чистый воздух — Рэлей (1+cos²θ), мутный слой — Хеньи–Гринстейн (g = haze_g); обе
// нормированы на 90° от солнца, поэтому сбоку дымка такая же, как была; к солнцу светлее и теплее
// (цвет солнца), против солнца мутный слой темнее. Зеркало формул — SkyEnvironment.haze_phase_*.
// Параметры задаёт scripts/world/sky_environment.gd из configs/world.json → haze.
shader_type spatial;
render_mode unshaded, blend_premul_alpha, depth_draw_never, depth_test_disabled, cull_disabled, fog_disabled;

uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;
uniform float top_msl = 1900.0;          // верх дымки над уровнем моря, м
uniform float top_transition_m = 60.0;   // толщина перехода на верхней границе, м
uniform float extinction = 1.5e-4;       // ослабление слоя под границей на 550 нм, 1/м
uniform vec3 extinction_rgb = vec3(0.85, 1.0, 1.2); // спектр ослабления слоя (R, G, B)
uniform float clear_extinction = 0.0;    // ослабление чистого воздуха на 550 нм, 1/м
uniform float clear_sky_height_m = 1500.0; // в небе чистый воздух: путь ≤ H / sin(угла над горизонтом)
uniform vec3 clear_rgb = vec3(0.5, 1.0, 2.0); // спектр ослабления чистого воздуха
uniform vec3 clear_color : source_color = vec3(0.66, 0.76, 0.88); // насыщенный свет чистого воздуха
uniform float max_distance_m = 150000.0; // длина луча в небо
uniform vec3 haze_color : source_color = vec3(0.75, 0.76, 0.76);
uniform vec3 sun_color : source_color = vec3(1.0, 0.95, 0.85);
uniform vec3 sun_dir = vec3(0.0, 1.0, 0.0); // направление НА солнце
uniform float sun_scatter = 0.35;        // подсветка дымки против солнца
uniform float haze_g = 0.7;             // анизотропия Хеньи–Гринстейна мутного слоя (0 — изотропно, → 1 — узкий ореол)
uniform float forward_gain = 3.0;        // яркость ореола у самого солнца относительно прежнего cos^6
uniform float forward_knee = 6.0;        // сжатие ореола: x/(x+knee), x = HG(θ)/HG(90°) − 1
uniform float back_dim = 0.3;            // насколько мутный слой темнее против солнца (0..1)
uniform float clear_phase_k = 0.5;       // доля фазы Рэлея (1+cos²θ) у чистого воздуха (0 — изотропно)
uniform float inscatter_power = 1.0;    // свет дымки ∝ (1 − e^(−τ))^p: >1 — тонкая дымка светит слабее
uniform float max_opacity = 0.97;        // дымка никогда не закрывает всё полностью

void vertex() {
	POSITION = vec4(VERTEX.xy * 2.0, 1.0, 1.0);
}

// Первообразная профиля плотности по высоте: f(y) = 1 ниже a, линейно до 0 к b, 0 выше.
float haze_integral(float y) {
	float a = top_msl - 0.5 * top_transition_m;
	float b = top_msl + 0.5 * top_transition_m;
	if (y <= a) {
		return y;
	}
	if (y >= b) {
		return top_msl;
	}
	float w = max(top_transition_m, 1e-3);
	return a + (w * w - (b - y) * (b - y)) / (2.0 * w);
}

float haze_profile(float y) {
	return clamp((top_msl + 0.5 * top_transition_m - y) / max(top_transition_m, 1e-3), 0.0, 1.0);
}

void fragment() {
	float depth = textureLod(depth_tex, SCREEN_UV, 0.0).r;
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
	vec3 ndc = vec3(SCREEN_UV, depth) * 2.0 - 1.0;
	bool sky = depth >= 1.0;
#else
	vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, depth);
	bool sky = depth <= 0.0;
#endif
	vec4 v = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
	vec3 view_pos = v.xyz / v.w;
	vec3 cam = (INV_VIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	vec3 world = (INV_VIEW_MATRIX * vec4(view_pos, 1.0)).xyz;
	vec3 ray = world - cam;
	float len = length(ray);
	vec3 dir = ray / max(len, 1e-4);
	if (sky) {
		len = max_distance_m;
	}
	len = min(len, max_distance_m);
	float y0 = cam.y;
	float y1 = y0 + dir.y * len;
	// путь в дымке (эквивалентная длина при полной плотности)
	float path;
	if (abs(y1 - y0) > 0.01) {
		path = len * (haze_integral(y1) - haze_integral(y0)) / (y1 - y0);
	} else {
		path = len * haze_profile(y0);
	}
	// фазы нормированы на 90° от солнца (там = 1): сбоку яркость как раньше
	float mu = dot(dir, normalize(sun_dir));
	float hg_ratio = (1.0 - haze_g * haze_g) / pow(1.0 + haze_g * haze_g - 2.0 * haze_g * mu, 1.5)
			* pow(1.0 + haze_g * haze_g, 1.5) / (1.0 - haze_g * haze_g);
	float fwd = max(hg_ratio - 1.0, 0.0);
	float halo = fwd / (fwd + forward_knee);
	float rayleigh = mix(1.0, 1.0 + mu * mu, clear_phase_k);
	vec3 tau_h = extinction * max(path, 0.0) * extinction_rgb;
	float clear_len = len;
	if (sky) {
		clear_len = min(len, clear_sky_height_m / max(dir.y, 1e-4));
	}
	vec3 tau_c = clear_extinction * clear_len * clear_rgb;
	vec3 tau = tau_h + tau_c;
	vec3 opacity = min(vec3(1.0) - exp(-tau), vec3(max_opacity));
	vec3 col_h = haze_color * mix(1.0, min(hg_ratio, 1.0), back_dim)
			+ sun_color * sun_scatter * forward_gain * halo;
	vec3 col = (tau_h * col_h + tau_c * clear_color * rayleigh) / max(tau, vec3(1e-6));
	ALBEDO = col * pow(opacity, vec3(inscatter_power));
	ALPHA = opacity.g;
}
