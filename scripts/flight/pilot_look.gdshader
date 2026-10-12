shader_type spatial;
// Материалы пилота (каска, визор, ткань, ботинки). Процедурно: шум в координатах модели
// (UV модели не используются), всё гаснет по размеру пикселя в метрах — без мерцания.
// kind: 0 каска, 1 визор, 2 кордура (подвеска), 3 текстиль (куртка, брюки), 4 стропа, 5 кожа, 6 резина.
// PILOT_LOOK_VISOR (define в начале кода) — прозрачный вариант: только визор пишет ALPHA.
#ifdef PILOT_LOOK_VISOR
render_mode blend_mix, depth_draw_opaque, cull_back;
#else
render_mode cull_back;
#endif

uniform int kind = 2;
uniform vec4 base_color : source_color = vec4(0.5, 0.5, 0.5, 1.0);
uniform float base_rough = 0.7;
uniform float period_m = 0.012;     // шаг плетения / рисунка, м
uniform float weave_strength = 0.35; // наклон нормали плетением
uniform float sheen = 0.3;          // подсвет ткани по краю
uniform float dust = 0.25;          // неравномерная пыль/выгорание
uniform float wear = 0.5;           // потёртости (каска, кожа)
uniform float rough_var = 0.15;     // разброс шероховатости
uniform float alpha = 0.88;         // визор: непрозрачность
uniform vec3 sky_tint : source_color = vec3(0.55, 0.70, 0.95);
uniform float reflect_k = 0.55;     // визор: сила отражения неба по Френелю
uniform float dirt = 0.5;           // грязь снизу (ботинки, подошва)
uniform float clearcoat = 1.0;

varying vec3 mp;
varying vec3 on;

float hash31(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.zyx + 31.32);
	return fract((p.x + p.y) * p.z);
}

float vnoise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = mix(mix(hash31(i), hash31(i + vec3(1, 0, 0)), f.x), mix(hash31(i + vec3(0, 1, 0)), hash31(i + vec3(1, 1, 0)), f.x), f.y);
	float b = mix(mix(hash31(i + vec3(0, 0, 1)), hash31(i + vec3(1, 0, 1)), f.x), mix(hash31(i + vec3(0, 1, 1)), hash31(i + vec3(1, 1, 1)), f.x), f.y);
	return mix(a, b, f.z);
}

void vertex() {
	mp = VERTEX;
	on = NORMAL;
}

