// Рисунок НЛО на поле: примятые колосья чуть светлее и серебристее. Рисуется по мешу, лежащему на рельефе
// (как draped.gdshader: вершины на height_at, сдвиг к камере против мерцания с грубым LOD рельефа), узор — SDF
// в координатах рисунка (центр, поворот, радиус). Умножающее смешение: цвет поля знать не нужно.
// Сверху ясно, с земли (скользящий угол) гаснет; вдали плавно угасает.
shader_type spatial;
render_mode blend_mul, unshaded, cull_disabled, depth_draw_never;

uniform vec2 center = vec2(0.0);
uniform float radius = 80.0;
uniform float rot = 0.0;
uniform int pattern = 0;
uniform float strength = 1.0;
uniform vec3 tint = vec3(1.2, 1.22, 1.18);
uniform float depth_bias_m = 0.3;
uniform float depth_pull = 0.004;
uniform float fade_start_m = 5000.0;
uniform float fade_end_m = 7000.0;
// Синус угла места камеры над точкой: ниже view_sin.x рисунка нет, выше view_sin.y — полный.
uniform vec2 view_sin = vec2(0.08, 0.5);

varying vec3 world_pos;
varying float view_dist;

vec2 dir(float a) {
	return vec2(cos(a), sin(a));
}


float ring(float r, float r0, float w) {
	return abs(r - r0) - w;
}


float circ(vec2 p, vec2 c, float rad) {
	return length(p - c) - rad;
}


float sdf(vec2 p) {
	float r = length(p);
	float d = 1.0e3;
	if (pattern == 0) {
		// концентрические кольца
		d = min(ring(r, 0.95, 0.045), min(ring(r, 0.68, 0.07), min(ring(r, 0.38, 0.05), r - 0.12)));
	} else if (pattern == 1) {
		// спираль «бус»
		for (int i = 0; i < 60; i++) {
			float t = float(i) / 59.0;
			d = min(d, circ(p, (0.1 + 0.8 * t) * dir(t * 3.5 * 2.0 * PI), 0.03 + 0.05 * t));
		}
		d = min(d, ring(r, 0.98, 0.03));
	} else if (pattern == 2) {
		// треугольник из кругов с кругами меньшего порядка
		d = ring(circ(p, vec2(0.0), 0.2), 0.0, 0.03);
		for (int i = 0; i < 3; i++) {
			vec2 v = 0.56 * dir(PI * 0.5 + float(i) * 2.0 * PI / 3.0);
			d = min(d, ring(length(p - v), 0.36, 0.03));
			for (int j = 0; j < 3; j++) {
				vec2 w = v + 0.2 * dir(float(j) * 2.0 * PI / 3.0 + float(i));
				d = min(d, circ(p, w, 0.07));
			}
		}
	} else if (pattern == 3) {
		// «цветок» из пересекающихся кругов
		for (int i = 0; i < 6; i++) {
			d = min(d, ring(length(p - 0.5 * dir(float(i) * PI / 3.0)), 0.5, 0.035));
		}
		d = min(d, min(ring(r, 1.04, 0.035), r - 0.08));
	} else if (pattern == 4) {
		// три больших круга внахлёст в кольце
		for (int i = 0; i < 3; i++) {
			d = min(d, ring(length(p - 0.32 * dir(PI * 0.5 + float(i) * 2.0 * PI / 3.0)), 0.55, 0.04));
		}
		d = min(d, ring(r, 0.98, 0.04));
	} else {
		// диск, орбита и пять спутников
		d = min(r - 0.18, ring(r, 0.55, 0.035));
		for (int i = 0; i < 5; i++) {
			d = min(d, circ(p, 0.55 * dir(float(i) * 2.0 * PI / 5.0 + 0.3), 0.1));
		}
		d = min(d, ring(r, 0.95, 0.04));
	}
	return max(d, r - 1.1);
}


void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec4 v = MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	float d = length(v.xyz);
	view_dist = d;
	float pull = min(depth_bias_m + d * depth_pull, d * 0.5);
	v.xyz -= v.xyz / max(d, 1e-3) * pull;
	POSITION = PROJECTION_MATRIX * v;
}


void fragment() {
	vec2 q = world_pos.xz - center;
	float c = cos(rot);
	float s = sin(rot);
	vec2 p = vec2(c * q.x + s * q.y, -s * q.x + c * q.y) / radius;
	float px = max(length(fwidth(p)), 1.0e-4);
	float m = 1.0 - smoothstep(-px, px, sdf(p));
	vec3 to_cam = INV_VIEW_MATRIX[3].xyz - world_pos;
	float sin_el = to_cam.y / max(length(to_cam), 1.0e-3);
	m *= smoothstep(view_sin.x, view_sin.y, sin_el);
	m *= 1.0 - smoothstep(fade_start_m, fade_end_m, view_dist);
	m *= strength;
	if (m < 0.004) {
		discard;
	}
	ALBEDO = mix(vec3(1.0), tint, m);
	ALPHA = 1.0;
}
