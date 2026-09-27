// Апскейл облаков из буфера пониженного разрешения и наложение на кадр (GLSL 450).
// Билатеральный фильтр: из окна 4×4 низкорезных пикселей берутся те, у которых глубина сцены
// близка к глубине текущего пикселя — облака не «ореолят» по контуру гор.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform image2D color_image;
layout(set = 0, binding = 1) uniform sampler2D cloud_tex;
layout(set = 0, binding = 2) uniform sampler2D cloud_depth;
layout(set = 0, binding = 3) uniform sampler2D depth_tex;

layout(push_constant, std430) uniform Pc {
	mat4 inv_proj;
	vec4 sizes;   // низкое w, h, полное w, h
} pc;

void main() {
	ivec2 px = ivec2(gl_GlobalInvocationID.xy);
	ivec2 full = ivec2(pc.sizes.zw);
	ivec2 low = ivec2(pc.sizes.xy);
	if (px.x >= full.x || px.y >= full.y) {
		return;
	}
	vec2 uv = (vec2(px) + 0.5) / vec2(full);
	float d = texelFetch(depth_tex, px, 0).r;
	vec4 vp = pc.inv_proj * vec4(uv * 2.0 - 1.0, d, 1.0);
	float t_own = length(vp.xyz / vp.w);

	vec2 f = uv * vec2(low) - 0.5;
	ivec2 b = ivec2(floor(f));
	vec2 fr = f - vec2(b);
	vec4 acc = vec4(0.0);
	float wsum = 0.0;
	vec4 best = vec4(0.0);
	float best_err = 1e30;
	// Окно 4×4 низкорезных пикселей с гауссовым весом (σ ≈ 0,8 пикселя буфера) добирает
	// остаток дрожания начала луча после временного накопления (cloud_temporal_cs) — иначе
	// тонкие места облака видны «растровыми точками». Вес по глубине оставляет контур гор резким.
	for (int j = -1; j < 3; j++) {
		for (int i = -1; i < 3; i++) {
			ivec2 q = clamp(b + ivec2(i, j), ivec2(0), low - 1);
			vec4 c = texelFetch(cloud_tex, q, 0);
			float t = texelFetch(cloud_depth, q, 0).r;
			float err = abs(log(max(t, 1e-3) / max(t_own, 1e-3)));
			vec2 dq = vec2(i, j) - fr;
			float wb = exp(-dot(dq, dq) * 0.78);
			float w = wb * exp(-err * 12.0);
			acc += c * w;
			wsum += w;
			if (err < best_err) {
				best_err = err;
				best = c;
			}
		}
	}
	vec4 cloud = wsum > 1e-4 ? acc / wsum : best;
	vec4 col = imageLoad(color_image, px);
	col.rgb = cloud.rgb + col.rgb * (1.0 - cloud.a);
	imageStore(color_image, px, col);
}
