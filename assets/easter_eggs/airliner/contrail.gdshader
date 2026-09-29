shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix, fog_disabled, shadows_disabled;
// Инверсионный след: прямая лента вдоль +Z узла (назад от самолёта), повёрнута к камере в
// вершинном шейдере. Вершины статичны; длина, ширина и прозрачность — uniform-ы из airliner.gd.

uniform float start_m = 80.0;       // начало ленты позади самолёта, м
uniform float length_m = 10000.0;   // длина видимой ленты, м
uniform float speed_ms = 230.0;     // скорость самолёта, м/с (возраст следа = расстояние / скорость)
uniform float trail_life_s = 60.0;  // живучесть следа, с
uniform float width0_m = 12.0;      // ширина у самолёта, м
uniform float spread_ms = 2.0;      // рост ширины, м/с возраста
uniform float alpha0 = 0.85;        // непрозрачность у самолёта
uniform vec3 tint = vec3(1.0);

varying float v_alpha;
varying float v_edge;
varying float v_soft;

void vertex() {
	float u = UV.y;
	float d = start_m + u * u * max(length_m - start_m, 1.0);
	float age = d / speed_ms;
	float k = clamp(age / trail_life_s, 0.0, 1.0);
	float w = width0_m + spread_ms * age;
	vec3 wp = (MODEL_MATRIX * vec4(0.0, 0.0, d, 1.0)).xyz;
	vec3 dir = normalize((MODEL_MATRIX * vec4(0.0, 0.0, 1.0, 0.0)).xyz);
	vec3 view = CAMERA_POSITION_WORLD - wp;
	vec3 side = cross(dir, view);
	side = length(side) > 1e-4 ? normalize(side) : vec3(1.0, 0.0, 0.0);
	wp += side * UV.x * w * 0.5;
	POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(wp, 1.0);
	float grow = smoothstep(0.0, 4.0, age);  // образование: первые секунды след ещё прозрачен
	v_alpha = alpha0 * grow * pow(1.0 - k, 1.5);
	v_edge = UV.x;
	v_soft = mix(0.5, 1.0, k);  // края мягчают к хвосту
}

void fragment() {
	float e = 1.0 - abs(v_edge);
	ALBEDO = tint;
	ALPHA = clamp(v_alpha * smoothstep(0.0, v_soft, e), 0.0, 1.0);
}
