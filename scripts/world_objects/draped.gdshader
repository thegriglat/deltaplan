// Плоские объекты по рельефу (дороги, покос посадки): вершины уже лежат на height_at,
// но рельеф вдали рисуется грубым LOD, поэтому точки сдвигаются к камере на
// depth_bias_m + depth_pull·расстояние — лента не тонет в рельефе и не мерцает.
// Цвет — цвет вершин (линейный), альфа вершин — растушёвка края (дизеринг, без сортировки).
// Полосы покоса: чередование яркости поперёк stripe_axis (0 — без полос).
shader_type spatial;
render_mode cull_disabled;

uniform float depth_bias_m = 0.3;
uniform float depth_pull = 0.004;
uniform float roughness : hint_range(0.0, 1.0) = 0.95;
// Затемнение обочин дороги (UV.x = 0 и 1 — края).
uniform float edge_darken = 0.15;
uniform vec2 stripe_axis = vec2(1.0, 0.0);
uniform float stripe_width_m = 6.0;
uniform float stripe_contrast = 0.0;
// Мягкий рваный край (UV.x → 0/1): альфа начинает падать с edge_alpha_start (1.0 — выключено,
// как раньше), край размывается шумом по миру на масштабе edge_noise_m (0 — выключено).
uniform float edge_alpha_start : hint_range(0.0, 1.0) = 1.0;
uniform float edge_noise_m = 0.0;
// Плавное угасание вдали (view-space расстояние): fade_start_m..fade_end_m, 1e6 — выключено.
uniform float fade_start_m = 1.0e6;
uniform float fade_end_m = 1.0000001e6;

varying vec3 world_pos;
varying float view_dist;


float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}


void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec4 v = MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	float d = length(v.xyz);
	view_dist = d;
	float pull = min(depth_bias_m + d * depth_pull, d * 0.5);
	v.xyz -= v.xyz / max(d, 1e-3) * pull;
	POSITION = PROJECTION_MATRIX * v;
}


void fragment() {
	float e = abs(UV.x - 0.5) * 2.0;
	if (edge_noise_m > 0.0) {
		float n = hash12(floor(world_pos.xz / edge_noise_m)) - 0.5;
		e = clamp(e + n * 0.6, 0.0, 1.0);
	}
	float alpha = COLOR.a;
	if (edge_alpha_start < 1.0) {
		alpha *= 1.0 - smoothstep(edge_alpha_start, 1.0, e);
	}
	alpha *= 1.0 - smoothstep(fade_start_m, fade_end_m, view_dist);
	if (alpha < 0.999 && alpha < hash12(FRAGCOORD.xy)) {
		discard;
	}
	vec3 c = COLOR.rgb;
	c *= 1.0 - edge_darken * smoothstep(0.6, 1.0, e);
	if (stripe_contrast > 0.0) {
		float s = dot(world_pos.xz, stripe_axis) / stripe_width_m;
		float band = smoothstep(0.35, 0.5, abs(fract(s) - 0.5));
		c *= 1.0 + stripe_contrast * (band * 2.0 - 1.0);
	}
	ALBEDO = c;
	ROUGHNESS = roughness;
	NORMAL = FRONT_FACING ? NORMAL : -NORMAL;
}
