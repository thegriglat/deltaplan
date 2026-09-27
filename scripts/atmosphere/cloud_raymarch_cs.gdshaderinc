// Compute-проход облаков в буфере пониженного разрешения (GLSL 450; собирается в
// cloud_compositor_effect.gd: заголовок + cloud_common.gdshaderinc + этот текст).
// Для каждого пикселя: пересечения луча с боксами всех облаков, сортировка по дальности,
// проход вперемешку по дальности (боксы соседей перекрываются) с общим пропусканием. Рельеф обрезает луч (буфер глубины).
// Выход: цвет с премультипликацией + непрозрачность, расстояние до сцены (для апскейла)
// и средняя глубина облака (для временного накопления).

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

const int MAX_HITS = 8;
// Облака с перекрытыми по лучу боксами: длина среза (м и доля дальности), запас проходов.
const float SLICE_M = 400.0;
const float SLICE_K = 0.05;
const int MAX_PASSES = 96;

Cloud cloud_at(int i, vec3 ro, float pix_a) {
	vec4 a = clouds.d[i * 5];
	vec4 b = clouds.d[i * 5 + 1];
	return cloud_make(vec3(a.x, 0.0, a.z), vec3(b.x, 0.0, b.y), clouds.d[i * 5 + 2],
			clouds.d[i * 5 + 3], clouds.d[i * 5 + 4], ro, pix_a);
}

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
	// Дрожание начала луча: IGN (равномерно по соседним пикселям) со сдвигом по золотому
	// сечению от кадра к кадру — cloud_temporal_cs усредняет его, точки не видны.
	float ign = fract(52.9829189 * fract(dot(vec2(px), vec2(0.06711056, 0.00583715)))
			+ float(frame % 64) * 0.61803399);
	// Боксы соседних облаков перекрываются по лучу: проходить облака целиком по ближней
	// границе бокса нельзя — дальнее облако ложится поверх ближнего, и при смене порядка
	// (облако выросло, камера сдвинулась) картинка скачет. Поэтому облака идут вперемешку:
	// всегда шагает то, чья текущая точка ближе, до точки следующего + срез.
	vec4 st[MAX_HITS];
	for (int k = 0; k < nh; k++) {
		// Полуоси — как в cloud_make (без сборки облака).
		vec4 sh = clouds.d[h_id[k] * 5 + 2];
		st[k] = cloud_march_start(max(sh.z, 10.0), max(sh.w, 10.0), h_tn[k], h_tf[k], ign);
	}
	for (int pass = 0; pass < MAX_PASSES; pass++) {
		if (trans < 0.01) {
			break;
		}
		int kmin = -1;
		float t1 = 1e29;
		float t2 = 1e30;
		for (int k = 0; k < nh; k++) {
			float tk = st[k].x;
			if (tk < t1) {
				t2 = t1;
				t1 = tk;
				kmin = k;
			} else if (tk < t2) {
				t2 = tk;
			}
		}
		if (kmin < 0) {
			break;
		}
		// Последний проход — до конца (запас по числу проходов исчерпан).
		float stop = pass == MAX_PASSES - 1 ? 1e30 : t2 + max(SLICE_M, t1 * SLICE_K);
		vec4 s = st[kmin];
		cloud_march_part(cloud_at(h_id[kmin], ro, pix_a), ro, rd, h_tn[kmin], h_tf[kmin], ign,
				stop, s, trans, col, t_acc, w_acc);
		st[kmin] = s;
	}
	float alpha = 1.0 - trans;
	// Дымка по средней глубине облака.
	float dist = w_acc > 0.0 ? t_acc / w_acc : scene_t;
	float fog = 1.0 - exp(-dist * fog_density);
	float cos_t = dot(rd, sun_dir);
	vec3 fc = fog_color * (1.0 + fog_sun_scatter * pow(max(cos_t, 0.0), 8.0));
	col = col * (1.0 - fog) + fc * alpha * fog;
	imageStore(out_cloud, px, vec4(col, alpha));
	// r — расстояние до сцены (апскейл), g — средняя глубина облака (перепроекция истории).
	imageStore(out_depth, px, vec4(scene_t, dist, 0.0, 0.0));
}
