// Частица снежного флага (SnowPlumeRender): billboard, мягкое белое пятно без текстуры. Прозрачность ∝
// intensity (COLOR.a частицы), плавно появляется и гаснет с возрастом (INSTANCE_CUSTOM.y); освещение —
// как smoke_puff (солнце, просвет BACKLIGHT, туман сцены); вблизи камеры растворяется.
shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, specular_disabled, diffuse_lambert_wrap, shadows_disabled;

uniform vec3 tint : source_color = vec3(0.96, 0.97, 1.0);
uniform float alpha = 0.5;
uniform float near_fade_m = 30.0;

varying float v_age;
varying float v_rnd;
varying float v_int;

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
	v_int = COLOR.a;
}

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float r = length(p);
	float a = atan(p.y, p.x);
	float lump = 0.15 * sin(a * 3.0 + v_rnd * 40.0) + 0.1 * sin(a * 5.0 + v_rnd * 17.0);
	float m = 1.0 - smoothstep(0.0, 1.0, r * (1.0 + lump));
	float t = clamp(v_age, 0.0, 1.0);
	float life = smoothstep(0.0, 0.12, t) * (1.0 - smoothstep(0.55, 1.0, t));
	float near = clamp((-VERTEX.z - 1.0) / max(near_fade_m, 0.01), 0.0, 1.0);
	ALBEDO = tint;
	ALPHA = clamp(alpha * v_int * m * life * near, 0.0, 1.0);
	BACKLIGHT = tint * 0.5;
	ROUGHNESS = 1.0;
	NORMAL = vec3(0.0, 0.0, 1.0);
}
