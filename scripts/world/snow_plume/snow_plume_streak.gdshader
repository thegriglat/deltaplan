// Штрих снежной пыли (SnowPlumeRender): цилиндрический билборд вокруг оси скорости частицы.
// Ось X частицы (MODEL_MATRIX[0]) = направление скорости × длина штриха, ось Y — ширина (длина = ширина штриха).
// Альфа спадает к концам штриха и к краям поперёк; плавное появление/исчезание по возрасту (INSTANCE_CUSTOM.y);
// прозрачность ∝ intensity (COLOR.a). Свет как у smoke_puff (солнце, просвет BACKLIGHT, туман сцены).
// Чтобы штрих не пропадал в субпиксель вдали, ширина не меньше min_px пикселей.
shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, specular_disabled, diffuse_lambert_wrap, shadows_disabled;

uniform vec3 tint : source_color = vec3(0.96, 0.97, 1.0);
uniform float alpha = 0.25;
uniform float near_fade_m = 3.0;
uniform float min_px = 1.2;

varying float v_age;
varying float v_int;

void vertex() {
	float len = length(MODEL_MATRIX[0].xyz);
	float wid = length(MODEL_MATRIX[1].xyz);
	vec3 ax_w = len > 1e-4 ? MODEL_MATRIX[0].xyz / len : vec3(1.0, 0.0, 0.0);
	vec3 c = (VIEW_MATRIX * vec4(MODEL_MATRIX[3].xyz, 1.0)).xyz;
	vec3 ax = normalize((VIEW_MATRIX * vec4(ax_w, 0.0)).xyz);
	vec3 side = cross(ax, normalize(c));
	float sl = length(side);
	side = sl > 1e-3 ? side / sl : vec3(0.0, 1.0, 0.0);
	// ширина не меньше min_px пикселей: размер пикселя на расстоянии d ≈ d · 2·tan(fov/2) / высота_вида
	float px_m = -c.z * 2.0 / (PROJECTION_MATRIX[1][1] * VIEWPORT_SIZE.y);
	wid = max(wid, px_m * min_px);
	VERTEX = c + ax * (VERTEX.x * len) + side * (VERTEX.y * wid);
	NORMAL = vec3(0.0, 0.0, 1.0);
	MODELVIEW_MATRIX = mat4(1.0);
	MODELVIEW_NORMAL_MATRIX = mat3(1.0);
	v_age = INSTANCE_CUSTOM.y;
	v_int = COLOR.a;
}

void fragment() {
	float along = 1.0 - abs(UV.x * 2.0 - 1.0);
	float across = 1.0 - abs(UV.y * 2.0 - 1.0);
	float m = smoothstep(0.0, 0.6, along) * smoothstep(0.0, 0.7, across);
	float t = clamp(v_age, 0.0, 1.0);
	float life = smoothstep(0.0, 0.2, t) * (1.0 - smoothstep(0.6, 1.0, t));
	float near = clamp((-VERTEX.z - 0.5) / max(near_fade_m, 0.01), 0.0, 1.0);
	ALBEDO = tint;
	ALPHA = clamp(alpha * v_int * m * life * near, 0.0, 1.0);
	BACKLIGHT = tint * 0.5;
	ROUGHNESS = 1.0;
}
