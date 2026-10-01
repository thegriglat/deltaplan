// Клуб пыли УАЗика (копия smoke_puff для пасхалки uaz: плотный у колёс — без плавного входа): billboard, мягкий комок с неровным краем — без текстуры.
// Освещается солнцем (просвет — BACKLIGHT), туман сцены — как у всего мира. Прозрачность гаснет
// с возрастом клуба (INSTANCE_CUSTOM.y) — дым тает с высотой; вблизи камеры клуб растворяется.
shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, specular_disabled, diffuse_lambert_wrap, shadows_disabled;

uniform vec3 tint : source_color = vec3(0.84, 0.87, 0.92);
uniform float density = 0.22;
uniform float near_fade_m = 4.0;

varying float v_age;
varying float v_rnd;

void vertex() {
	float c = cos(INSTANCE_CUSTOM.x);
	float s = sin(INSTANCE_CUSTOM.x);
	mat4 rot = mat4(vec4(c, -s, 0.0, 0.0), vec4(s, c, 0.0, 0.0), vec4(0.0, 0.0, 1.0, 0.0),
			vec4(0.0, 0.0, 0.0, 1.0));
	MODELVIEW_MATRIX = VIEW_MATRIX
			* mat4(INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
	MODELVIEW_MATRIX = MODELVIEW_MATRIX * rot
			* mat4(vec4(length(MODEL_MATRIX[0].xyz), 0.0, 0.0, 0.0),
					vec4(0.0, length(MODEL_MATRIX[1].xyz), 0.0, 0.0),
					vec4(0.0, 0.0, length(MODEL_MATRIX[2].xyz), 0.0), vec4(0.0, 0.0, 0.0, 1.0));
	MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);
	v_age = INSTANCE_CUSTOM.y;
	v_rnd = INSTANCE_CUSTOM.z;
}

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float r = length(p);
	float a = atan(p.y, p.x);
	float lump = 0.2 * sin(a * 3.0 + v_rnd * 40.0) + 0.12 * sin(a * 5.0 + v_rnd * 17.0);
	float m = 1.0 - smoothstep(0.0, 1.0, r * (1.0 + lump));
	// клочья: пятна внутри, прозрачные дыры — не комок ваты
	m *= clamp(0.55 + 0.45 * sin(p.x * 4.5 + v_rnd * 9.0) * sin(p.y * 3.8 + v_rnd * 5.0)
			+ 0.25 * sin((p.x + p.y) * 7.0 + v_rnd * 21.0), 0.0, 1.0);
	float t = clamp(v_age, 0.0, 1.0);
	float life = smoothstep(0.0, 0.03, t) * pow(1.0 - t, 1.3);
	float near = clamp((-VERTEX.z - 0.5) / max(near_fade_m, 0.01), 0.0, 1.0);
	ALBEDO = tint;
	ALPHA = clamp(density * m * life * near, 0.0, 1.0);
	BACKLIGHT = tint * 0.5;
	ROUGHNESS = 1.0;
	NORMAL = vec3(0.0, 0.0, 1.0);
}
