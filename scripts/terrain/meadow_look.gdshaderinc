// Цвет луга, общий для рельефа (terrain.gdshader) и травинок (grass.gdshader): палитра и сухость
// локации, влажность и экспозиция из полей рельефа (TerrainRelief), пятна с высоты (meadow_macro:
// оттенок/яркость, выгоревшие пятна, покосы). Травинки берут цвет земли под собой — вблизи и
// вдали луг одного тона, трава бесшовно переходит в землю. Нужен terrain_common.gdshaderinc.

// --- поля рельефа (TerrainRelief, считаются из DEM при загрузке): R — влажность, G — AO,
// B — сглаженная северность (тень рельефа relief_shadow_tex — в terrain.gdshader) ---
uniform bool use_relief = false;
uniform sampler2D relief_tex : filter_linear, repeat_disable;
uniform vec2 relief_origin;
uniform float relief_cell_m = 50.0;
uniform vec2 relief_texels = vec2(1.0);
uniform float wet_dry_k = 0.35;          // сдвиг сухости луга влажностью (ложбины сочнее, гребни суше)
uniform float wet_dark = 0.08;           // сухие выпуклости светлее (доля яркости; ложбины — wet_bright)
uniform float wet_green = 0.45;          // ложбины зеленее (к сочному grass_color)
uniform float wet_bright = 0.0;          // яркость сырых ложбин (доля; 0 — как вокруг, < 0 — темнее)
uniform float wet_sat = 1.5;             // насыщенность сочной травы ложбин (1 — как grass_color)
uniform float aspect_dry_k = 0.2;        // южные склоны степнее, северные зеленее (сглаженная экспозиция)

// --- пятна лугов с высоты (terrain_look: macro_*, burn_*, mow_*): многомасштабные неподвижные
// пятна оттенка «сочнее ↔ суше» и яркости 20 м … 1–2 км, выгоревшие пятна, полосы покоса ---
uniform vec4 macro_scales_m = vec4(22.0, 80.0, 280.0, 1100.0);   // масштабы пятен, м
uniform vec4 macro_weights = vec4(0.18, 0.3, 0.3, 0.22);         // вклад каждого масштаба
uniform float macro_hue = 0.5;         // сдвиг оттенка к сочной/сухой траве (доля смешения)
uniform float macro_bright = 0.14;     // разброс яркости пятнами (доля)
uniform float macro_wet_k = 0.35;      // влажность смещает пятна к сочным (ложбины) / сухим (гребни)
uniform vec2 macro_near_m = vec2(90.0, 220.0);  // мелкие масштабы и покос проявляются с этого расстояния, м
uniform float burn_share = 0.12;       // доля выгоревших пятен
uniform float burn_strength = 0.55;    // сила выгорания (к соломе)
uniform float mow_share = 0.3;         // доля покосов на пологих сырых днищах долин
uniform vec2 mow_cell_m = vec2(190.0, 120.0);  // размер покоса, м
uniform float mow_row_m = 8.0;         // шаг валков/проходов косилки, м
uniform float mow_strength = 0.16;     // контраст полос покоса
uniform float mow_max_slope_deg = 9.0; // покосы — только на пологом

// Бесшовная текстура плавного шума (4 независимых канала, пятно = MACRO_NOISE_FEATURE текселей,
// мипмапы; TerrainRenderer.macro_noise_texture) — дешевле хешей и сама гасит пятна мельче пикселя.
uniform sampler2D macro_noise_tex : filter_linear_mipmap, repeat_enable;
const float MACRO_NOISE_FEATURE = 16.0;   // = TerrainRenderer.MACRO_NOISE_FEATURE
const float MACRO_NOISE_SIZE = 256.0;     // = TerrainRenderer.MACRO_NOISE_SIZE

// Шум с пятнами размера s, м (4 канала 0..1), в точке q; foot — след пикселя, м (выбор мипа,
// +0,5 уровня — без мерцания пятен в пару пикселей).
vec4 macro_tex(vec2 q, float s, float foot) {
	float lod = log2(max(foot * MACRO_NOISE_SIZE / (MACRO_NOISE_FEATURE * s), 1e-3)) + 0.5;
	return textureLod(macro_noise_tex, q / (s * MACRO_NOISE_FEATURE), lod);
}

// Поджать шум: пятна с внятным краем (не «мыло»), −0.5..0.5.
float macro_shape(float n) {
	return smoothstep(0.22, 0.78, n) - 0.5;
}

