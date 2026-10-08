// Сборка буфера облаков из марша по четвертям и истории (GLSL 450; PF-7).
// Марш (cloud_raymarch_cs) за кадр считает луч только в одном пикселе из каждого блока 2×2
// (смещение ofs меняется по кадрам, обход за 4 кадра) и пишет в буфер четвертей. Здесь для
// каждого пикселя буфера облаков:
//  - свежий (луч этого кадра) — смешивается с историей с весом w_fresh;
//  - остальные — история с перепроекцией по средней глубине облака, зажатая в диапазон свежих
//    соседей, и слабая подмешка (w_fill) оценки по свежим соседям.
// Без шлейфа там, где истории нет: старт или смена размера, перепроекция за кадр, разрыв по
// глубине рельефа (история видела другую поверхность) — пиксель берётся из свежих соседей
// (гауссов вес по расстоянию, билатеральный — по глубине сцены), а не из старого кадра.
// Начало луча в марше дрожит по пикселям и по кадрам; накопление его усредняет, иначе тонкие
// места облака распадаются на «растровые точки».

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D q_tex;      // марш, буфер четвертей
layout(set = 0, binding = 1) uniform sampler2D q_depth;    // r — до сцены, g — до облака
layout(set = 0, binding = 2) uniform sampler2D hist_tex;   // история (прошлый кадр)
layout(rgba16f, set = 0, binding = 3) uniform writeonly image2D out_hist;
layout(set = 0, binding = 4, std140) uniform Tp {
	mat4 inv_proj;     // текущая проекция⁻¹
	mat4 reproj;       // вид текущего кадра → клип прошлого
	mat4 prev_view;    // вид текущего кадра → вид прошлого
	vec4 sizes;        // низкое w, h; полное w, h
	vec4 wts;          // x — вес свежего луча, y — вес оценки по соседям, z — история есть (1/0)
	ivec4 ofs;         // xy — смещение свежего пикселя в блоке 2×2
} tp;
layout(set = 0, binding = 5) uniform sampler2D depth_tex;  // глубина сцены, полное разрешение
layout(set = 0, binding = 6) uniform sampler2D hist_depth; // r — до сцены в прошлом кадре
layout(rg32f, set = 0, binding = 7) uniform writeonly image2D out_depth;

// Расстояние до сцены, как в марше: ближайшая геометрия в блоке полного разрешения.
float scene_dist(ivec2 px, ivec2 low, ivec2 full, vec2 ndc) {
	ivec2 f0 = ivec2(vec2(px) * vec2(full) / vec2(low));
	ivec2 f1 = min(ivec2(vec2(px + 1) * vec2(full) / vec2(low)), full) - 1;
	float dmax = 0.0;
	for (int y = f0.y; y <= f1.y; y++) {
		for (int x = f0.x; x <= f1.x; x++) {
			dmax = max(dmax, texelFetch(depth_tex, ivec2(x, y), 0).r);
		}
	}
	vec4 vp = tp.inv_proj * vec4(ndc, dmax, 1.0);
	return length(vp.xyz / vp.w);
}

