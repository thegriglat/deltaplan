// Compute-проход облаков в буфере пониженного разрешения (GLSL 450; собирается в
// cloud_compositor_effect.gd: заголовок + cloud_common.gdshaderinc + этот текст).
// Для каждого пикселя: пересечения луча с боксами всех облаков, сортировка по дальности,
// проход вперемешку по дальности (боксы соседей перекрываются) с общим пропусканием. Рельеф обрезает луч (буфер глубины).
// Одновременно в работе до MAX_HITS ближних боксов; пройденный бокс уступает место следующему
// по дальности (иначе на лучах через много боксов дальние облака пропадали — облако срезалось
// вертикальной гранью бокса ближнего соседа).
// Кучевые региона — слой поля облачности (field_march, CLF-5) в том же проходе.
// Выход: цвет с премультипликацией + непрозрачность, расстояние до сцены (для апскейла)
// и средняя глубина облака (для временного накопления).

layout(local_size_x = 8, local_size_y = 4, local_size_z = 1) in;

const int MAX_HITS = 8;
// Облака с перекрытыми по лучу боксами: длина среза (м и доля дальности), запас проходов.
const float SLICE_M = 400.0;
const float SLICE_K = 0.05;
const int MAX_PASSES = 160;

// Пройденное облако освобождает место: список уплотняется, и свободные места за один проход
// по всем облакам занимают следующие по дальности боксы — после последнего взятого
// (tn_last, id_last): порядок — по ближней границе, при равенстве — по номеру. Ждать, пока
// освободится несколько мест, нельзя: дальние облака тогда снова пропадали (проверено).

Cloud cloud_at(int i, vec3 ro, float pix_a) {
	vec4 a = clouds.d[i * CLOUD_VEC4S];
	vec4 b = clouds.d[i * CLOUD_VEC4S + 1];
	return cloud_make(vec3(a.x, 0.0, a.z), vec3(b.x, 0.0, b.y), clouds.d[i * CLOUD_VEC4S + 2],
			clouds.d[i * CLOUD_VEC4S + 3], clouds.d[i * CLOUD_VEC4S + 4], clouds.d[i * CLOUD_VEC4S + 5].x,
			ro, pix_a);
}

