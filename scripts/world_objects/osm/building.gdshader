// Стены домов (OL-1, контракт L2, docs/contracts/osm-look.md): коробка 1×1×1, масштаб экземпляра = размеры дома.
// Всё в шейдере, геометрия не растёт: плоская крыша своим цветом, окна по этажам, стекло, профлист, затемнение у земли.
// Данные экземпляра (BuildingPlacer.place):
//   COLOR.rgb (INSTANCE_COLOR) — цвет стен (линейный);
//   COLOR.a × 32 = стиль + 4 × стекло + 8 × индекс цвета плоской крыши (стиль: 0 город, 1 село, 2 промзона;
//   индекс 0..3 в палитре стиля, roof_pal[стиль × 4 + индекс]) — целое/32, точно в половинной точности;
//   зерно разброса окон — из положения экземпляра (MODEL_MATRIX[3]), отдельных данных не нужно.
// (Данные экземпляра лежат в альфе цвета, а не в INSTANCE_CUSTOM: set_instance_custom_data на 280 тыс. домов
// стоил бы ≈ 0,1 с построения.)
// Высота дома — длина оси Y матрицы модели (стена уходит в землю на sink_m и на перепад склона).
shader_type spatial;
render_mode specular_schlick_ggx;

uniform vec4 roof_pal[12];
uniform vec3 window_dark = vec3(0.01, 0.015, 0.03);
uniform vec3 window_light = vec3(0.2, 0.3, 0.45);
uniform vec3 glass = vec3(0.07, 0.17, 0.26);
uniform float floor_m = 3.0;
uniform float sink_m = 0.5;
uniform float ground_dark = 0.45;
uniform float ground_h_m = 1.0;
uniform float window_fade_m = 1100.0;

varying vec3 v_m;       // положение на доме, м от центра коробки
varying vec3 v_size;    // размеры дома, м
varying vec3 v_n;       // нормаль в осях коробки
// flat: данные экземпляра не интерполируются (иначе целое 8.0 приходит как 7.9999 — рябь на плоских крышах)
varying flat float v_code;
varying flat float v_seed;
varying float v_depth;

float hash13(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.zyx + 31.32);
	return fract((p.x + p.y) * p.z);
}

// маска прямоугольника в ячейке (0..1)²: центр cx, cy, полуразмеры hx, hy; aa — сглаживание в долях ячейки
float rect(vec2 f, vec2 c, vec2 h, vec2 aa) {
	vec2 d = abs(f - c) - h;
	vec2 m = 1.0 - smoothstep(-aa, aa, d);
	return m.x * m.y;
}

void vertex() {
	v_size = vec3(length(MODEL_MATRIX[0].xyz), length(MODEL_MATRIX[1].xyz), length(MODEL_MATRIX[2].xyz));
	v_m = VERTEX * v_size;
	v_n = NORMAL;
	v_code = floor(COLOR.a * 32.0 + 0.5);
	v_seed = fract(sin(dot(MODEL_MATRIX[3].xz, vec2(12.9898, 78.233))) * 43758.5453);
	v_depth = -(MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).z;
}

