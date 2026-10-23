// Ослепление солнцем и каска поверх кадра (CanvasLayer, после 3D и облаков, до интерфейса).
// Параметры и логику задаёт scripts/world/sun_glare.gd (world.json → sun_glare, helmet.json).
//
// Глаз: засвет вокруг солнца (узкое ядро + широкое рассеяние), остальное темнеет — зрачок
// сужается. Засвет — свет, рассеянный в глазу/объективе: яркость ∝ освещённости от солнца (она же
// падает с высотой солнца — множитель glare = пропускание атмосферы, SkyEnvironment), форма —
// площадка ядра + хвост ∝ 1/θ² (Хоулдей–Стайлс: L_вуаль = 10·E/θ²). Складывается с кадром в линейном
// свете и не даёт каналам уйти в белый по отдельности: избыток делится на максимум канала (цвет
// сохраняется), поэтому у горизонта ядро — цвета солнца (пропускание атмосферы), а не белое. Диск
// (θ меньше ~1,6 радиуса) перекрашивается в цвет солнца: тонмаппинг по каналам выбеливает любой
// HDR-цвет ярче ~1,5, у настоящего солнца у горизонта R/G/B — как в sun_tint. Вокруг диска — только аддитивный засвет. Видимость солнца = sun_vis × (солнце в кадре ? доля светлых пикселей диска : cloud_vis):
//   sun_vis, cloud_vis — рельеф и облака лучами на процессоре (sun_glare.gd), сглажено во
//     времени; облака по лучу — упрощённый купол, поэтому только за краем кадра;
//   пиксели — пока солнце в кадре (on_screen): облака (точный край), крыло; пробы по кругу
//     диска с ореолом, каждая —
//     максимум яркости в крестике ±probe_px, поэтому тонкий трос (уже крестика) пробу не гасит,
//     а парус и трубы крыла гасят; полупрозрачный парус на солнце светлее порога «закрыто» —
//     засвет слабее, но не ноль.
// Углы — от настоящего направления пикселя (tan_half — полуполе зрения), поэтому засвет
// одинаков при любом fov. Кромка козырька и искажение визора — в долях кадра (у края всегда).
// Каска: 0 — нет, 1 — открытая (козырёк), 2 — прозрачный визор, 3 — тёмный визор.
shader_type canvas_item;
render_mode unshaded;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear, repeat_disable;
uniform vec2 tan_half = vec2(0.77, 0.577);   // tan половины поля зрения по x, y
uniform float aspect = 1.777;
uniform vec3 sun_view = vec3(0.0, 0.0, -1.0); // направление на солнце в осях камеры
uniform vec2 sun_uv = vec2(0.5);              // солнце на экране (может быть за краем)
uniform float sun_vis = 1.0;                  // не закрыто рельефом (лучи) 0..1
uniform float cloud_vis = 1.0;                // пропускание облаков по лучам 0..1
uniform float on_screen = 0.0;                // 1 — диск в кадре, пробовать пиксели
uniform vec2 probe_uv = vec2(0.005);          // радиус кольца проб (диск с ореолом)
uniform vec2 probe_px = vec2(0.0016, 0.0028); // полуразмер крестика максимума (тоньше — не закрывает)
uniform vec2 visible_luma = vec2(0.45, 0.93); // яркость пробы: закрыто / видно полностью
uniform float glare = 0.0;                    // сила ослепления (× время суток × визор)
uniform float darken = 0.0;                   // потемнение кадра при видимом солнце
uniform vec3 sun_color = vec3(1.0);  // цвета — в пространстве экрана (sRGB)
uniform float veil_core = 12.0;               // яркость площадки ядра засвета при glare = 1 (в долях белого)
uniform float veil_core_deg = 0.3;            // полуширина площадки ядра: 1/(1+(θ/θ0)²), градусы
uniform float veil_wide = 0.3;                // широкий хвост рассеяния в глазу, доля белого при glare = 1
uniform float veil_wide_deg = 8.0;            // полуширина хвоста: 1/(1+(θ/θ0)²), градусы
uniform float veil_flat = 0.05;               // засвет всего кадра (рассеяние в глазу)
uniform float disk_deg = 0.3;                 // угловой радиус диска, градусы (перекраска в цвет солнца)

