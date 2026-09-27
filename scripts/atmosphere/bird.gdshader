// Птица: машет крыльями по |x| (расстояние от оси тела). Параметры — на экземпляр MultiMesh:
// INSTANCE_CUSTOM.x — фаза 0..1, .y — амплитуда взмаха (0 — парит).
shader_type spatial;
render_mode cull_disabled, diffuse_lambert, specular_disabled;

uniform vec3 color : source_color = vec3(0.16, 0.11, 0.07);
uniform float flap_hz = 3.0;

void vertex() {
	float a = INSTANCE_CUSTOM.y * sin(TIME * flap_hz * TAU + INSTANCE_CUSTOM.x * TAU);
	VERTEX.y += abs(VERTEX.x) * a;
}

void fragment() {
	ALBEDO = color;
	ROUGHNESS = 0.9;
}
