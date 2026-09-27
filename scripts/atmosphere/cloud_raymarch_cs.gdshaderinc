// Compute-проход облаков в буфере пониженного разрешения (GLSL 450; собирается в
// cloud_compositor_effect.gd: заголовок + cloud_common.gdshaderinc + этот текст).
// Для каждого пикселя: пересечения луча с боксами всех облаков, сортировка по дальности,
// проход через каждое по порядку с общим пропусканием. Рельеф обрезает луч (буфер глубины).
// Выход: цвет с премультипликацией + непрозрачность, и расстояние до сцены (для апскейла).

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

const int MAX_HITS = 8;

void main() {
	ivec2 px = ivec2(gl_GlobalInvocationID.xy);
	ivec2 low = ivec2(sizes.xy);
	ivec2 full = ivec2(sizes.zw);
	if (px.x >= low.x || px.y >= low.y) {
		return;
	}
	vec2 uv = (vec2(px) + 0.5) / vec2(low);
	// Ближайшая геометрия в блоке полного разрешения — облако не «наползает» на горы.
	ivec2 f0 = ivec2(vec2(px) * vec2(full) / vec2(low));
	ivec2 f1 = min(ivec2(vec2(px + 1) * vec2(full) / vec2(low)), full) - 1;
	float dmax = 0.0;
	for (int y = f0.y; y <= f1.y; y++) {
		for (int x = f0.x; x <= f1.x; x++) {
			dmax = max(dmax, texelFetch(depth_tex, ivec2(x, y), 0).r);
		}
	}
	vec2 ndc = uv * 2.0 - 1.0;
	vec4 vp = inv_proj * vec4(ndc, dmax, 1.0);
	float scene_t = length(vp.xyz / vp.w);
	vec4 vn = inv_proj * vec4(ndc, 1.0, 1.0);
	vec3 rd_v = normalize(vn.xyz / vn.w);
	vec4 vn2 = inv_proj * vec4(ndc + vec2(0.0, 2.0 / float(low.y)), 1.0, 1.0);
	float pix_a = length(normalize(vn2.xyz / vn2.w) - rd_v);
	vec3 ro = cam_to_world[3].xyz;
	vec3 rd = normalize(mat3(cam_to_world) * rd_v);

	// Пересечения с боксами, сортировка вставкой по ближней границе.
	float h_tn[MAX_HITS];
	float h_tf[MAX_HITS];
	int h_id[MAX_HITS];
	int nh = 0;
	for (int i = 0; i < cloud_count; i++) {
		float tn;
		float tf;
		if (!cloud_box_hit(clouds.d[i * 5], clouds.d[i * 5 + 1], ro, rd, tn, tf)) {
			continue;
		}
		tf = min(tf, scene_t);
		if (tf <= tn) {
			continue;
		}
		if (nh == MAX_HITS) {
			if (tn >= h_tn[MAX_HITS - 1]) {
				continue;
			}
			nh = MAX_HITS - 1;
		}
		int j = nh;
		while (j > 0 && h_tn[j - 1] > tn) {
			h_tn[j] = h_tn[j - 1];
			h_tf[j] = h_tf[j - 1];
			h_id[j] = h_id[j - 1];
			j--;
		}
		h_tn[j] = tn;
		h_tf[j] = tf;
		h_id[j] = i;
		nh++;
	}

	float trans = 1.0;
	vec3 col = vec3(0.0);
	float t_acc = 0.0;
	float w_acc = 0.0;
	// Белый шум без структуры (IGN после апскейла даёт штриховку).
	float ign = fract(sin(dot(vec2(px), vec2(12.9898, 78.233))) * 43758.5453);
	for (int k = 0; k < nh; k++) {
		if (trans < 0.01) {
			break;
		}
		int i = h_id[k];
		vec4 a = clouds.d[i * 5];
		vec4 b = clouds.d[i * 5 + 1];
		Cloud cl = cloud_make(vec3(a.x, 0.0, a.z), vec3(b.x, 0.0, b.y), clouds.d[i * 5 + 2],
				clouds.d[i * 5 + 3], clouds.d[i * 5 + 4], ro, pix_a);
		cloud_march(cl, ro, rd, h_tn[k], h_tf[k], ign, trans, col, t_acc, w_acc);
	}
	float alpha = 1.0 - trans;
	// Дымка по средней глубине облака.
	float dist = w_acc > 0.0 ? t_acc / w_acc : scene_t;
	float fog = 1.0 - exp(-dist * fog_density);
	float cos_t = dot(rd, sun_dir);
	vec3 fc = fog_color * (1.0 + fog_sun_scatter * pow(max(cos_t, 0.0), 8.0));
	col = col * (1.0 - fog) + fc * alpha * fog;
	imageStore(out_cloud, px, vec4(col, alpha));
	imageStore(out_depth, px, vec4(scene_t, 0.0, 0.0, 0.0));
}