uniform int helmet = 0;
uniform vec3 brim_color = vec3(0.03);
uniform float brim_height = 0.07;
uniform float brim_curve = 0.05;
uniform float brim_softness = 0.08;
uniform float brim_opacity = 0.8;
uniform float side_width = 0.06;
uniform float side_opacity = 0.3;
uniform float brim_sun_block = 0.9;
uniform vec3 visor_tint = vec3(1.0);
uniform float distortion = 0.01;
uniform float distortion_start = 0.35;
uniform float edge_tint = 0.08;
uniform float glass_veil = 0.25;
uniform float glass_veil_deg = 25.0;
uniform float streaks = 0.5;
uniform float streak_width = 0.004;
uniform float streak_length = 0.35;
uniform vec2 streak_angles = vec2(0.3, 1.8);
uniform float scratches = 0.6;
uniform float scratch_density = 7.0;
uniform float dust = 0.5;
uniform float dust_density = 26.0;
uniform float lit_deg = 35.0;

varying float v_vis;      // видимость солнца с учётом козырька (одна на кадр — в вершинах)
varying float v_vis_raw;  // диск виден по пикселям (без лучей рельефа и облаков): перекраска в цвет солнца

vec3 to_linear(vec3 c) {
	return mix(pow((c + 0.055) / 1.055, vec3(2.4)), c / 12.92, lessThanEqual(c, vec3(0.04045)));
}

vec3 to_srgb(vec3 c) {
	return mix(1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, c * 12.92, lessThanEqual(c, vec3(0.0031308)));
}

float luma(vec3 c) {
	return dot(c, vec3(0.2126, 0.7152, 0.0722));
}

// Яркость пробы (максимальный канал): максимум в крестике — тонкие тёмные линии (тросы) пропадают.
float probe(vec2 uv) {
	float l = 0.0;
	vec2 o[5] = vec2[](vec2(0.0), vec2(1.0, 0.0), vec2(-1.0, 0.0), vec2(0.0, 1.0), vec2(0.0, -1.0));
	for (int i = 0; i < 5; i++) {
		vec2 q = clamp(uv + o[i] * probe_px, vec2(0.0), vec2(1.0));
		vec3 c = textureLod(screen_tex, q, 0.0).rgb;
		l = max(l, max(c.r, max(c.g, c.b)));  // по максимальному каналу: красный диск у горизонта (яркость по Y мала) — виден
	}
	return smoothstep(visible_luma.x, visible_luma.y, l);
}

// Непрозрачность козырька в точке экрана uv (0 сверху .. 1 снизу), 0..1.
float brim_mask(vec2 uv) {
	if (helmet == 0) {
		return 0.0;
	}
	float x = uv.x * 2.0 - 1.0;
	float edge = brim_height + brim_curve * x * x;
	float top = 1.0 - smoothstep(edge - brim_softness, edge + brim_softness * 0.5, uv.y);
	return top * brim_opacity;
}

float side_mask(vec2 uv) {
	if (helmet == 0) {
		return 0.0;
	}
	float d = min(uv.x, 1.0 - uv.x) / max(side_width, 1e-4);
	return (1.0 - smoothstep(0.0, 1.0, d)) * side_opacity;
}

vec2 hash2(vec2 p) {
	p = vec2(dot(p, vec2(127.1, 311.7)), dot(p, vec2(269.5, 183.3)));
	return fract(sin(p) * 43758.5453);
}

float hash1(vec2 p) {
	return fract(sin(dot(p, vec2(41.3, 289.1))) * 15731.743);
}

