// Мелкие признаки термика (QL-9): ласточки (mode 0) и пух/мусор (mode 1, плоская «точка» к камере).
// Размер на экране не меньше min_px: меш растёт вокруг своего центра (до max_scale), иначе
// ласточку 0,3 м и пушинку 0,1 м с воздуха не видно. INSTANCE_CUSTOM: x — прозрачность, y — доля
// «мусора» (тёмный), z — фаза взмаха.
shader_type spatial;
render_mode unshaded, cull_disabled, blend_mix, depth_draw_never, shadows_disabled;

uniform int mode = 0;
uniform float ref_size = 0.34;
uniform float min_px = 4.0;
uniform float max_scale = 40.0;
uniform float flap_hz = 7.0;
uniform vec3 color_a : source_color = vec3(0.05, 0.05, 0.07);
uniform vec3 color_b : source_color = vec3(0.3, 0.24, 0.17);

varying float v_alpha;
varying vec3 v_col;

void vertex() {
	vec4 c = MODELVIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0);
	float dist = max(-c.z, 1.0);
	float px_per_m = PROJECTION_MATRIX[1][1] * VIEWPORT_SIZE.y * 0.5 / dist;
	float s = clamp(min_px / max(ref_size * px_per_m, 1.0e-6), 1.0, max_scale);
	v_alpha = INSTANCE_CUSTOM.x;
	v_col = mix(color_a, color_b, INSTANCE_CUSTOM.y);
	if (mode == 0) {
		float a = 0.45 * sin(TIME * flap_hz * TAU + INSTANCE_CUSTOM.z * TAU);
		VERTEX.y += abs(VERTEX.x) * a;
	} else {
		MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
			INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
	}
	VERTEX *= s;
}

void fragment() {
	vec3 col = v_col;
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
	col = mix(col * 12.92, 1.055 * pow(max(col, vec3(0.0)), vec3(1.0 / 2.4)) - 0.055, step(vec3(0.0031308), col));
#endif
	ALBEDO = col;
	if (mode == 1) {
		float d = length(UV - vec2(0.5)) * 2.0;
		ALPHA = v_alpha * (1.0 - smoothstep(0.55, 1.0, d));
	} else {
		ALPHA = v_alpha;
	}
}
