shader_type spatial;
render_mode cull_disabled;
// Ткань лагеря (контракт SC-K5): палатки, чехлы, рюкзаки, одежда. Узор и рельеф — в осях объекта
// (VERTEX до трансформации экземпляра; UV не нужны), проекция по доминирующей оси нормали — одна
// выборка нормали ткани (рипстоп 512², общая). Складки и провис — аналитически, пыль — снизу.
// Тон (sRGB) = base_color * COLOR.rgb * tint; переводится в линейный здесь.

uniform sampler2D fabric_normal : hint_normal, filter_linear_mipmap, repeat_enable;
uniform vec3 base_color = vec3(1.0);
uniform bool use_color = true;
uniform float tile_m = 0.32;          // размер плитки плетения (64 нити), м в осях объекта
uniform float weave_strength = 1.0;
uniform float fold_strength = 0.25;   // складки и провис, нормалью
uniform float fold_scale = 1.0;
uniform float roughness = 0.88;
uniform float dirt_height_m = 0.35;   // пыль до этой высоты в осях объекта
uniform float dirt_amount = 0.5;
uniform vec3 dirt_color = vec3(0.45, 0.38, 0.29);
instance uniform vec3 tint = vec3(1.0);

varying vec3 obj_pos;
varying vec3 obj_nrm;

vec3 to_linear(vec3 c) {
	return mix(pow((c + 0.055) / 1.055, vec3(2.4)), c / 12.92, step(c, vec3(0.04045)));
}

void vertex() {
	obj_pos = VERTEX;
	obj_nrm = NORMAL;
}

void fragment() {
	vec3 n = normalize(obj_nrm);
	vec3 a = abs(n);
	vec2 uv;
	vec3 tu;
	vec3 tv;
	if (a.y >= a.x && a.y >= a.z) {
		uv = obj_pos.xz; tu = vec3(1.0, 0.0, 0.0); tv = vec3(0.0, 0.0, 1.0);
	} else if (a.x >= a.z) {
		uv = obj_pos.zy; tu = vec3(0.0, 0.0, 1.0); tv = vec3(0.0, 1.0, 0.0);
	} else {
		uv = obj_pos.xy; tu = vec3(1.0, 0.0, 0.0); tv = vec3(0.0, 1.0, 0.0);
	}
	vec3 tex = texture(fabric_normal, uv / tile_m).xyz * 2.0 - 1.0;
	// складки: пологие волны вдоль ткани и провис между растяжками
	vec2 f = uv * fold_scale;
	float w1 = sin(f.x * 5.3 + sin(f.y * 3.1) * 1.7);
	float w2 = sin(f.y * 7.1 + f.x * 2.3);
	vec2 g = vec2(cos(f.x * 5.3 + sin(f.y * 3.1) * 1.7) * 5.3 * w2 + w1 * cos(f.y * 7.1 + f.x * 2.3) * 2.3,
			w1 * cos(f.y * 7.1 + f.x * 2.3) * 7.1) * 0.06 * fold_strength;
	vec3 no = normalize(n + (tex.x * weave_strength + g.x) * tu + (tex.y * weave_strength + g.y) * tv);
	NORMAL = normalize((VIEW_MATRIX * MODEL_MATRIX * vec4(no, 0.0)).xyz);

	float cav = clamp(tex.z, 0.0, 1.0);
	float patch_n = 0.5 + 0.5 * sin(uv.x * 2.7 + sin(uv.y * 3.3) * 2.0) * sin(uv.y * 1.9 + 1.3);
	float dirt = smoothstep(dirt_height_m, 0.0, obj_pos.y) * dirt_amount * (0.6 + 0.8 * patch_n);
	vec3 tone = base_color;
	if (use_color) {
		tone *= COLOR.rgb * tint;
	}
	vec3 col = to_linear(clamp(tone, 0.0, 1.0));
	col *= 0.78 + 0.22 * cav * cav;                       // нити темнее в щелях плетения
	col = mix(col, to_linear(dirt_color) * (0.5 + 0.5 * dot(col, vec3(0.33))), clamp(dirt, 0.0, 0.85));
	ALBEDO = col;
	ROUGHNESS = roughness;
	METALLIC = 0.0;
	SPECULAR = 0.3;
}
