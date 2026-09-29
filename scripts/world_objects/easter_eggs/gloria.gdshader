shader_type canvas_item;
// Глория (брокенский призрак): цветные кольца вокруг антисолнечной точки на облаке. Квадрат на
// экране (облака рисует компоситор ПОСЛЕ прозрачных мешей и стёр бы меш); r = 0 в центре, 1 на краю квада (внешний угол). Кольца каждого цвета — на радиусе,
// пропорциональном длине волны (синий ближе к центру, красный дальше). Множитель по фону.
render_mode blend_mul;

uniform float opacity : hint_range(0.0, 1.0) = 1.0;
uniform float red_r = 0.5;   // радиус первого красного кольца, доля внешнего радиуса
uniform float depth_mix = 0.22; // глубина затемнения между кольцами
uniform float shadow = 0.18;   // затемнение центрального пятна тени

void fragment() {
	vec2 p = (UV - 0.5) * 2.0;
	float r = length(p);
	vec3 scale = vec3(1.0, 0.83, 0.66); // R, G, B: отношение длин волн
	vec3 x = vec3(r) / (red_r * scale);
	vec3 f = pow(0.5 + 0.5 * cos(6.2831853 * x), vec3(1.5));
	vec3 env = smoothstep(0.55, 1.0, x) * exp(-0.22 * x * x);
	vec3 ring = f * env;
	float edge = 1.0 - smoothstep(0.8, 1.0, r);
	vec3 col = vec3(1.0) - depth_mix * edge * (vec3(1.0) - clamp(ring * 1.6, 0.0, 1.0)) * smoothstep(0.1, 0.35, r);
	col -= shadow * (1.0 - smoothstep(0.0, 0.16, r));
	COLOR = vec4(mix(vec3(1.0), col, opacity), 1.0);
}