// Царапины: в каждой клетке сетки — отрезок случайного направления; блестят те, что поперёк
// направления на солнце (как на настоящем стекле — круг бликов вокруг солнца).
float scratch_field(vec2 p, vec2 sun_p, float px) {
	vec2 cell = floor(p);
	float s = 0.0;
	for (int j = -1; j <= 1; j++) {
		for (int i = -1; i <= 1; i++) {
			vec2 c = cell + vec2(float(i), float(j));
			vec2 h = hash2(c);
			float r = hash1(c + 7.1);
			if (r < 0.45) {
				continue;
			}
			vec2 o = c + h;
			float ang = hash1(c + 3.7) * 3.14159;
			vec2 t = vec2(cos(ang), sin(ang));
			float half_len = 0.25 + 0.6 * hash1(c + 1.3);
			vec2 q = p - o;
			float along = clamp(dot(q, t), -half_len, half_len);
			float dist = length(q - t * along);
			float line = 1.0 - smoothstep(0.0, px * 1.5, dist);
			vec2 rad = normalize(o - sun_p + vec2(1e-4));
			float glint = pow(1.0 - abs(dot(t, rad)), 6.0);
			s += line * glint * (0.4 + 0.6 * r);
		}
	}
	return s;
}

// Пылинки: мягкие точки в части клеток сетки.
float dust_field(vec2 p, float px) {
	vec2 cell = floor(p);
	vec2 h = hash2(cell + 11.0);
	if (hash1(cell + 5.5) < 0.55) {
		return 0.0;
	}
	vec2 o = cell + 0.15 + 0.7 * h;
	float r = px * (1.0 + 2.5 * hash1(cell + 2.2));
	return (1.0 - smoothstep(r * 0.3, r, length(p - o))) * (0.3 + 0.7 * h.x);
}

void vertex() {
	float px = 1.0;
	if (on_screen > 0.0) {
		// центр, кольцо из 6 на половине радиуса и из 6 на радиусе (со сдвигом)
		float acc = probe(sun_uv);
		for (int i = 0; i < 6; i++) {
			float a = float(i) * 1.0472;
			acc += probe(sun_uv + vec2(cos(a), sin(a)) * probe_uv * 0.5);
			acc += probe(sun_uv + vec2(cos(a + 0.5236), sin(a + 0.5236)) * probe_uv);
		}
		px = acc / 13.0;
	}
	v_vis = sun_vis * mix(cloud_vis, px, on_screen);
	// солнце за козырьком не слепит
	v_vis *= 1.0 - brim_sun_block * brim_mask(sun_uv) / max(brim_opacity, 1e-3);
	// диск перекрашивается там, где его видно по пикселям (рельеф и облака — в самих пикселях),
	// без лучей по кольцу 1° вокруг: хребет у горизонта режет кольцо, а диск над ним виден целиком
	v_vis_raw = px * on_screen * (1.0 - brim_sun_block * brim_mask(sun_uv) / max(brim_opacity, 1e-3));
}

