// Металл каркаса: трубы (анодированный алюминий), оцинкованный крепёж, воронёные фитинги.
// Подставляется вместо материала glb при загрузке крыла (FrameMetal.apply), база — цвет, шероховатость
// и металличность исходного материала. Шум — в координатах модели, без текстур.
// Ось трубы: COLOR.rgb = касательная (0..1 ↔ -1..1), FrameMetal считает её по мешу при загрузке.
// Детали гаснут по расстоянию и по размеру пикселя в метрах (fwidth), мерцания нет.
// Параметры: configs/flight.json → visual.metal.
shader_type spatial;

uniform vec4 base_color : source_color = vec4(0.7, 0.7, 0.72, 1.0);
uniform float base_rough = 0.35;
uniform float base_metal = 0.8;
uniform float blot_freq = 7.0;      // пятна шероховатости (затёртое/пыльное), 1/м
uniform float blot_rough = 0.2;     // амплитуда ± к шероховатости
uniform float color_var = 0.04;     // неровность цвета анодировки ± доля
uniform float dirt = 0.0;           // тёмная грязь пятнами (крепёж), 0..1
uniform float brush = 0.0;          // 0 — без продольных царапин (нет оси)
uniform float brush_rough = 0.12;   // амплитуда царапин в шероховатости
uniform float brush_along = 5.0;    // длина царапины: 1/м вдоль оси
uniform float brush_across = 28.0;  // густота вокруг оси (радиус цилиндра шума)
uniform float aniso = 0.5;          // вытянутый блик (шлифованный металл)
uniform vec3 grip_l = vec3(0.0, 1.0e4, 0.0); // точки хвата в осях меша
uniform vec3 grip_r = vec3(0.0, 1.0e4, 0.0);
uniform float grip_radius = 0.14;   // зона хвата, м
uniform float grip_rough_k = 0.45;  // в зоне хвата шероховатость × это
uniform float fade_near = 3.0;      // детали полностью до, м
uniform float fade_far = 14.0;      // и нет совсем после

varying vec3 mpos;
varying vec3 mtan;
varying float vdist;

float h31(vec3 p) {
	p = fract(p * 0.3183099 + vec3(0.1, 0.2, 0.3));
	p *= 17.0;
	return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

float vnoise(vec3 x) {
	vec3 i = floor(x);
	vec3 f = fract(x);
	f = f * f * (3.0 - 2.0 * f);
	return mix(
		mix(mix(h31(i), h31(i + vec3(1, 0, 0)), f.x), mix(h31(i + vec3(0, 1, 0)), h31(i + vec3(1, 1, 0)), f.x), f.y),
		mix(mix(h31(i + vec3(0, 0, 1)), h31(i + vec3(1, 0, 1)), f.x), mix(h31(i + vec3(0, 1, 1)), h31(i + vec3(1, 1, 1)), f.x), f.y),
		f.z);
}

void vertex() {
	mpos = VERTEX;
	mtan = COLOR.rgb * 2.0 - 1.0;
	if (brush > 0.0) {
		TANGENT = normalize((MODELVIEW_NORMAL_MATRIX * mtan));
		BINORMAL = normalize(cross(NORMAL, TANGENT));
	}
}

void fragment() {
	float d = length(VERTEX);
	float px = length(fwidth(mpos));                 // метров на пиксель
	float fade = 1.0 - smoothstep(fade_near, fade_far, d);
	float fine_fade = fade * (1.0 - smoothstep(0.002, 0.006, px)); // царапины тоньше 2–6 мм → гаснут
	float blot_fade = 1.0 - smoothstep(0.02, 0.08, px);

	float n1 = vnoise(mpos * blot_freq);
	float n2 = vnoise(mpos * blot_freq * 3.1 + 7.0);
	float blot = (n1 * 0.65 + n2 * 0.35 - 0.5) * 2.0 * blot_fade;

	float rough = base_rough + blot * blot_rough;
	vec3 col = base_color.rgb * (1.0 + blot * color_var * 0.7 + (vnoise(mpos * 2.3 + 3.0) - 0.5) * 2.0 * color_var * blot_fade);
	col *= 1.0 - dirt * smoothstep(0.55, 0.85, n2) * blot_fade * 0.6;
	rough += dirt * smoothstep(0.55, 0.85, n2) * 0.2 * blot_fade;

	float aniso_k = 0.0;
	if (brush > 0.0) {
		vec3 t = normalize(mtan);
		float a = dot(mpos, t);
		vec3 r0 = abs(t.y) < 0.95 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
		vec3 r = normalize(cross(t, r0));
		vec3 s = cross(t, r);
		vec3 radial = mpos - t * a;
		float ang = atan(dot(radial, s), dot(radial, r));
		float sc = vnoise(vec3(a * brush_along, cos(ang) * brush_across, sin(ang) * brush_across));
		sc = smoothstep(0.35, 0.8, sc) * fine_fade;
		rough += (sc - 0.3) * brush_rough * brush;
		aniso_k = aniso * brush * fine_fade;
	}

	float gd = min(distance(mpos, grip_l), distance(mpos, grip_r));
	float g = 1.0 - smoothstep(grip_radius * 0.7, grip_radius * 1.3, gd);
	rough = mix(rough, rough * grip_rough_k, g);
	col = mix(col, col * 1.06, g);

	ALBEDO = clamp(col, 0.0, 1.0);
	ROUGHNESS = clamp(rough, 0.05, 1.0);
	METALLIC = base_metal;
	SPECULAR = 0.5;
	ANISOTROPY = aniso_k * (1.0 - g);
}
