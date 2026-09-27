// Дымка слоя перемешивания (VR-3): от земли до верхней границы top_msl воздух мутный
// (видимость visibility), выше — чистый (там работает только лёгкая голубая дымка окружения).
// Полноэкранный квад: по глубине кадра восстанавливается точка сцены, оптическая толщина
// считается аналитически вдоль луча камера → точка (плотность постоянна под границей и
// линейно спадает до нуля в переходе top_transition_m). Небо — луч до max_distance.
// Параметры задаёт scripts/world/sky_environment.gd из configs/world.json → haze.
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, depth_test_disabled, cull_disabled, fog_disabled;

uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;
uniform float top_msl = 1900.0;          // верх дымки над уровнем моря, м
uniform float top_transition_m = 60.0;   // толщина перехода на верхней границе, м
uniform float extinction = 1.5e-4;       // коэффициент ослабления под границей, 1/м
uniform float max_distance_m = 150000.0; // длина луча в небо
uniform vec3 haze_color : source_color = vec3(0.75, 0.76, 0.76);
uniform vec3 sun_color : source_color = vec3(1.0, 0.95, 0.85);
uniform vec3 sun_dir = vec3(0.0, 1.0, 0.0); // направление НА солнце
uniform float sun_scatter = 0.35;        // подсветка дымки против солнца
uniform float sun_scatter_power = 6.0;   // узость ореола
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
	bool sky = depth >= 0.999999;
#else
	vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, depth);
	bool sky = depth <= 1e-6;
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
	float tau = extinction * max(path, 0.0);
	float alpha = min(1.0 - exp(-tau), max_opacity);
	float s = pow(max(dot(dir, normalize(sun_dir)), 0.0), sun_scatter_power);
	ALBEDO = haze_color + sun_color * sun_scatter * s;
	ALPHA = alpha;
}
