// Пылевой вихрь: полупрозрачная закрученная «труба» пыли (конус, расширяется кверху).
// UV.x — угол вокруг оси; высота — из локальной координаты вершины.
shader_type spatial;
render_mode unshaded, cull_back, depth_draw_never, blend_mix, shadows_disabled;

uniform sampler2D noise : filter_linear_mipmap, repeat_enable;
uniform vec3 dust_color : source_color = vec3(0.62, 0.52, 0.40);
uniform float opacity = 0.55;
uniform float spin_speed = 0.6;
uniform float rise_speed = 0.35;

instance uniform float age = 0.5;
instance uniform float spin = 1.0;
instance uniform float seed = 0.0;
// 1 — пылевая «юбка» у земли (широкая, низкая, размытая).
instance uniform float skirt = 0.0;

varying float v_h;

void vertex() {
	// Высота вдоль оси вихря 0 (земля) … 1 (верх) — у CylinderMesh локальная y от −0,5 до 0,5.
	v_h = VERTEX.y + 0.5;
}

void fragment() {
	float h = v_h;
	vec2 q = vec2(UV.x * 2.0 + spin * TIME * spin_speed - h * 0.8 * spin, h * 2.5 - TIME * rise_speed) * 0.5;
	float n = texture(noise, q + seed * 0.013).r;
	float n2 = texture(noise, q * vec2(2.0, 3.0) + 0.5).r;
	// Клубящаяся пыль: мягкие пятна, без вертикальных «нитей».
	float streak = 0.55 + 0.45 * smoothstep(0.25, 0.75, n * 0.6 + n2 * 0.4);
	// Плотно у земли, редеет кверху; края трубы (скользящий взгляд) плотнее — объём.
	float rim = 1.0 - abs(dot(normalize(NORMAL), normalize(VIEW)));
	// Объём: вдоль луча пыли больше в середине ствола, к силуэту — мягко на нет.
	float facing = 1.0 - rim;
	float dens = streak * mix(1.6, 0.25, pow(h, 0.6)) * smoothstep(0.0, 0.7, facing) * 1.3;
	if (skirt > 0.5) {
		// Юбка: густая у земли, быстро редеет вверх, мягкая.
		dens = (0.5 + 0.5 * streak) * pow(1.0 - h, 2.0) * smoothstep(0.0, 0.8, facing) * 0.8;
	}
	dens *= (skirt > 0.5 ? 1.0 : smoothstep(0.0, 0.08, h)) * (1.0 - smoothstep(0.75, 1.0, h));
	// Жизнь: нарастает и тает.
	dens *= smoothstep(0.0, 0.15, age) * (1.0 - smoothstep(0.7, 1.0, age));
	vec3 col = dust_color * mix(0.75, 1.1, h) * (0.85 + 0.3 * n2);
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
	col = mix(col * 12.92, 1.055 * pow(max(col, vec3(0.0)), vec3(1.0 / 2.4)) - 0.055, step(vec3(0.0031308), col));
#endif
	ALBEDO = col;
	ALPHA = clamp(dens * opacity, 0.0, 1.0);
}
