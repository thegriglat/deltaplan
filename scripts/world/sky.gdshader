// Небо: градиент ProceduralSkyMaterial (зенит → горизонт, ореол солнца по sun_angle_max/sun_curve)
// плюс яркий диск солнца и корона в HDR — диск заметно ярче «белого» тонмаппинга, от него
// светится glow (world.json → effects), а засвет глаза рисует SunGlare (sun_glare.gdshader).
// В проходе кубической карты (окружение, отражения) диска и короны нет — освещение сцены
// остаётся как у ProceduralSkyMaterial.
// Параметры задаёт scripts/world/sky_environment.gd из configs/world.json → sky, sky.sun_disk.
shader_type sky;

uniform vec3 sky_top_color : source_color = vec3(0.23, 0.42, 0.75);
uniform vec3 sky_horizon_color : source_color = vec3(0.66, 0.76, 0.88);
uniform float sky_curve = 0.12;
uniform vec3 ground_bottom_color : source_color = vec3(0.25, 0.28, 0.24);
uniform vec3 ground_horizon_color : source_color = vec3(0.66, 0.76, 0.88);
uniform float ground_curve = 0.02;
uniform float sun_angle_max = 0.35;   // ореол ProceduralSky, радианы
uniform float sun_curve = 0.1;
uniform float exposure = 1.0;         // energy_multiplier
uniform vec3 sun_dir = vec3(0.0, 1.0, 0.0); // направление НА солнце
uniform vec3 sun_color : source_color = vec3(1.0);
uniform float halo_energy = 1.2;      // яркость солнца в ореоле ProceduralSky (как light_energy)
uniform float disk_radius = 0.0047;   // угловой радиус диска, радианы
uniform float disk_edge = 0.3;        // мягкость края диска, доля радиуса
uniform float disk_energy = 40.0;     // яркость диска (HDR), безразмерная
uniform float limb_darkening = 0.4;   // потемнение к краю диска
uniform float corona_energy = 3.0;    // яркость короны у края диска (HDR)
uniform float corona_width = 0.02;    // спад короны, радианы
// Ореол аэрозоля (HH-11): свет солнца, рассеянный вперёд дымкой (фаза Хеньи–Гринстейна).
// Яркость = disk_energy (уже с пропусканием по высоте солнца) × Ω диска × aureole_compression
// × (1 − e^−τ), τ = aureole_tau_vertical × воздушная масса (Kasten–Young по sun_dir):
// у горизонта путь по дымке в 10–20 раз длиннее — ореол растёт, диск не увеличивается.
// aureole_compression: настоящее солнце у горизонта в ~3·10⁴ раз ярче неба рядом, в игре
// (ограниченный HDR) — в ~10; без сжатия Ω·τ ≈ 10⁻⁴ даёт невидимый ореол. Подобрано по кадру.
uniform float aureole_compression = 2500.0;
uniform float aureole_tau_vertical = 0.2;  // оптическая толщина дымки по вертикали (30 км видимости × 1,5 км слоя)
uniform float clip_hdr = 1.0;              // яркость (HDR), выше которой каналы «пересвечены»: избыток белый, как у матрицы/глаза
uniform float aureole_g = 0.95;            // асимметрия рассеяния аэрозоля (острый пик вперёд)

float air_mass(float h_deg) {
	float h = max(h_deg, 0.0);
	return 1.0 / (sin(radians(h)) + 0.50572 * pow(h + 6.07995, -1.6364));
}

// Фаза Хеньи–Гринстейна, 1/ср (интеграл по сфере = 1).
float phase_hg(float cos_t, float g) {
	float d = 1.0 + g * g - 2.0 * g * cos_t;
	return (1.0 - g * g) / (4.0 * PI * pow(max(d, 1e-6), 1.5));
}

void sky() {
	vec3 d = EYEDIR;
	float v_angle = acos(clamp(d.y, -1.0, 1.0));
	float c = 1.0 - v_angle / (PI * 0.5);
	vec3 sky = mix(
		sky_horizon_color, sky_top_color, clamp(1.0 - pow(1.0 - c, 1.0 / sky_curve), 0.0, 1.0)
	);
	float a = acos(clamp(dot(normalize(sun_dir), d), -1.0, 1.0));
	vec3 sun = sun_color * halo_energy;
	if (a < disk_radius) {
		sky = sun;
	} else if (a < sun_angle_max) {
		float c2 = (a - disk_radius) / (sun_angle_max - disk_radius);
		sky = mix(sun, sky, clamp(1.0 - pow(1.0 - c2, 1.0 / sun_curve), 0.0, 1.0));
	}
	float cg = (v_angle - PI * 0.5) / (PI * 0.5);
	vec3 ground = mix(
		ground_horizon_color, ground_bottom_color,
		clamp(1.0 - pow(1.0 - cg, 1.0 / ground_curve), 0.0, 1.0)
	);
	vec3 col = mix(ground, sky, step(0.0, d.y)) * exposure;
	if (!AT_CUBEMAP_PASS) {
		float r = a / max(disk_radius, 1e-5);
		float edge = max(disk_edge, 1e-3);
		float disk = 1.0 - smoothstep(1.0 - edge, 1.0, r);
		float limb = 1.0 - limb_darkening * (1.0 - sqrt(max(1.0 - min(r, 1.0) * min(r, 1.0), 0.0)));
		float corona = corona_energy * exp(-max(a - disk_radius, 0.0) / max(corona_width, 1e-5));
		// под горизонтом диска нет (там земля/рельеф)
		float above = smoothstep(-0.01, 0.0, d.y);
		float el_deg = degrees(asin(clamp(normalize(sun_dir).y, -1.0, 1.0)));
		float tau = aureole_tau_vertical * air_mass(el_deg);
		float omega = PI * disk_radius * disk_radius;
		float aureole = disk_energy * omega * aureole_compression * (1.0 - exp(-tau)) * phase_hg(cos(a), aureole_g);
		float e = disk * limb * disk_energy + corona + aureole;
		// выше clip_hdr все каналы насыщены — избыток уходит в белый (форма и яркость, не оттенок)
		col += (sun_color * e + vec3(max(e - clip_hdr, 0.0))) * above;
	}
	COLOR = col;
}
