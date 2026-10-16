// Столб-цилиндр цели (GL-К4 v2): непрозрачность растёт с расстоянием до камеры
// (вблизи alpha_near, вдали alpha_far, между — smoothstep по fade_near_m..fade_far_m).
shader_type spatial;
render_mode unshaded, cull_disabled, blend_mix, depth_draw_never, shadows_disabled, fog_disabled;

uniform vec3 color : source_color = vec3(0.2, 0.75, 1.0);
uniform float alpha_near = 0.12;
uniform float alpha_far = 0.35;
uniform float fade_near_m = 500.0;
uniform float fade_far_m = 4000.0;


void fragment() {
	float d = length(VERTEX);
	float t = smoothstep(fade_near_m, max(fade_far_m, fade_near_m + 1.0), d);
	ALBEDO = color;
	ALPHA = mix(alpha_near, alpha_far, t);
}
