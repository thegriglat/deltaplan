// Полоса трека (GL-К6): лента, развёрнутая к камере, постоянной экранной ширины width_px.
// Вершины — пары в одной точке трека с UV.x = −1/+1, NORMAL — касательная трека, COLOR — цвет и
// непрозрачность по вертикальной скорости (линейный цвет). Глубину не пишет, тест глубины есть
// (за горой не видно); вершины сдвинуты к камере по лучу зрения — экранное положение то же,
// а у земли полоса не мерцает с рельефом. Образец — scripts/world_objects/wire.gdshader.
shader_type spatial;
render_mode unshaded, cull_disabled, blend_mix, depth_draw_never, shadows_disabled, fog_disabled;

uniform float width_px = 4.0;
uniform float depth_pull_m = 1.5;
uniform float depth_pull_frac = 0.002;

varying vec4 vcolor;


void vertex() {
	vec3 vpos = (MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 vt = (MODELVIEW_MATRIX * vec4(NORMAL, 0.0)).xyz;
	float tl = length(vt);
	vt = tl > 1e-6 ? vt / tl : vec3(1.0, 0.0, 0.0);
	float d = max(length(vpos), 1e-3);
	vec3 side = cross(vt, vpos / d);
	float sl = length(side);
	side = sl > 1e-4 ? side / sl : vec3(0.0, 1.0, 0.0);
	float px = d * 2.0 / (PROJECTION_MATRIX[1][1] * VIEWPORT_SIZE.y);
	vpos += side * UV.x * 0.5 * width_px * px;
	float pull = min(depth_pull_m + depth_pull_frac * d, 0.5 * d);
	vpos *= 1.0 - pull / max(length(vpos), 1e-3);
	vcolor = COLOR;
	POSITION = PROJECTION_MATRIX * vec4(vpos, 1.0);
}


void fragment() {
	ALBEDO = vcolor.rgb;
	ALPHA = vcolor.a;
}
