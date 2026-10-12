// Стальной трос из скрученных жил: косая винтовая полоска (шаг свивки ~3–4 диаметра, 6–7 прядей),
// наклон нормали по прядям (блик идёт по жилам). Ось троса: COLOR.rgb = касательная (FrameMetal),
// «вдоль» — проекция точки на ось, «вокруг» — угол нормали относительно оси; UV в мешах тросов нет.
// Когда прядь тоньше пикселя — рисунок гаснет в средний тон. Параметры: configs/flight.json → visual.metal.wire.
shader_type spatial;

uniform vec4 base_color : source_color = vec4(0.55, 0.56, 0.6, 1.0);
uniform float base_rough = 0.4;
uniform float base_metal = 0.8;
uniform float strands = 7.0;        // число прядей (целое)
uniform float lay_pitch = 0.045;    // шаг свивки, м (≈ 3,5 диаметра)
uniform float strand_width = 0.0058;// ширина пряди по окружности, м (2πr/strands)
uniform float groove = 0.45;        // глубина тёмной канавки между прядями
uniform float bend = 0.55;          // наклон нормали по прядям
uniform float rough_var = 0.12;     // пряди чуть глаже канавок

varying vec3 mpos;
varying vec3 mnorm;
varying vec3 mtan;
varying vec3 vtan;

void vertex() {
	mpos = VERTEX;
	mnorm = NORMAL;
	mtan = COLOR.rgb * 2.0 - 1.0;
	vtan = normalize((MODELVIEW_MATRIX * vec4(mtan, 0.0)).xyz);
}

void fragment() {
	vec3 t = normalize(mtan);
	float s = dot(mpos, t);
	vec3 r0 = abs(t.y) < 0.95 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
	vec3 r = normalize(cross(t, r0));
	vec3 b = cross(t, r);
	vec3 n = normalize(mnorm);
	float phi = atan(dot(n, b), dot(n, r));
	float q = (phi - 6.2831853 * s / lay_pitch) * strands / 6.2831853;
	float f = fract(q);
	float px = length(fwidth(mpos));
	float fade = 1.0 - smoothstep(0.3, 0.9, px / strand_width);
	float h = sin(f * 3.1415927);          // 0 в канавке, 1 на гребне пряди
	float prof = mix(1.0, mix(1.0 - groove, 1.0, h), fade);
	// наклон нормали поперёк пряди (в плоскости «вокруг оси»)
	vec3 around = normalize(cross(NORMAL, normalize(vtan)));
	NORMAL = normalize(NORMAL + around * cos(f * 3.1415927) * bend * fade);
	ALBEDO = base_color.rgb * prof;
	ROUGHNESS = clamp(base_rough + (1.0 - h) * rough_var * fade + (1.0 - fade) * 0.1, 0.05, 1.0);
	METALLIC = base_metal;
}
