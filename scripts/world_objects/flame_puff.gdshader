// Язычок пламени костра (Campfire): billboard, светящийся, складывается (blend_add).
// Цвет по возрасту частицы (INSTANCE_CUSTOM.y от ParticleProcessMaterial): жёлтый → оранжевый →
// тёмно-красный и гаснет.
shader_type spatial;
render_mode blend_add, depth_draw_never, cull_disabled, unshaded, shadows_disabled;

uniform float intensity = 2.0;

varying float v_age;

void vertex() {
	MODELVIEW_MATRIX = VIEW_MATRIX
			* mat4(INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
	MODELVIEW_MATRIX = MODELVIEW_MATRIX
			* mat4(vec4(length(MODEL_MATRIX[0].xyz), 0.0, 0.0, 0.0),
					vec4(0.0, length(MODEL_MATRIX[1].xyz), 0.0, 0.0),
					vec4(0.0, 0.0, length(MODEL_MATRIX[2].xyz), 0.0), vec4(0.0, 0.0, 0.0, 1.0));
	v_age = INSTANCE_CUSTOM.y;
}

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	p.y *= 0.8;
	float m = 1.0 - smoothstep(0.1, 1.0, length(p));
	float t = clamp(v_age, 0.0, 1.0);
	vec3 col = mix(vec3(1.0, 0.85, 0.4), vec3(1.0, 0.4, 0.08), smoothstep(0.0, 0.5, t));
	col = mix(col, vec3(0.5, 0.08, 0.02), smoothstep(0.5, 1.0, t));
	float fade = smoothstep(0.0, 0.1, t) * (1.0 - t);
	ALBEDO = col * m * fade * intensity;
}