void fragment() {
	vec2 uv = SCREEN_UV;
	vec2 suv = uv;
	bool visor = helmet >= 2;
	float rk = 0.0;
	if (visor) {
		vec2 c = (uv - 0.5) * vec2(aspect, 1.0);
		float r = length(c) / length(vec2(aspect, 1.0) * 0.5);
		rk = smoothstep(distortion_start, 1.0, r);
		suv = uv - (uv - 0.5) * distortion * rk * rk * 2.0;
	}
	vec3 col = textureLod(screen_tex, suv, 0.0).rgb;
	if (visor) {
		col *= visor_tint * (1.0 - edge_tint * rk);
	}
	// направление пикселя и угол до солнца
	vec3 pdir = normalize(vec3((uv.x * 2.0 - 1.0) * tan_half.x, (1.0 - uv.y * 2.0) * tan_half.y, -1.0));
	float th = degrees(acos(clamp(dot(pdir, normalize(sun_view)), -1.0, 1.0)));
	float I = glare * v_vis;
	// сжатие зрачка гасит весь кадр (без исключений вокруг солнца: пересвет ниже и так добавляется поверх)
	col *= 1.0 - darken * I;
	float veil = I * (
		veil_core / (1.0 + pow(th / max(veil_core_deg, 1e-3), 2.0))
		+ veil_wide / (1.0 + pow(th / max(veil_wide_deg, 1e-3), 2.0))
		+ veil_flat
	);
	if (visor) {
		float lit = I * exp(-pow(th / max(lit_deg, 1e-3), 2.0));
		veil += I * glass_veil / (1.0 + pow(th / max(glass_veil_deg, 1e-3), 2.0));
		// в единицах высоты кадра (без растяжения по ширине)
		vec2 p = uv * vec2(aspect, 1.0);
		vec2 sp = sun_uv * vec2(aspect, 1.0);
		float px = SCREEN_PIXEL_SIZE.y;  // пиксель в долях высоты кадра
		float g = 0.0;
		vec2 q = p - sp;
		for (int i = 0; i < 2; i++) {
			float a = i == 0 ? streak_angles.x : streak_angles.y;
			vec2 d = vec2(cos(a), -sin(a));
			float perp = abs(q.x * d.y - q.y * d.x);
			float along = abs(dot(q, d));
			// вторая полоса — тоньше и слабее (следы протирки разной силы)
			float w = streak_width * (i == 0 ? 1.0 : 0.5);
			float amp = i == 0 ? 1.0 : 0.5;
			g += amp * exp(-pow(perp / max(w, 1e-5), 2.0)) * exp(-along / max(streak_length, 1e-4));
		}
		veil += I * streaks * g;
		float sc = scratch_field(p * scratch_density, sp * scratch_density, px * scratch_density);
		float du = dust_field(p * dust_density, px * dust_density);
		veil += lit * (scratches * sc + dust * du);
	}
	// линейный свет: цвет солнца с R = 1 (отношения каналов — sun_tint)
	vec3 tint = to_linear(sun_color);
	tint /= max(max(tint.r, tint.g), max(tint.b, 1e-6));
	vec3 lin = to_linear(col);
	lin += veil * tint;
	lin /= max(1.0, max(max(lin.r, lin.g), lin.b));
	// Диск — самая яркая точка кадра у солнца (HH-15, Q6 а): у красного диска Y = Y(tint) мала, а небо, сложенное с засветом,
	// даёт рядом пиксель (R = 1, G и B выше, чем у диска) со светлотой выше диска. Там, где ядро засвета доминирует
	// (вес w = 1 − exp(−ядро/0,02): ≈1 в пределах ~1,5° от диска, к 7° ≈0,2), G и B масштабируются так, чтобы Y не выше 0,97·Y(tint);
	// R не меняется (размер насыщенного пятна — прежний). Дальше от солнца и в сцене вне засвета ничего не меняется.
	float core = I * veil_core / (1.0 + pow(th / max(veil_core_deg, 1e-3), 2.0));
	float w_cap = 1.0 - exp(-core / 0.02);
	float y_t = 0.97 * dot(tint, vec3(0.2126, 0.7152, 0.0722));  // 3 % запаса: диск после размытия кадром не темнее ореола
	float y_l = dot(lin, vec3(0.2126, 0.7152, 0.0722));
	if (y_l > y_t && y_l > 0.2126 * lin.r + 1.0e-6) {
		lin.gb *= mix(1.0, (y_t - 0.2126 * lin.r) / (y_l - 0.2126 * lin.r), w_cap);
	}
	// Диск (видимый по пробам: не закрыт рельефом и облаками) — цвет солнца sun_tint с яркостью 1: тонмаппинг по каналам
	// выбеливает яркий красный HDR, а у настоящего солнца у горизонта R/G/B — как в sun_tint; солнце самое яркое в кадре.
	// Только диск (θ < 1,6 радиуса): ореол — аддитивный засвет выше (veil · tint), сцена вокруг солнца цвет сохраняет
	// (HH-15, доработка 3: перекраски окна вокруг солнца нет).
	if (glare > 1.0e-6 && v_vis_raw > 0.0) {
		float wd = (1.0 - smoothstep(0.8 * disk_deg, 1.6 * disk_deg, th)) * clamp(2.0 * v_vis_raw, 0.0, 1.0);
		lin = mix(lin, tint, wd);
	}
	col = to_srgb(lin);
	// козырёк и края каски — ближе всего к глазу, поверх всего
	col = mix(col, brim_color, brim_mask(uv));
	col *= 1.0 - side_mask(uv);
	COLOR = vec4(col, 1.0);
}