// Пятна луга с высоты. c — цвет луга, wet — влажность −1..1, dist — до камеры, м;
// flat_k — 1 на пологом открытом лугу (покосы). Возвращает новый цвет.
vec3 meadow_macro(vec2 p, vec3 c, float foot, float wet, float dist, float flat_k) {
	const vec3 L = vec3(0.2126, 0.7152, 0.0722);
	float lum = dot(c, L);
	float near_k = smoothstep(macro_near_m.x, macro_near_m.y, dist);
	// сдвиг выборки крупным шумом: пятна неправильной формы, без сетки и повторов
	vec4 w = macro_tex(p + vec2(311.0, 97.0), 430.0, foot);
	vec2 q = p + (w.xy - 0.5) * 260.0;
	// октавы повёрнуты друг к другу — границы тайлов текстуры не совпадают
	vec4 n0 = macro_tex(q, macro_scales_m.x, foot);
	vec4 n1 = macro_tex(mat2(vec2(0.8, 0.6), vec2(-0.6, 0.8)) * q + vec2(57.0, 13.0), macro_scales_m.y, foot);
	vec4 n2 = macro_tex(mat2(vec2(0.28, 0.96), vec2(-0.96, 0.28)) * q + vec2(19.0, 83.0), macro_scales_m.z, foot);
	vec4 n3 = macro_tex(mat2(vec2(0.6, -0.8), vec2(0.8, 0.6)) * q + vec2(71.0, 41.0), macro_scales_m.w, foot);
	float o0 = macro_shape(n0.x) * near_k;
	float o1 = macro_shape(n1.x) * mix(0.4, 1.0, near_k);
	float o2 = macro_shape(n2.x);
	float o3 = macro_shape(n3.x);
	// оттенок: + суше, − сочнее; сырые ложбины тянут к сочному
	float hue = 2.0 * (o0 * macro_weights.x + o1 * macro_weights.y + o2 * macro_weights.z
			+ o3 * macro_weights.w) / max(dot(macro_weights, vec4(1.0)), 1e-3) * 3.0;
	hue = clamp(hue - macro_wet_k * wet, -1.0, 1.0);
	// яркость — независимые каналы тех же выборок (не совпадает с оттенком)
	float br = (macro_shape(n0.y) * 0.6 * near_k + macro_shape(n1.y) * mix(0.4, 1.0, near_k)
			+ macro_shape(n2.y) * 0.8 + macro_shape(n3.y) * 0.7) * 1.6;
	// сочные пятна — оливково-зелёные (grass_color), насыщенная зелень — только сырые ложбины
	vec3 lush = grass_color * (lum / max(dot(grass_color, L), 1e-3));
	// сухие пятна — к оливково-хаки (dry_grass_color), солома — только выгоревшие (burn_*)
	vec3 dry = dry_grass_color * (lum / max(dot(dry_grass_color, L), 1e-3)) * 1.08;
	c = mix(c, hue < 0.0 ? lush : dry, abs(hue) * macro_hue);
	c *= 1.0 + macro_bright * br;
	// выгоревшие пятна (третьи каналы октав 280 м и 80 м — рваные края, без лишних выборок);
	// чаще на сухих макушках
	// и буграх, в сырых ложбинах — нет
	if (burn_share > 0.0) {
		float bn = n2.z * 0.7 + n1.z * 0.3;
		float bw = smoothstep(0.75 - burn_share, 0.8 - burn_share * 0.5, bn - 0.25 * min(wet, 0.0))
				* (1.0 - clamp(wet * 2.0, 0.0, 1.0));
		c = mix(c, straw_color * (dot(c, L) / max(dot(straw_color, L), 1e-3)) * 1.18, bw * burn_strength);
	}
	// покосы: прямоугольные участки (чуть кривые), светлая стерня и валки полосами
	float mk = flat_k * near_k;
	if (mk > 0.0 && mow_share > 0.0 && wet > 0.0) {
		vec2 pw = p + (n0.zw - 0.5) * 14.0;
		vec2 qc = pw / mow_cell_m + vec2(floor(pw.y / (mow_cell_m.y * 4.0)) * 0.41, 0.0);
		vec2 cell = floor(qc);
		float hc = hash12(cell + vec2(23.7, 5.9));
		if (hc < mow_share * smoothstep(0.0, 0.4, wet)) {   // редко, только днища долин
			vec2 f = qc - cell;
			vec2 e = min(f, 1.0 - f) * mow_cell_m;
			float inner = smoothstep(3.0, 7.0, min(e.x, e.y));   // некошеная кромка
			float along = hash12(cell + 1.9) < 0.5 ? pw.x : pw.y;
			float rows = sin(6.2832 * along / mow_row_m) * (1.0 - smoothstep(0.15 * mow_row_m, 0.4 * mow_row_m, foot));
			vec3 stub = mix(c, dry, 0.45) * (1.06 + mow_strength * rows);
			c = mix(c, stub, inner * mk);
		}
	}
	return c;
}

// Цвет луга до пятен с высоты: сухость по локации, пятнам, склону (north — «северность» склона,
// patch2 — meadow_patch), влажность wet −1..1 и сглаженная северность north_s из полей рельефа.
vec3 meadow_ground_color(vec2 xz, float north, float patch2, float wet, float north_s) {
	vec3 gcol = meadow_color_dry(xz, north, patch2, -wet_dry_k * wet - aspect_dry_k * north_s);
	// ложбины сочнее-зеленее (насыщеннее, не темнее), гребни/выпуклости светлее и суше
	const vec3 LW = vec3(0.2126, 0.7152, 0.0722);
	vec3 gsat = mix(vec3(dot(grass_color, LW)), grass_color, wet_sat);
	vec3 lush = gsat * (dot(gcol, LW) / max(dot(gsat, LW), 1e-3));
	return mix(gcol, lush, wet_green * max(wet, 0.0))
			* (1.0 - wet_dark * min(wet, 0.0) + wet_bright * max(wet, 0.0));
}

// Поля рельефа в точке xz: (R влажность, G AO, B северность, A); без полей — нейтрально.
vec4 relief_at(vec2 xz) {
	if (!use_relief) {
		return vec4(0.5, 1.0, 0.5, 0.0);
	}
	return textureLod(relief_tex, ((xz - relief_origin) / relief_cell_m + 0.5) / relief_texels, 0.0);
}
