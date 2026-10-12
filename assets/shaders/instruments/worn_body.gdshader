shader_type spatial;
// Поношенный корпус прибора (instrument.glb / vario_90s.glb, нода Body). Маска износа — цвет вершин
// из tools/blender/bl_util.py:bake_wear: R износ рёбер, G грязь во впадинах (AO), B зона кнопок.
// Параметры — configs/instruments.json → wear.<вид>. Один шейдер на пластик/резину/металл.
// Всё, что мельче пикселя, гаснет по fwidth: без мерцания.

uniform vec4 base_color : source_color = vec4(0.1, 0.1, 0.1, 1.0);
uniform float base_rough = 0.6;
uniform float base_metal = 0.0;
uniform vec4 worn_color : source_color = vec4(0.4, 0.4, 0.42, 1.0); // чем стёрто (подложка/голый металл)
uniform float edge_amount = 0.9;     // сила истирания рёбер 0..1
uniform float edge_rough = 0.3;      // шероховатость стёртого (глаже)
uniform float edge_width = 0.5;      // порог маски: меньше — шире стёртая кромка
uniform float dirt_amount = 0.8;     // грязь во впадинах 0..1
uniform vec4 dirt_color : source_color = vec4(0.05, 0.045, 0.04, 1.0);
uniform float dirt_rough = 0.95;
uniform float scratch_amount = 0.5;  // царапины и потёртости 0..1
uniform float scratch_freq = 220.0;  // частота царапин, 1/м
uniform float blotch_freq = 45.0;    // частота пятен износа, 1/м
uniform float polish_amount = 0.8;   // затёртость центра кнопок до блеска 0..1
uniform float polish_rough = 0.2;
uniform float seed = 0.0;

varying vec3 mpos;
varying vec4 wear;

float hash(vec3 p) {
	p = fract(p * 0.3183099 + vec3(0.1, 0.2, 0.3) + seed);
	p *= 17.0;
	return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

float vnoise(vec3 x) {
	vec3 i = floor(x);
	vec3 f = fract(x);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(mix(hash(i), hash(i + vec3(1, 0, 0)), f.x),
			mix(hash(i + vec3(0, 1, 0)), hash(i + vec3(1, 1, 0)), f.x), f.y),
			mix(mix(hash(i + vec3(0, 0, 1)), hash(i + vec3(1, 0, 1)), f.x),
			mix(hash(i + vec3(0, 1, 1)), hash(i + vec3(1, 1, 1)), f.x), f.y), f.z);
}

void vertex() {
	mpos = VERTEX;
	wear = COLOR;
}

void fragment() {
	// Пиксельный размер в единицах частоты шума: когда ячейка меньше пикселя — гасим деталь.
	float px = length(fwidth(mpos));
	float fade_blotch = 1.0 - smoothstep(0.35, 0.9, px * blotch_freq);
	float fade_scr = 1.0 - smoothstep(0.35, 0.9, px * scratch_freq);

	float n_b = vnoise(mpos * blotch_freq);
	float n_b2 = vnoise(mpos * blotch_freq * 2.7 + 7.0);
	float blotch = mix(0.5, n_b * 0.65 + n_b2 * 0.35, fade_blotch);

	// износ кромки: маска вершин + пятнистость; граница сглаживается по fwidth
	float e = wear.r * (0.55 + 0.9 * blotch);
	float ew = fwidth(e) + 0.04;
	float thr = 1.0 - edge_width;
	float edge = smoothstep(thr - ew, thr + ew, e) * edge_amount;

	// царапины: вытянутый шум в двух направлениях, тонкая линия на гребне
	vec3 sp = mpos * scratch_freq;
	float s1 = vnoise(sp * vec3(1.0, 0.06, 0.5) + 3.1);
	float s2 = vnoise(sp * vec3(0.05, 1.0, 0.5) + 9.7);
	float s3 = vnoise(sp * vec3(0.5, 0.5, 0.05) + 1.3);
	float sc = max(max(smoothstep(0.84, 0.88, s1), smoothstep(0.86, 0.9, s2)),
			smoothstep(0.87, 0.91, s3));
	sc *= fade_scr * scratch_amount * (0.4 + 0.6 * smoothstep(0.3, 0.8, blotch));

	float dirt = clamp(wear.g * dirt_amount * (0.55 + 0.9 * blotch), 0.0, 1.0);
	dirt *= 1.0 - edge;

	// центр кнопки: зона B без кромки — затёрт до блеска
	float polish = wear.b * (1.0 - smoothstep(0.1, 0.5, wear.r)) * polish_amount;
	polish *= 0.55 + 0.45 * smoothstep(0.25, 0.7, blotch);

	vec3 alb = base_color.rgb;
	float rgh = base_rough;
	float met = base_metal;

	alb = mix(alb, dirt_color.rgb, dirt);
	rgh = mix(rgh, dirt_rough, dirt);
	met = mix(met, 0.0, dirt * 0.7);

	alb = mix(alb, worn_color.rgb, edge);
	rgh = mix(rgh, edge_rough, edge);

	alb = mix(alb, mix(alb, worn_color.rgb, 0.55), sc);
	rgh = mix(rgh, min(rgh + 0.25, 1.0), sc * (1.0 - edge));

	// затёртость кнопок: темнее-глянцевее (отполированная резина) без перекраски
	alb = mix(alb, alb * 0.75 + worn_color.rgb * 0.12, polish);
	rgh = mix(rgh, polish_rough, polish);

	ALBEDO = alb;
	ROUGHNESS = clamp(rgh, 0.04, 1.0);
	METALLIC = met;
	SPECULAR = 0.5;
}