void main() {
	ivec2 px = ivec2(gl_GlobalInvocationID.xy);
	ivec2 low = ivec2(tp.sizes.xy);
	ivec2 full = ivec2(tp.sizes.zw);
	if (px.x >= low.x || px.y >= low.y) {
		return;
	}
	ivec2 o = tp.ofs.xy;
	ivec2 qn = (low + 1) / 2;
	vec2 uv = (vec2(px) + 0.5) / vec2(low);
	vec2 ndc = uv * 2.0 - 1.0;
	vec4 vn = tp.inv_proj * vec4(ndc, 1.0, 1.0);
	vec3 dir_v = normalize(vn.xyz / vn.w);

	ivec2 qs = px >> 1;
	bool fresh = all(equal(min(qs * 2 + o, low - 1), px));
	vec4 own = vec4(0.0);
	float t_own;
	float d_own = 0.0;
	if (fresh) {
		own = texelFetch(q_tex, qs, 0);
		vec2 dd = texelFetch(q_depth, qs, 0).rg;
		t_own = dd.r;
		d_own = dd.g;
	} else {
		t_own = scene_dist(px, low, full, ndc);
	}

	// Свежие соседи: ячейки четвертей вокруг пикселя, гауссов вес по расстоянию до их пикселя
	// (σ ≈ 0,85 пикселя буфера), билатеральный — по глубине сцены.
	ivec2 q0 = ivec2(floor(vec2(px - o) * 0.5));
	vec4 acc = vec4(0.0);
	float wsum = 0.0;
	float dacc = 0.0;
	float dw = 0.0;
	vec4 best = vec4(0.0);
	float best_err = 1e30;
	float best_d = t_own;
	vec4 mn = vec4(1e30);
	vec4 mx = vec4(-1e30);
	for (int j = -1; j <= 2; j++) {
		for (int i = -1; i <= 2; i++) {
			ivec2 q = clamp(q0 + ivec2(i, j), ivec2(0), qn - 1);
			vec2 dq = vec2(min(q * 2 + o, low - 1) - px);
			float r2 = dot(dq, dq);
			vec4 c = texelFetch(q_tex, q, 0);
			vec2 dd = texelFetch(q_depth, q, 0).rg;
			float err = abs(log(max(dd.r, 1e-3) / max(t_own, 1e-3)));
			float wd = exp(-err * 12.0);
			float w = exp(-r2 * 0.7) * wd;
			acc += c * w;
			wsum += w;
			float wa = w * (c.a + 0.02);
			dacc += dd.g * wa;
			dw += wa;
			if (err < best_err) {
				best_err = err;
				best = c;
				best_d = dd.g;
			}
			// Диапазон для истории — ближние свежие пиксели той же поверхности.
			if (r2 <= 5.5 && wd > 0.1) {
				mn = min(mn, c);
				mx = max(mx, c);
			}
		}
	}
	vec4 est = wsum > 1e-4 ? acc / wsum : best;
	float d_est = dw > 1e-6 ? dacc / dw : best_d;
	vec4 cur = fresh ? own : est;
	float dist = fresh ? d_own : d_est;
	if (fresh) {
		mn = min(mn, own);
		mx = max(mx, own);
	}
	if (mn.a > mx.a) {
		mn = est;
		mx = est;
	}
	imageStore(out_depth, px, vec4(t_own, dist, 0.0, 0.0));

	if (tp.wts.z < 0.5) {
		imageStore(out_hist, px, cur);
		return;
	}
	dist = min(dist, 2.0e5);
	vec4 pc = tp.reproj * vec4(dir_v * dist, 1.0);
	vec2 puv = pc.w > 1e-6 ? (pc.xy / pc.w) * 0.5 + 0.5 : vec2(-1.0);
	if (any(lessThan(puv, vec2(0.0))) || any(greaterThan(puv, vec2(1.0)))) {
		imageStore(out_hist, px, cur);
		return;
	}
	// Разрыв по глубине рельефа: прошлый кадр в этой точке видел другую поверхность (гора
	// открыла небо или закрыла облако) — истории нет.
	vec4 ps = tp.reproj * vec4(dir_v * min(t_own, 2.0e5), 1.0);
	if (ps.w > 1e-6) {
		vec2 suv = (ps.xy / ps.w) * 0.5 + 0.5;
		float t_exp = min(length((tp.prev_view * vec4(dir_v * t_own, 1.0)).xyz), 3.0e4);
		float t_hist = min(textureLod(hist_depth, clamp(suv, vec2(0.0), vec2(1.0)), 0.0).r, 3.0e4);
		if (abs(log(max(t_exp, 1.0) / max(t_hist, 1.0))) > 0.15) {
			imageStore(out_hist, px, cur);
			return;
		}
	}
	// Диапазон чуть шире разброса свежих соседей: их мало (2–5), иначе пиксель дрожит вслед
	// за дрожанием луча.
	vec4 ext = (mx - mn) * 0.25;
	vec4 hist = clamp(textureLod(hist_tex, puv, 0.0), mn - ext, mx + ext);
	imageStore(out_hist, px, mix(hist, cur, fresh ? tp.wts.x : tp.wts.y));
}
