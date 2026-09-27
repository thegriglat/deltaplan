shader_type spatial;
// Камни у земли (RockScatter): рисунок породы трипланарно в мировых координатах (камни разного
// масштаба и поворота не тянут текстуру), оттенок экземпляра (цвет MultiMesh), лишайник
// пятнами на верхних гранях, тёмный влажный низ у земли.
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

uniform sampler2D rock_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D rock_normal : hint_normal, filter_linear_mipmap, repeat_enable;
uniform bool use_tex = false;
uniform bool use_normal = false;
uniform vec3 tex_avg = vec3(0.5);
uniform float tile_m = 2.5;
uniform vec3 base_color : source_color = vec3(0.36, 0.34, 0.31);
uniform vec3 lichen_color : source_color = vec3(0.52, 0.53, 0.42);
uniform float lichen_amount = 0.35;

varying vec3 v_wp;
varying vec3 v_wn;
varying float v_base;
varying vec3 v_tint;

void vertex() {
	v_wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_wn = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	v_base = VERTEX.y;  // модель: низ на −0,15·высоты, наибольший размер 1
	v_tint = COLOR.rgb;
}

void fragment() {
	vec3 w = pow(abs(v_wn), vec3(4.0));
	w /= w.x + w.y + w.z;
	vec3 p = v_wp / tile_m;
	vec3 col = base_color * v_tint;
	if (use_tex) {
		vec3 t = texture(rock_tex, p.zy).rgb * w.x + texture(rock_tex, p.xz).rgb * w.y
				+ texture(rock_tex, p.xy).rgb * w.z;
		col *= clamp(t / tex_avg, vec3(0.35), vec3(1.8));
	}
	// лишайник: пятна на гранях, смотрящих вверх
	float ln = use_tex ? texture(rock_tex, v_wp.xz / 7.3 + vec2(0.37, 0.11)).g / tex_avg.g : 1.0;
	float lichen = smoothstep(0.35, 0.8, v_wn.y) * smoothstep(0.95, 1.25, ln) * lichen_amount;
	col = mix(col, lichen_color * (0.8 + 0.2 * v_tint), clamp(lichen, 0.0, 1.0));
	// низ у земли темнее (затенение, влага)
	col *= mix(0.55, 1.0, smoothstep(-0.12, 0.12, v_base));
	ALBEDO = col;
	ROUGHNESS = 0.92;
	SPECULAR = 0.3;
	if (use_normal) {
		// трипланарная нормаль по доминирующей оси (дёшево): берём проекцию с наибольшим весом
		vec2 uv = w.y > max(w.x, w.z) ? p.xz : (w.x > w.z ? p.zy : p.xy);
		NORMAL_MAP = texture(rock_normal, uv).rgb;
		NORMAL_MAP_DEPTH = 0.8;
	}
}