// Слой поля облачности (CLF-5): один отрезок луча через [основание, основание + верх поля];
// пустые блоки грубой карты (cf_max) — прыжком до границы блока (O(1) на шаг поиска); у облака —
// как в cloud_march_part: грубые шаги по оболочке, мелкие внутри, свет — cloud_light.
// Без облаков в поле (cf_on = 0) не вызывается.
void field_march(vec3 ro, vec3 rd, float scene_t, float pix_a, float ign,
		inout float trans, inout vec3 col, inout float t_acc, inout float w_acc) {
	float y0 = cf_base.x;
	float y1 = cf_base.x + cf_misc.x;
	float far_m = cf_misc.y;
	float t0 = 0.0;
	float t1 = min(scene_t, far_m);
	if (abs(rd.y) > 1e-6) {
		float ta = (y0 - ro.y) / rd.y;
		float tb = (y1 - ro.y) / rd.y;
		t0 = max(min(ta, tb), 0.0);
		t1 = min(t1, max(ta, tb));
	} else if (ro.y < y0 || ro.y > y1) {
		return;
	}
	vec2 rxz = vec2(rd.x >= 0.0 ? max(rd.x, 1e-6) : min(rd.x, -1e-6),
			rd.z >= 0.0 ? max(rd.z, 1e-6) : min(rd.z, -1e-6));
	vec2 inv = 1.0 / rxz;
	if (cf_base.z <= 0.0) {
		// Фон пуст — только сетка и полоса перехода за её краем.
		vec2 lo = cf_rect.xy - vec2(cf_edge);
		vec2 hi = cf_rect.xy + 1.0 / cf_rect.zw + vec2(cf_edge);
		vec2 a = (lo - ro.xz) * inv;
		vec2 b = (hi - ro.xz) * inv;
		vec2 mn = min(a, b);
		vec2 mx = max(a, b);
		t0 = max(t0, max(mn.x, mn.y));
		t1 = min(t1, min(mx.x, mx.y));
	}
	if (t1 <= t0) {
		return;
	}
	// Грубый шаг — как у облаков (cloud_dt_coarse): доля отрезка, не больше доли размера облака
	// (облако маски — период / 4 клетки Уорли).
	float seg = t1 - t0;
	float lod_k = clamp(t0 / lod_distance_m, 0.0, 1.0);
	float n_coarse = mix(float(coarse_steps), max(float(coarse_steps) * 0.25, 8.0), lod_k);
	float cell = cf_misc.z * 0.25;
	float dt_c = min(seg / n_coarse, cell * 0.12);
	float dt_budget = min(seg, 4.0 * cell) / float(max_iterations) * 1.5;
	float cos_t = dot(rd, sun_dir);
	float phase = mix(cloud_hg(cos_t, phase_forward) * silver, cloud_hg(cos_t, phase_back), phase_mix) * 4.0 * CLOUD_PI;
	vec3 sun_l = sun_color * sun_energy;
	int lsteps = t0 > lod_distance_m ? max(light_steps - 2, 1) : light_steps;
	float t = t0 + dt_c * ign;
	float t_exit = t0;
	bool fine = false;
	int it = 0;
	int skips = 0;
	vec4 box;
	for (int i = 0; i < 512; i++) {
		if (it >= max_iterations * 2 || t > t1 || trans < 0.01) {
			break;
		}
		vec3 p = ro + rd * t;
		vec2 mb = cf_block(p.xz, box);
		float y_top = y0 + mb.y + 60.0;
		if (mb.x <= 0.0 || p.y > y_top) {
			// Пустой блок (или выше его верха): прыжок к границе блока или к его верху.
			if (box.z > box.x && skips < 96) {
				float te = min(((rd.x > 0.0 ? box.z : box.x) - ro.x) * inv.x,
						((rd.z > 0.0 ? box.w : box.y) - ro.z) * inv.y);
				if (mb.x > 0.0 && rd.y < 0.0) {
					te = min(te, (y_top - ro.y) / rd.y);
				}
				t = max(te + 0.5, t + 1.0);
				skips++;
				fine = false;
				t_exit = t;
				continue;
			}
			if (mb.x <= 0.0) {
				it++;
				t += dt_c;
				continue;
			}
		}
		it++;
		vec4 f = cf_sample(p.xz);
		float fp = t * pix_a;
		float dt_fine = clamp(max(t * fine_step_per_m, dt_budget), fine_step_min_m, dt_c);
		if (!fine) {
			if (cf_envelope(p, f, fp) > 0.0) {
				// Вход в облако: шаг назад (не дальше прошлого выхода — без хождения по кругу).
				fine = true;
				t = max(t - dt_c, t_exit) + dt_fine * ign;
			} else {
				t += dt_c;
			}
			continue;
		}
		float top;
		float dns = cf_density_top(p, f, 2, max(fp, dt_fine * 0.5), top);
		// Дальний край слоя тает (дальше — дымка), без среза.
		dns *= 1.0 - smoothstep(far_m * 0.8, far_m, t);
		if (dns <= 0.003 && cf_envelope(p, f, fp) <= 0.0) {
			fine = false;
			t_exit = t;
			t += dt_c;
			continue;
		}
		if (dns > 0.003) {
			float sigma = dns * extinction;
			float h = p.y - y0;
			// К солнцу — шаги растут до ~половины мощности облака.
			float od = 0.0;
			float lstep = light_step_m;
			float lgrow = max(light_step_growth,
					pow(max(top * 0.5 / light_step_m, 1.0), 1.0 / float(max(lsteps - 1, 1))));
			vec3 lp = p;
			for (int j = 0; j < 8; j++) {
				if (j >= lsteps) {
					break;
				}
				lp += sun_dir * lstep;
				od += cf_density(lp, cf_sample(lp.xz), 0, max(fp, lstep)) * lstep;
				lstep *= lgrow;
			}
			// Небо над точкой закрыто толщей облака над ней; над живым подъёмом (активность) —
			// основание темнее («подсос»); бока высоких облаков освещены небом сбоку.
			float sky = exp(-max(top - h, 0.0) / sky_occlusion_m) * mix(1.0, 0.6, f.w);
			sky = mix(sky, 1.0, smoothstep(0.0, sky_occlusion_m * 1.5, h));
			vec3 S = cloud_light(dns, od, sky, clamp(h / max(top, 1.0), 0.0, 1.0), phase, sun_l) * sigma;
			float tr = exp(-sigma * dt_fine);
			col += trans * (S - S * tr) / max(sigma, 1e-6);
			float wgt = trans * (1.0 - tr);
			t_acc += t * wgt;
			w_acc += wgt;
			trans *= tr;
		}
		t += dt_fine;
	}
}