void fragment() {
	float pf = length(fwidth(mp)) + 1.0e-6;       // размер пикселя на поверхности, м
	float curv = length(fwidth(on)) / pf;         // кривизна (грубо): края и рёбра
	vec3 col = base_color.rgb;
	float rough = base_rough;
	float met = 0.0;
	float a = 1.0;
	vec3 emis = vec3(0.0);
	float lowf = vnoise(mp * 3.0);
	float midf = vnoise(mp * 14.0);

	if (kind == 0) {
		// каска: стеклопластик, царапины, сколы краски по кромке
		float fine = 1.0 - smoothstep(0.012, 0.03, pf);
		float sc = smoothstep(0.80, 0.84, vnoise(mp * vec3(160.0, 6.0, 160.0))) + smoothstep(0.80, 0.84, vnoise(mp * vec3(5.0, 150.0, 90.0)));
		sc = clamp(sc, 0.0, 1.0) * fine * wear;
		float edge = smoothstep(6.0, 16.0, curv);
		float chip = smoothstep(0.68, 0.72, vnoise(mp * 160.0)) * edge * wear * (1.0 - smoothstep(0.02, 0.05, pf));
		col = mix(col, col * 0.78, lowf * dust * 0.5);
		col = mix(col, vec3(0.5, 0.5, 0.48), chip);
		col -= vec3(0.05) * sc;
		rough = base_rough + (lowf - 0.5) * rough_var + sc * 0.2 + chip * 0.45;
		CLEARCOAT = clearcoat * (1.0 - chip);
		CLEARCOAT_ROUGHNESS = 0.04 + sc * 0.4 + (midf - 0.5) * 0.03;
	} else if (kind == 1) {
		// визор: тонированный поликарбонат, отражение неба по Френелю, разводы только в блике
		float ndv = clamp(dot(NORMAL, VIEW), 0.0, 1.0);
		float fres = pow(1.0 - ndv, 3.0);
		float smudge = vnoise(mp * vec3(40.0, 22.0, 40.0)) * 0.6 + vnoise(mp * 9.0) * 0.4;
		col = base_color.rgb * 0.45;
		rough = base_rough + smoothstep(0.45, 0.8, smudge) * rough_var;
		a = clamp(alpha + fres * (1.0 - alpha), 0.0, 1.0);
		emis = sky_tint * fres * reflect_k * (0.7 + 0.3 * smudge);
		SPECULAR = 0.9;
	} else if (kind <= 4) {
		// ткань: плетение нормалями по доминирующей оси, sheen по краю, пыль/выгорание
		vec3 ao = abs(on);
		vec3 ea = vec3(0.0, 1.0, 0.0);
		vec3 eb = vec3(0.0, 0.0, 1.0);
		vec2 uv = mp.yz;
		if (ao.y >= ao.x && ao.y >= ao.z) {
			ea = vec3(1.0, 0.0, 0.0);
			uv = mp.xz;
		} else if (ao.z >= ao.x && ao.z >= ao.y) {
			eb = vec3(1.0, 0.0, 0.0);
			ea = vec3(0.0, 1.0, 0.0);
			uv = mp.yx;
		} else {
			eb = vec3(0.0, 0.0, 1.0);
		}
		float per = period_m;
		float fade = 1.0 - smoothstep(0.25 * per, 0.6 * per, pf);
		vec2 q = uv / per;
		float gu;
		float gv;
		float g = 1.0;
		if (kind == 4) {
			// лента: поперечный «ёлочный» рубчик вдоль стропы и крупный шаг по ширине
			float s = dot(mp, normalize(vec3(0.0, 1.0, 0.45))) / per;
			gu = cos(6.2832 * s) * 0.6;
			gv = 0.0;
			g = 0.5 + 0.5 * sin(6.2832 * s);
			ea = normalize(vec3(0.0, 1.0, 0.45));
			eb = vec3(0.0);
		} else {
			float su = sin(6.2832 * q.x);
			float sv = sin(6.2832 * q.y);
			gu = cos(6.2832 * q.x) * sv;
			gv = su * cos(6.2832 * q.y);
			g = 0.5 + 0.5 * su * sv;
		}
		float str = weave_strength * fade;
		vec3 d = -(gu * ea + gv * eb) * str;
		NORMAL = normalize(NORMAL + (VIEW_MATRIX * MODEL_MATRIX * vec4(d, 0.0)).xyz);
		// пыль/выгорание неравномерно; рип-стоп: сетка ярче каждые 8 ниток
		float dn = vnoise(mp * 2.5) * 0.65 + midf * 0.35;
		col = mix(col, col * 0.8 + vec3(0.04, 0.038, 0.034), smoothstep(0.35, 0.8, dn) * dust);
		if (kind == 2) {
			vec2 r = abs(fract(q / 8.0) - 0.5);
			float grid = smoothstep(0.46, 0.5, max(r.x, r.y)) * fade;
			col *= 1.0 + 0.12 * grid;
		}
		col *= 1.0 - 0.08 * fade * (1.0 - g);
		rough = base_rough + (dn - 0.5) * rough_var;
		RIM = sheen;
		RIM_TINT = 0.6;
	} else if (kind == 5) {
		// кожа: потёртости на выпуклом (носок), складки, грязь снизу
		float crease = smoothstep(0.55, 0.9, vnoise(mp * vec3(30.0, 120.0, 30.0))) * (1.0 - smoothstep(0.01, 0.03, pf));
		float scuff = smoothstep(2.0, 7.0, curv) * smoothstep(0.35, 0.7, vnoise(mp * 45.0)) * wear;
		col = mix(col, col * 1.9 + vec3(0.05, 0.04, 0.03), scuff);
		col *= 1.0 - 0.18 * crease;
		float mud = smoothstep(0.1, -0.6, on.y) * smoothstep(0.3, 0.7, vnoise(mp * 18.0)) * dirt;
		col = mix(col, vec3(0.16, 0.12, 0.08), mud);
		rough = base_rough - scuff * 0.2 + mud * 0.4 + (lowf - 0.5) * rough_var;
	} else {
		// подошва: матовая резина, зернистость, грязь
		float grain = vnoise(mp * 220.0) * (1.0 - smoothstep(0.004, 0.012, pf));
		float mud = smoothstep(0.3, -0.5, on.y) * smoothstep(0.3, 0.65, vnoise(mp * 16.0)) * dirt;
		col = mix(col * (0.9 + 0.2 * grain), vec3(0.2, 0.15, 0.1), mud);
		rough = base_rough + (lowf - 0.5) * rough_var * 0.5;
	}
	ALBEDO = col;
	ROUGHNESS = clamp(rough, 0.02, 1.0);
	METALLIC = met;
#ifdef PILOT_LOOK_VISOR
	ALPHA = a;
#endif
	EMISSION = emis;
}
