// Птица: машет крыльями по |x| (расстояние от оси тела). Параметры — на экземпляр MultiMesh:
// INSTANCE_CUSTOM.x — фаза 0..1, .y — амплитуда взмаха (0 — парит).
shader_type spatial;
render_mode cull_disabled, diffuse_lambert, specular_disabled;

uniform vec3 color : source_color = vec3(0.16, 0.11, 0.07);
uniform float flap_hz = 3.0;
// Минимальный размах птицы на экране, px (QL-8): вдали модель растёт до него, вблизи — реальный размер.
uniform float min_span_px = 5.0;
// Размах модели в метрах до масштаба экземпляра (aabb.x меша).
uniform float model_span_m = 1.6;

void vertex() {
	float a = INSTANCE_CUSTOM.y * sin(TIME * flap_hz * TAU + INSTANCE_CUSTOM.x * TAU);
	VERTEX.y += abs(VERTEX.x) * a;
	// Размер в пикселях: span / расстояние * (H/2) / tan(fov/2); P[1][1] = 1/tan(fov/2).
	float dist = max(length((MODELVIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz), 1.0);
	float span_m = model_span_m * length(MODEL_MATRIX[0].xyz);
	float px = span_m / dist * 0.5 * VIEWPORT_SIZE.y * abs(PROJECTION_MATRIX[1][1]);
	VERTEX *= max(1.0, min_span_px / max(px, 1.0e-4));
}

void fragment() {
	ALBEDO = color;
	ROUGHNESS = 0.9;
}