void fragment() {
	float code = floor(v_code + 0.5);
	float ri = floor(code / 8.0);
	float rem = code - 8.0 * ri;
	float glass_f = step(4.0, rem);
	float style = rem - 4.0 * glass_f;
	float seed = v_seed;
	int roof_i = int(style) * 4 + int(ri);
	float h_ground = v_m.y + 0.5 * v_size.y - sink_m;  // высота над землёй, м
	vec3 wall = COLOR.rgb;
	vec3 col = wall;
	float rough = 0.9;
	float metal = 0.0;
	vec3 emit = vec3(0.0);
	// производные — до ветвлений (внутри ветвей fwidth по соседним пикселям даёт мусор)
	float dx = fwidth(v_m.x);
	float dz = fwidth(v_m.z);
	float dy = fwidth(h_ground);
	float near = 1.0 - smoothstep(0.55 * window_fade_m, window_fade_m, v_depth);

	if (v_n.y > 0.5) {
		// крыша: плоская — цвет палитры стиля; у промзоны швы профлиста
		vec3 rc = roof_pal[roof_i].rgb;
		rc *= 0.94 + 0.12 * seed;
		if (style > 1.5) {
			rc *= 0.93 + 0.07 * sin(v_m.x * 9.0 + v_m.z * 0.0);
		}
		col = rc;
		rough = 0.8;
	} else if (v_n.y > -0.5) {
		bool along_x = abs(v_n.x) > 0.5;
		float u = along_x ? v_m.z : v_m.x;
		float len = along_x ? v_size.z : v_size.x;
		float face = along_x ? (v_n.x > 0.0 ? 1.0 : 2.0) : (v_n.z > 0.0 ? 3.0 : 4.0);
		float nfl = max(1.0, round((v_size.y - sink_m) / floor_m));
		float fy = h_ground / floor_m;
		float fl = floor(fy);
		float ff = fract(fy);
		float aa_y = dy / floor_m + 0.001;
		if (style < 0.5) {
			if (glass_f > 0.5) {
				// сплошное стекло: переплёты по этажам и через 1,5 м, отражение неба по Френелю
				float mull = smoothstep(0.0, 0.05 + aa_y, ff) * smoothstep(0.0, 0.05 + aa_y, 1.0 - ff);
				float fu = fract((u + 0.5 * len) / 1.5);
				float aa_g = (along_x ? dz : dx) / 1.5;
				float vm = smoothstep(0.0, 0.04 + aa_g, fu) * smoothstep(0.0, 0.04 + aa_g, 1.0 - fu);
				float k = mix(1.0, mull * vm, near);
				float tone = 0.85 + 0.3 * hash13(vec3(floor((u + 0.5 * len) / 1.5), fl, face + seed * 17.0));
				col = glass * tone * mix(1.0, k, 0.8);
				metal = 0.5;
				rough = 0.12;
				float fres = pow(1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0), 3.0);
				emit = vec3(0.35, 0.5, 0.7) * (0.06 + 0.25 * fres);
			} else {
				// сетка окон: шаг ≈ 3 м по ширине, этаж floor_m
				float ncol = max(1.0, floor(len / 3.0));
				float pitch = len / ncol;
				float cu = (u + 0.5 * len) / pitch;
				float ci = floor(cu);
				float fu = fract(cu);
				float aa_u = (along_x ? dz : dx) / pitch + 0.001;
				float win = rect(vec2(fu, ff), vec2(0.5, 0.52), vec2(0.5 * min(1.5 / pitch, 0.7), 0.24), vec2(aa_u, aa_y));
				// первый этаж без окон у самой земли, верхний этаж под кровлей — окна как у всех
				float hs = hash13(vec3(ci, fl, face + seed * 31.0));
				vec3 wc = hs > 0.72 ? window_light * (0.7 + 0.6 * hs) : mix(window_dark, window_light, hs * 0.5);
				win *= near * (1.0 - smoothstep(0.25, 0.6, max(aa_u, aa_y)));
				col = mix(wall, wc, win);
				rough = mix(0.9, 0.15, win);
				metal = win * 0.2;
				// межэтажные пояса чуть темнее
				col *= 1.0 - 0.06 * smoothstep(0.1, 0.0, ff) * near;
			}
		} else if (style < 1.5) {
			// село: 1–2 небольших окна на стену на этаж
			float ncol = len < 6.5 ? 1.0 : 2.0;
			float pitch = len / ncol;
			float cu = (u + 0.5 * len) / pitch;
			float ci = floor(cu);
			float fu = fract(cu);
			float aa_u = (along_x ? dz : dx) / pitch + 0.001;
			float win = rect(vec2(fu, ff), vec2(0.5, 0.5), vec2(0.5 * min(1.1 / pitch, 0.6), 0.2), vec2(aa_u, aa_y));
			float hs = hash13(vec3(ci, fl, face + seed * 31.0));
			win *= step(0.12, hs) * near * (1.0 - smoothstep(0.25, 0.6, max(aa_u, aa_y)));
			col = mix(wall, mix(window_dark, window_light, hs * 0.4), win);
			rough = mix(0.9, 0.2, win);
		} else {
			// промзона: профлист — вертикальные рёбра, без окон
			float rib = 0.5 + 0.5 * sin(u * 18.0);
			col = wall * (0.9 + 0.1 * mix(0.5, rib, near));
			rough = 0.6;
			metal = 0.1;
		}
		// затемнение у земли
		col *= mix(1.0 - ground_dark, 1.0, smoothstep(0.0, ground_h_m, h_ground));
	} else {
		col = wall * 0.5;
	}
	ALBEDO = col;
	ROUGHNESS = rough;
	METALLIC = metal;
	EMISSION = emit;
}
