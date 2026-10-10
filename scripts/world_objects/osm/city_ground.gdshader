// Земля города (L8, OL-5): серо-бежевая подложка дворов с пятнами зелени. Сетка по рельефу (OsmCityGround),
// альфа вершин — маска города (к краю плавно угасает, дизеринг без сортировки). Сдвиг к камере — как у
// draped.gdshader (прячет расхождение с грубым LOD рельефа). Шум — от локальных координат меша (≤ ±1 км),
// не от мировых: без float-ряби; детали гаснут с расстоянием.
shader_type spatial;
render_mode cull_disabled;

uniform float depth_bias_m = 0.12;
uniform float depth_pull = 0.004;
uniform float roughness : hint_range(0.0, 1.0) = 0.95;
uniform vec3 ground_color : source_color = vec3(0.5, 0.47, 0.42);
uniform vec3 yard_color : source_color = vec3(0.42, 0.40, 0.36);
uniform float patch_m = 28.0;

varying vec2 lp;
varying float view_dist;


float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}


float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash12(i), hash12(i + vec2(1.0, 0.0)), f.x), mix(hash12(i + vec2(0.0, 1.0)), hash12(i + vec2(1.0, 1.0)), f.x), f.y);
}


void vertex() {
	lp = VERTEX.xz;
	vec4 v = MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	float d = length(v.xyz);
	view_dist = d;
	float pull = min(depth_bias_m + d * depth_pull, d * 0.5);
	v.xyz -= v.xyz / max(d, 1e-3) * pull;
	POSITION = PROJECTION_MATRIX * v;
}


void fragment() {
	float alpha = COLOR.a;
	if (alpha < 0.999 && alpha < hash12(FRAGCOORD.xy)) {
		discard;
	}
	// спокойный светлый тон: только очень крупные мягкие пятна (малый контраст), без мелкого шума и зелени
	float big = vnoise(lp / patch_m + vec2(5.1, 2.7));
	vec3 c = mix(ground_color, yard_color, smoothstep(0.2, 0.8, big));
	ALBEDO = c;
	ROUGHNESS = roughness;
	NORMAL = FRONT_FACING ? NORMAL : -NORMAL;
}
