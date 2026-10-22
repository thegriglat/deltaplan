// Снежный флаг (SnowPlumeRender): частицы идут по линии тока источника path/vel (SNW-К3).
// Положение считается аналитически от возраста (не интегрируется): Эрмитова интерполяция между точками
// path (шаг path_dt, скорости vel), плюс разлёт spread_ms·age (случайное направление по частице) и
// оседание −settle_ms·age по Y. Рождение — случайная точка на отрезке width_m поперёк ветра у path[0].
// CUSTOM: x — поворот, y — возраст 0…1, z — случайное число частицы. COLOR.a — intensity (прозрачность).
shader_type particles;
render_mode disable_force, disable_velocity;

uniform vec3 path[8];
uniform vec3 vel[8];
uniform int path_n = 2;
uniform float path_dt = 8.0;
uniform vec3 dir = vec3(1.0, 0.0, 0.0);
uniform float width_m = 150.0;
uniform float spread_ms = 1.0;
uniform float settle_ms = 0.3;
uniform float size_start = 2.0;
uniform float size_end = 20.0;
uniform float intensity = 1.0;

float rnd(inout uint s) {
	s = s * 747796405u + 2891336453u;
	uint w = ((s >> ((s >> 28u) + 4u)) ^ s) * 277803737u;
	return float((w >> 22u) ^ w) / 4294967295.0;
}

// положение на линии тока в возрасте age (0…1)
vec3 plume_at(float age) {
	int n = clamp(path_n, 2, 8);
	float u = clamp(age, 0.0, 1.0) * float(n - 1);
	int i = min(int(floor(u)), n - 2);
	float f = u - float(i);
	float f2 = f * f;
	float f3 = f2 * f;
	vec3 p0 = path[i];
	vec3 p1 = path[i + 1];
	vec3 m0 = vel[i] * path_dt;
	vec3 m1 = vel[i + 1] * path_dt;
	return (2.0 * f3 - 3.0 * f2 + 1.0) * p0 + (f3 - 2.0 * f2 + f) * m0
			+ (-2.0 * f3 + 3.0 * f2) * p1 + (f3 - f2) * m1;
}

vec3 place(float age, float r_lat, float r_a, float r_b) {
	vec3 d = vec3(dir.x, 0.0, dir.z);
	d = length(d) > 1e-4 ? normalize(d) : vec3(1.0, 0.0, 0.0);
	vec3 side = cross(d, vec3(0.0, 1.0, 0.0));
	float life_s = path_dt * float(max(path_n - 1, 1));
	float t = age * life_s;
	// разлёт: случайное направление в горизонтали и немного вверх-вниз
	float ang = r_a * 6.2832;
	vec3 sp = vec3(cos(ang), (r_b - 0.5) * 0.6, sin(ang)) * spread_ms * t * (0.4 + 0.6 * r_b);
	vec3 pos = plume_at(age) + side * (r_lat - 0.5) * width_m + sp - vec3(0.0, settle_ms * t, 0.0);
	return pos;
}

void start() {
	uint s = NUMBER * 9781u + RANDOM_SEED * 6271u + 1u;
	float r0 = rnd(s);
	float r1 = rnd(s);
	float r2 = rnd(s);
	float r3 = rnd(s);
	if (RESTART_POSITION) {
		TRANSFORM = mat4(1.0);
		TRANSFORM[3].xyz = place(0.0, r0, r1, r2);
	}
	if (RESTART_CUSTOM) {
		CUSTOM = vec4(r3 * 6.2832, 0.0, r0 * 0.37 + r1 * 0.63, 0.0);
	}
	VELOCITY = vec3(0.0);
	COLOR = vec4(1.0, 1.0, 1.0, intensity);
}

void process() {
	float life_s = path_dt * float(max(path_n - 1, 1));
	CUSTOM.y += DELTA / max(life_s, 0.01);
	if (CUSTOM.y >= 1.0) {
		ACTIVE = false;
	}
	uint s = uint(CUSTOM.z * 4294967.0) * 2654435761u + 7u;
	float r_lat = rnd(s);
	float r_a = rnd(s);
	float r_b = rnd(s);
	float age = clamp(CUSTOM.y, 0.0, 1.0);
	TRANSFORM[3].xyz = place(age, r_lat, r_a, r_b);
	float g = 1.0 - pow(1.0 - age, 2.0);
	float size = mix(size_start, size_end, g);
	TRANSFORM[0].xyz = vec3(size, 0.0, 0.0);
	TRANSFORM[1].xyz = vec3(0.0, size, 0.0);
	TRANSFORM[2].xyz = vec3(0.0, 0.0, size);
	COLOR.a = intensity;
	CUSTOM.x += DELTA * (CUSTOM.z - 0.5) * 0.3;
}
