// Клубы пыли от порывов: billboard в MultiMesh, вся анимация в шейдере по времени атмосферы.
// Экземпляр: origin — старт у земли; MODEL_MATRIX[0] = (размер, снос vx, снос vz), [1].x = подъём м/с;
// INSTANCE_CUSTOM = (поворот, t0, жизнь, зерно). Вне жизни клуб схлопнут. Свет — как у пыли УАЗа.
shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, specular_disabled, diffuse_lambert_wrap, shadows_disabled;

uniform float now = 0.0;
uniform vec3 tint_a : source_color = vec3(0.58, 0.51, 0.39);
uniform vec3 tint_b : source_color = vec3(0.74, 0.69, 0.6);
uniform float density = 0.5;
uniform float near_fade_m = 6.0;

varying float v_age;
varying float v_rnd;
varying float v_tint;

void vertex() {
	float t0 = INSTANCE_CUSTOM.y;
	float life = max(INSTANCE_CUSTOM.z, 0.01);
	float age_s = now - t0;
	float age = age_s / life;
	v_age = age;
	v_rnd = fract(INSTANCE_CUSTOM.w * 7.31);
	v_tint = step(1.0, INSTANCE_CUSTOM.w);
	float size = MODEL_MATRIX[0].x * (0.3 + 0.7 * sqrt(clamp(age, 0.0, 1.0)));
	if (age < 0.0 || age > 1.0) {
		size = 0.0;
	}
	vec3 wp = MODEL_MATRIX[3].xyz + vec3(MODEL_MATRIX[0].y * age_s, MODEL_MATRIX[1].x * age_s + size * 0.35, MODEL_MATRIX[0].z * age_s);
	float c = cos(INSTANCE_CUSTOM.x);
	float s = sin(INSTANCE_CUSTOM.x);
	mat4 rot = mat4(vec4(c, -s, 0.0, 0.0), vec4(s, c, 0.0, 0.0), vec4(0.0, 0.0, 1.0, 0.0), vec4(0.0, 0.0, 0.0, 1.0));
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], vec4(wp, 1.0));
	MODELVIEW_MATRIX = MODELVIEW_MATRIX * rot * mat4(vec4(size, 0.0, 0.0, 0.0), vec4(0.0, size, 0.0, 0.0), vec4(0.0, 0.0, size, 0.0), vec4(0.0, 0.0, 0.0, 1.0));
	MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);
}

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float r = length(p);
	float a = atan(p.y, p.x);
	float lump = 0.2 * sin(a * 3.0 + v_rnd * 40.0) + 0.12 * sin(a * 5.0 + v_rnd * 17.0);
	float m = 1.0 - smoothstep(0.0, 1.0, r * (1.0 + lump));
	m *= clamp(0.55 + 0.45 * sin(p.x * 4.5 + v_rnd * 9.0) * sin(p.y * 3.8 + v_rnd * 5.0)
			+ 0.25 * sin((p.x + p.y) * 7.0 + v_rnd * 21.0), 0.0, 1.0);
	float t = clamp(v_age, 0.0, 1.0);
	float fade = smoothstep(0.0, 0.12, t) * pow(1.0 - t, 1.5);
	float near = clamp((-VERTEX.z - 0.5) / max(near_fade_m, 0.01), 0.0, 1.0);
	vec3 col = mix(tint_a, tint_b, v_tint);
	ALBEDO = col;
	ALPHA = clamp(density * m * fade * near, 0.0, 1.0);
	BACKLIGHT = col * 0.5;
	ROUGHNESS = 1.0;
	NORMAL = vec3(0.0, 0.0, 1.0);
}
