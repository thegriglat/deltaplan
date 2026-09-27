// Временное накопление облаков в буфере пониженного разрешения (GLSL 450).
// Начало луча в raymarch дрожит по пикселям и по кадрам; без накопления тонкие места облака
// (шаг луча толще клуба — его находит лишь часть лучей) распадаются на «растровые точки».
// Здесь кадр смешивается с историей, перепроецированной по средней глубине облака; история
// зажата в диапазон соседей текущего кадра 3×3 — при движении не тянется шлейф.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D cur_tex;
layout(set = 0, binding = 1) uniform sampler2D cur_depth;
layout(set = 0, binding = 2) uniform sampler2D hist_tex;
layout(rgba16f, set = 0, binding = 3) uniform writeonly image2D out_hist;
layout(set = 0, binding = 4, std140) uniform Tp {
	mat4 inv_proj;     // текущая проекция⁻¹
	mat4 reproj;       // вид текущего кадра → клип прошлого
	vec4 sizes;        // низкое w, h; x — вес нового кадра (1 — без истории)
} tp;

void main() {
	ivec2 px = ivec2(gl_GlobalInvocationID.xy);
	ivec2 low = ivec2(tp.sizes.xy);
	if (px.x >= low.x || px.y >= low.y) {
		return;
	}
	vec4 cur = texelFetch(cur_tex, px, 0);
	float w_new = tp.sizes.z;
	if (w_new >= 1.0) {
		imageStore(out_hist, px, cur);
		return;
	}
	vec4 mn = cur;
	vec4 mx = cur;
	for (int j = -1; j <= 1; j++) {
		for (int i = -1; i <= 1; i++) {
			vec4 c = texelFetch(cur_tex, clamp(px + ivec2(i, j), ivec2(0), low - 1), 0);
			mn = min(mn, c);
			mx = max(mx, c);
		}
	}
	vec2 uv = (vec2(px) + 0.5) / vec2(low);
	vec4 vn = tp.inv_proj * vec4(uv * 2.0 - 1.0, 1.0, 1.0);
	vec3 dir_v = normalize(vn.xyz / vn.w);
	float dist = min(texelFetch(cur_depth, px, 0).g, 2.0e5);
	vec4 pc = tp.reproj * vec4(dir_v * dist, 1.0);
	vec2 puv = pc.w > 1e-6 ? (pc.xy / pc.w) * 0.5 + 0.5 : vec2(-1.0);
	if (any(lessThan(puv, vec2(0.0))) || any(greaterThan(puv, vec2(1.0)))) {
		imageStore(out_hist, px, cur);
		return;
	}
	vec4 hist = clamp(textureLod(hist_tex, puv, 0.0), mn, mx);
	imageStore(out_hist, px, mix(hist, cur, w_new));
}
