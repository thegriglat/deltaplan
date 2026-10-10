// Провода ЛЭП (VR-10): лента, развёрнутая к камере. Ширина — реальная (wire_width_m), но не меньше
// min_pixels пикселя; прозрачность = доля покрытия пикселя (реальная ширина / нарисованная), поэтому
// вдали провод тает, как в жизни: вблизи — чёткая линия, на 100–200 м — едва заметная нить.
// Вершины: пары с UV.x = −1/+1 в одной точке, NORMAL — направление провода.
shader_type spatial;
render_mode unshaded, cull_disabled, blend_mix, depth_draw_never, shadows_disabled;

uniform vec3 wire_color : source_color = vec3(0.18);
uniform float wire_width_m = 0.02;
uniform float min_pixels = 1.0;
// Множитель заметности (блики, контраст с небом), > 1 — видно дальше.
uniform float visibility_boost = 1.5;
uniform float fade_start_m = 300.0;
uniform float fade_end_m = 500.0;

varying float coverage;


void vertex() {
	vec3 vpos = (MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 vt = normalize((MODELVIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	float d = max(length(vpos), 1e-3);
	vec3 side = cross(vt, vpos / d);
	float sl = length(side);
	side = sl > 1e-4 ? side / sl : vec3(0.0, 1.0, 0.0);
	float px = d * 2.0 / (PROJECTION_MATRIX[1][1] * VIEWPORT_SIZE.y);
	float w = max(wire_width_m, min_pixels * px);
	coverage = clamp(wire_width_m / w * visibility_boost, 0.0, 1.0)
			* (1.0 - smoothstep(fade_start_m, fade_end_m, d));
	vpos += side * UV.x * 0.5 * w;
	POSITION = PROJECTION_MATRIX * vec4(vpos, 1.0);
}


void fragment() {
	ALBEDO = wire_color;
	ALPHA = coverage;
}
