shader_type spatial;
// Кусты у земли (ShrubScatter): цвет листвы — цвет экземпляра MultiMesh (вид + разброс),
// рисунок «пучков листьев» — шум в мировых координатах (вдали гаснет), затенённый низ и
// просветы, покачивание макушки от ветра (то же поле порывов, что у травы и деревьев).
render_mode cull_back, diffuse_burley;

#include "res://scripts/terrain/terrain_wind.gdshaderinc"

uniform float leaf_scale_m = 0.14;      // размер пучка листьев в рисунке, м
uniform float leaf_contrast = 0.55;     // сила рисунка (тёмные просветы между пучками)
uniform float detail_fade_m = 160.0;    // дальше рисунок листвы гаснет, м
uniform float bottom_dark = 0.45;       // яркость низа куста относительно макушки
uniform float sway_top_m = 0.08;        // отклонение макушки при ветре wind_full_ms, м
uniform float sway_hz = 0.6;
uniform float backlight = 0.25;         // просвет листвы против солнца

varying vec3 v_wp;
varying vec3 v_tint;
varying float v_h;
varying vec3 v_wn;

float h31(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.zyx + 31.32);
	return fract((p.x + p.y) * p.z);
}

float vn3(vec3 p) {
	vec3 i = floor(p);
	vec3 f = p - i;
	vec3 u = f * f * (3.0 - 2.0 * f);
	return mix(
		mix(mix(h31(i), h31(i + vec3(1, 0, 0)), u.x),
			mix(h31(i + vec3(0, 1, 0)), h31(i + vec3(1, 1, 0)), u.x), u.y),
		mix(mix(h31(i + vec3(0, 0, 1)), h31(i + vec3(1, 0, 1)), u.x),
			mix(h31(i + vec3(0, 1, 1)), h31(i + vec3(1, 1, 1)), u.x), u.y),
		u.z);
}

void vertex() {
	vec3 base = MODEL_MATRIX[3].xyz;
	v_h = clamp(VERTEX.y, 0.0, 1.0);
	float spd = length(wind_vec);
	vec2 d = spd > 0.05 ? wind_vec / spd : vec2(1.0, 0.0);
	float amp = smoothstep(0.3, wind_full_ms, spd);
	float g = wind_noise((base.xz - wind_offset * wind_gust_speed_k) / wind_gust_scale_m);
	float ph = wind_hash(floor(base.xz)) * 6.2832;
	float sway = amp * sway_top_m * v_h * v_h
			* (0.5 + 0.7 * g + 0.3 * sin(TIME * sway_hz * 6.2832 + ph));
	mat3 m = mat3(MODEL_MATRIX);
	float s2 = max(dot(m[1], m[1]), 1e-6);
	VERTEX += transpose(m) * (vec3(d.x, 0.0, d.y) * sway) / s2;
	v_wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_wn = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	v_tint = COLOR.rgb;
}

void fragment() {
	float dist = length(v_wp - CAMERA_POSITION_WORLD);
	float near = 1.0 - smoothstep(detail_fade_m * 0.4, detail_fade_m, dist);
	vec3 q = v_wp / leaf_scale_m;
	float n = vn3(q) * 0.65 + vn3(q * 2.3 + 7.1) * 0.35;
	float big = vn3(v_wp / (leaf_scale_m * 4.0) + 3.3);
	float leaf = mix(0.8, mix(1.0 - leaf_contrast, 1.12, smoothstep(0.3, 0.7, n)), near);
	vec3 col = v_tint * leaf * (0.85 + 0.3 * big);
	// низ и нутро куста в тени, бока темнее макушки (листва сама себя затеняет)
	col *= mix(bottom_dark, 1.0, smoothstep(0.0, 0.75, v_h));
	col *= mix(0.75, 1.05, smoothstep(-0.2, 0.8, v_wn.y));
	// макушки чуть светлее и желтее (молодые побеги)
	col = mix(col, col * vec3(1.15, 1.12, 0.85), smoothstep(0.6, 1.0, v_h) * 0.5);
	ALBEDO = col;
	BACKLIGHT = col * backlight;
	ROUGHNESS = 0.85;
	SPECULAR = 0.25;
}