void main() {
	// Марш по четвертям (PF-7): поток — ячейка 2×2 буфера, луч — в одном её пикселе
	// (смещение ofs_x, ofs_y меняется по кадрам, обход за 4 кадра); выход — в буфер четвертей.
	// Остальные три пикселя дособирает cloud_temporal_cs из истории и свежих соседей.
	ivec2 qx = ivec2(gl_GlobalInvocationID.xy);
	ivec2 low = ivec2(sizes.xy);
	ivec2 full = ivec2(sizes.zw);
	if (qx.x >= (low.x + 1) / 2 || qx.y >= (low.y + 1) / 2) {
		return;
	}
	// На нечётном краю у ячейки может не быть пикселя со смещением — берём крайний.
	ivec2 px = min(qx * 2 + ivec2(ofs_x, ofs_y), low - 1);
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
	int n_all = 0;
	for (int i = 0; i < cloud_count; i++) {
		float tn;
		float tf;
		if (!cloud_box_hit(clouds.d[i * CLOUD_VEC4S], clouds.d[i * CLOUD_VEC4S + 1], ro, rd, tn, tf)) {
			continue;
		}
		tf = min(tf, scene_t);
		if (tf <= tn) {
			continue;
		}
		n_all++;
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
		vec4 sh = clouds.d[h_id[k] * CLOUD_VEC4S + 2];
		st[k] = cloud_march_start(max(sh.z, 10.0), max(sh.w, 10.0), h_tn[k], h_tf[k], ign);
	}
	// Боксы, ещё не взятые в работу, и последний взятый (порядок — см. выше, у MAX_PASSES).
	int pending = n_all - nh;
	float tn_last = nh > 0 ? h_tn[nh - 1] : 0.0;
	int id_last = nh > 0 ? h_id[nh - 1] : -1;
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
		if (s.x < 1e30 || pending <= 0 || trans < 0.01) {
			continue;
		}
		int na = 0;
		for (int k = 0; k < nh; k++) {
			if (st[k].x < 1e30) {
				h_tn[na] = h_tn[k];
				h_tf[na] = h_tf[k];
				h_id[na] = h_id[k];
				st[na] = st[k];
				na++;
			}
		}
		nh = na;
		for (int i = 0; i < cloud_count; i++) {
			float tn;
			float tf;
			if (!cloud_box_hit(clouds.d[i * CLOUD_VEC4S], clouds.d[i * CLOUD_VEC4S + 1], ro, rd, tn, tf)) {
				continue;
			}
			tf = min(tf, scene_t);
			if (tf <= tn || tn < tn_last || (tn == tn_last && i <= id_last)) {
				continue;
			}
			if (nh == MAX_HITS) {
				if (tn >= h_tn[MAX_HITS - 1]) {
					continue;
				}
				nh = MAX_HITS - 1;
			}
			int j = nh;
			while (j > na && h_tn[j - 1] > tn) {
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
		pending -= nh - na;
		if (nh > na) {
			tn_last = h_tn[nh - 1];
			id_last = h_id[nh - 1];
		}
		for (int k = na; k < nh; k++) {
			vec4 sh = clouds.d[h_id[k] * CLOUD_VEC4S + 2];
			st[k] = cloud_march_start(max(sh.z, 10.0), max(sh.w, 10.0), h_tn[k], h_tf[k], ign);
		}
	}
	if (cf_on > 0.5) {
		// Слой поля — отдельно, затем «ближнее поверх дальнего» по средней глубине (записи — линзы,
		// шапка, Cb — со слоем по лучу почти не перекрываются).
		float trans_f = 1.0;
		vec3 col_f = vec3(0.0);
		float ta_f = 0.0;
		float wa_f = 0.0;
		field_march(ro, rd, scene_t, pix_a, ign, trans_f, col_f, ta_f, wa_f);
		if (wa_f > 0.0) {
			bool field_first = w_acc <= 0.0 || ta_f / wa_f < t_acc / w_acc;
			col = field_first ? col_f + trans_f * col : col + trans * col_f;
			trans *= trans_f;
			t_acc += ta_f;
			w_acc += wa_f;
		}
	}
	float alpha = 1.0 - trans;
	// Дымка по средней глубине облака.
	float dist = w_acc > 0.0 ? t_acc / w_acc : scene_t;
	float fog = 1.0 - exp(-dist * fog_density);
	float cos_t = dot(rd, sun_dir);
	vec3 fc = fog_color * (1.0 + fog_sun_scatter * pow(max(cos_t, 0.0), 8.0));
	col = col * (1.0 - fog) + fc * alpha * fog;
	imageStore(out_cloud, qx, vec4(col, alpha));
	// r — расстояние до сцены (вес соседей в cloud_temporal_cs), g — средняя глубина облака
	// (перепроекция истории).
	imageStore(out_depth, qx, vec4(scene_t, dist, 0.0, 0.0));
}
