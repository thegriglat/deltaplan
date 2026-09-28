// Дым костра (Campfire): частицы-клубы в мировых координатах. Скорость клуба тянется к
// «ветер + всплытие»: ветер — локальный из модели атмосферы (Atmosphere.air_velocity_at у костра,
// у земли и выше — по высоте клуба смешиваются), всплытие горячего дыма гаснет с возрастом и
// слабеет в сильный ветер (дым прижимает). Порывы — через обновление ветра, все клубы разом.
// CUSTOM: x — поворот, y — возраст (0…1), z — случайное число клуба.
shader_type particles;
render_mode disable_force;

uniform vec3 wind_low = vec3(0.0);
uniform vec3 wind_high = vec3(0.0);
uniform float wind_high_m = 30.0;
uniform float fire_y = 0.0;
uniform float rise_speed = 3.0;
uniform float rise_decay_s = 5.0;
uniform float rise_min = 0.3;
uniform float wind_damp = 0.1;
uniform float follow_s = 1.2;
uniform float turbulence = 0.5;
uniform float size_start = 0.3;
uniform float size_end = 6.0;
uniform float emit_radius = 0.25;

float rnd(inout uint s) {
	s = s * 747796405u + 2891336453u;
	uint w = ((s >> ((s >> 28u) + 4u)) ^ s) * 277803737u;
	return float((w >> 22u) ^ w) / 4294967295.0;
}

void start() {
	uint s = NUMBER * 9781u + RANDOM_SEED * 6271u + 1u;
	float r0 = rnd(s);
	float r1 = rnd(s);
	float r2 = rnd(s);
	float r3 = rnd(s);
	if (RESTART_POSITION) {
		vec3 p = vec3((r0 - 0.5) * 2.0 * emit_radius, 0.3, (r1 - 0.5) * 2.0 * emit_radius);
		mat4 local = mat4(
				vec4(size_start, 0.0, 0.0, 0.0), vec4(0.0, size_start, 0.0, 0.0),
				vec4(0.0, 0.0, size_start, 0.0), vec4(p, 1.0));
		TRANSFORM = EMISSION_TRANSFORM * local;
	}
	if (RESTART_VELOCITY) {
		VELOCITY = vec3(0.0, rise_speed, 0.0) + wind_low * 0.5;
	}
	if (RESTART_CUSTOM) {
		CUSTOM = vec4(r2 * 6.2832, 0.0, r3, 0.0);
	}
	COLOR = vec4(1.0);
}

void process() {
	CUSTOM.y += DELTA / LIFETIME;
	if (CUSTOM.y >= 1.0) {
		ACTIVE = false;
	}
	float age_s = CUSTOM.y * LIFETIME;
	vec3 pos = TRANSFORM[3].xyz;
	float k = clamp((pos.y - fire_y) / max(wind_high_m, 1.0), 0.0, 1.0);
	vec3 wind = mix(wind_low, wind_high, k);
	float u = length(wind.xz);
	float rise = (rise_min + rise_speed * exp(-age_s / rise_decay_s)) / (1.0 + wind_damp * u);
	float ph = CUSTOM.z * 40.0;
	vec3 turb = vec3(sin(age_s * 0.9 + ph), 0.5 * sin(age_s * 0.6 + ph * 1.7),
			cos(age_s * 0.8 + ph * 2.3)) * turbulence * (0.3 + 0.15 * u) * min(age_s * 0.3, 1.0);
	vec3 target = wind + vec3(0.0, rise, 0.0) + turb;
	VELOCITY = mix(VELOCITY, target, 1.0 - exp(-DELTA / max(follow_s, 0.01)));
	float g = 1.0 - pow(1.0 - clamp(CUSTOM.y, 0.0, 1.0), 2.2);
	float size = mix(size_start, size_end, g);
	TRANSFORM[0].xyz = vec3(size, 0.0, 0.0);
	TRANSFORM[1].xyz = vec3(0.0, size, 0.0);
	TRANSFORM[2].xyz = vec3(0.0, 0.0, size);
	CUSTOM.x += DELTA * (CUSTOM.z - 0.5) * 0.3;
}
