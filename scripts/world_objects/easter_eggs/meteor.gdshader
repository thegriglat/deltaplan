shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, fog_disabled, shadows_disabled;
// Метеор: штрих на плоскости, касательной к небесной сфере (gnomonic). u = 0..1 вдоль пути,
// v = поперёк. Угол вдоль пути = atan((u-0.5)*2*tan_half) (рад от середины пути).

uniform float tan_half = 0.3;       // tan(половина угловой длины пути)
uniform float half_height = 0.02;   // полувысота плоскости в единицах R (tan углов) - для v
uniform float head_rad = 0.0;       // положение головы, рад от середины пути
uniform float trail_rad = 0.2;      // длина хвоста, рад
uniform float width_rad = 0.004;    // полутолщина у головы, рад
uniform float intensity = 1.0;      // яркость (HDR), 0 - не видно
uniform vec3 head_color : source_color = vec3(1.0, 0.97, 0.82);
uniform vec3 tail_color : source_color = vec3(0.65, 1.0, 0.55);

void fragment() {
	float a = atan((UV.x - 0.5) * 2.0 * tan_half);
	float y = (UV.y - 0.5) * 2.0 * half_height; // ~ угол поперёк, рад
	float d = head_rad - a;                      // >0 — позади головы
	float k = clamp(d / trail_rad, 0.0, 1.0);
	float across_w = width_rad * (1.0 - 0.75 * k) + 0.0005;
	float across = exp(-(y * y) / (across_w * across_w));
	float tail = (d >= 0.0) ? pow(1.0 - k, 1.6) : 0.0;
	// «голова»: яркая точка с мягким ореолом
	float hd = length(vec2(d, y));
	float head = exp(-(hd * hd) / (width_rad * width_rad * 6.0));
	vec3 col = mix(tail_color, head_color, clamp(head + tail * tail, 0.0, 1.0));
	float b = (tail * across * 1.2 + head * 2.5) * intensity;
	ALBEDO = col * b;
	ALPHA = 1.0;
}
