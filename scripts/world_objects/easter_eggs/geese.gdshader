shader_type spatial;
render_mode cull_disabled, shadows_disabled;
// Клин гусей (EE-6): взмах крыльев по abs(VERTEX.x) (К13). Чистая картинка: TIME — реальное
// время, фаза у каждой птицы своя (INSTANCE_CUSTOM.x, доля периода).
uniform float half_span = 0.8;
uniform float body_x = 0.12;
uniform float flap_hz = 3.0;
uniform float amp_frac = 0.35;   // размах взмаха кончика, доля полуразмаха
uniform float tip_lag = 1.1;     // отставание фазы кончика, рад
uniform vec3 tint = vec3(1.0);

void vertex() {
	float ax = abs(VERTEX.x);
	float w = clamp((ax - body_x) / max(half_span - body_x, 0.01), 0.0, 1.0);
	float ph = (TIME * flap_hz + INSTANCE_CUSTOM.x) * 6.2831853 - tip_lag * w;
	VERTEX.y += sin(ph) * amp_frac * half_span * w * w;
	// при взмахе крыло чуть подтягивается к телу
	VERTEX.x -= sign(VERTEX.x) * (1.0 - cos(amp_frac * sin(ph) * w)) * half_span * 0.5;
}

void fragment() {
	ALBEDO = COLOR.rgb * tint;
	ROUGHNESS = 0.9;
}
