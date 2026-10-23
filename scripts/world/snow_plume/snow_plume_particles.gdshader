// Струйки снежной пыли (SnowPlumeRender, SNW-К3 v3): позёмка у поверхности и над гребнем.
// Рождение — случайная точка в оболочке точек surf (uniform surf[8], surf_n) на высоте layer_h·r² над рельефом
// (r² — гуще у поверхности). Движение интегрируется по кадрам: скорость — vel вдоль path по времени жизни
// (у гребня — местный ветер), горизонтальная часть × логарифмический профиль ln(z/z0)/ln(10/z0) (Pomeroy 1989),
// z — высота над поверхностью в точке рождения (не меньше 0,05 м); плюс оседание settle_ms и разлёт spread_ms.
// Штрих: TRANSFORM[0] = направление скорости × длина, TRANSFORM[1] — поперечная ось × ширина.
// CUSTOM: x — 0, y — возраст 0…1, z — случайное число частицы, w — высота поверхности в точке рождения.
shader_type particles;
render_mode disable_force, disable_velocity;

uniform vec3 surf[8];
uniform int surf_n = 2;
uniform vec3 vel[8];
uniform int path_n = 2;
uniform float path_dt = 1.0;
uniform float layer_h_m = 2.0;
uniform float life_s = 2.0;
uniform float streak_len_m = 3.5;
uniform float streak_w_m = 0.25;
uniform float spread_ms = 0.6;
uniform float settle_ms = 0.2;
uniform float intensity = 1.0;
uniform float z0_m = 0.0015;

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
	float r4 = rnd(s);
	int n = clamp(surf_n, 1, 8);
	int a = min(int(r0 * float(n)), n - 1);
	int b = min(int(r1 * float(n)), n - 1);
	vec3 p = mix(surf[a], surf[b], r2);
	float zb = layer_h_m * r3 * r3;
	if (RESTART_POSITION) {
		TRANSFORM = mat4(1.0);
		TRANSFORM[3].xyz = p + vec3(0.0, zb, 0.0);
	}
	if (RESTART_CUSTOM) {
		CUSTOM = vec4(0.0, 0.0, r4, p.y);
	}
	VELOCITY = vec3(1.0, 0.0, 0.0);
	COLOR = vec4(1.0, 1.0, 1.0, intensity);
}

void process() {
	float life = max(life_s, 0.05);
	CUSTOM.y += DELTA / life;
	if (CUSTOM.y >= 1.0) {
		ACTIVE = false;
	}
	float t = CUSTOM.y * life;
	uint s = uint(CUSTOM.z * 4294967.0) * 2654435761u + 7u;
	float r_a = rnd(s);
	float r_b = rnd(s);
	int n = clamp(path_n, 2, 8);
	float u = clamp(t / max(path_dt, 0.01), 0.0, float(n - 1));
	int i = min(int(floor(u)), n - 2);
	vec3 w = mix(vel[i], vel[i + 1], u - float(i));
	float z = max(TRANSFORM[3].y - CUSTOM.w, 0.05);
	float k = clamp(log(z / z0_m) / log(10.0 / z0_m), 0.0, 1.5);
	float ang = r_a * 6.2832;
	vec3 sp = vec3(cos(ang), (r_b - 0.5) * 0.6, sin(ang)) * spread_ms * (0.4 + 0.6 * r_b);
	vec3 v = vec3(w.x * k, w.y, w.z * k) + sp;
	if (z > 0.06) {
		v.y -= settle_ms;
	} else if (v.y < 0.0) {
		v.y = 0.0;
	}
	TRANSFORM[3].xyz += v * DELTA;
	VELOCITY = v;
	float sp_len = length(v);
	vec3 ax = sp_len > 0.01 ? v / sp_len : vec3(1.0, 0.0, 0.0);
	vec3 pe = cross(ax, vec3(0.0, 1.0, 0.0));
	pe = length(pe) > 1e-3 ? normalize(pe) : vec3(0.0, 0.0, 1.0);
	TRANSFORM[0].xyz = ax * streak_len_m;
	TRANSFORM[1].xyz = pe * streak_w_m;
	TRANSFORM[2].xyz = cross(ax, pe);
	COLOR.a = intensity;
}
