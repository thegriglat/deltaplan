// Покров земли (GR-25, G2 v2): одно правило «здесь скала / выход породы / осыпь» для шейдера рельефа
// (terrain_main.gdshaderinc рисует по нему породу) и для травы (grass.gdshader, grass_mid_shell,
// grass_mid_cards: травы там нет; CPU-копия — GrassField.height_at). Нужен terrain_common.gdshaderinc
// (h_node, vnoise, fbm, rock_slope_deg, rock_blend_deg) до этого include.
// Параметры — configs/world.json → terrain_look (числа здесь — значения по умолчанию шейдера рельефа).

// кромки материалов (трава/скала/осыпь/снег в кулуарах): узкий переход по рваной кромке вместо
// широкой плавной смеси; ширина не уже ~пикселя
uniform float material_edge_noise = 0.5;          // сдвиг кромки шумом 7–25 м (доля веса)
uniform float material_edge_hw = 0.06;            // полуширина перехода (доля веса)
// выпуклость рельефа (−лапласиан, м/м) в масштабе outcrop_scale_m
uniform float outcrop_scale_m = 35.0;             // масштаб кривизны (гребни, бугры), м
uniform float outcrop_convex_k = 0.035;           // выпуклость (м/м), с которой гребень каменистый
uniform vec2 outcrop_slope_deg = vec2(25.0, 36.0); // уклон начала/полной силы выходов породы
uniform float outcrop_patch_m = 45.0;             // размер пятен породы, м
uniform float outcrop_amount = 0.9;
uniform float outcrop_ribs = 0.6;                 // доля «рёбер вдоль линии падения» в пятнах породы на крутом
uniform vec2 band_size_m = vec2(28.0, 170.0);     // полосы травы: поперёк × вдоль линии падения, м
uniform float scree_probe_m = 35.0;               // где искать обрыв выше по склону, м
uniform float scree_min_deg = 18.0;               // осыпь лежит на склоне круче этого (и положе скал)

// Анизотропный шум полос вдоль линии падения d (гориз. вектор вниз по склону): три фиксированных
// направления 0/60/120° смешиваются по близости к d — без поворота координат (он рвёт шум
// там, где меняется экспозиция).
float fall_bands(vec2 p, vec2 d) {
	float acc = 0.0;
	float wsum = 1e-4;
	for (int i = 0; i < 3; i++) {
		float a = float(i) * 1.0472;
		vec2 e = vec2(cos(a), sin(a));
		float c2 = dot(d, e);
		float w = max(pow(c2 * c2, 4.0) - 0.03, 0.0);   // малые веса — без выборки, без скачка
		vec2 q = vec2(dot(p, vec2(-e.y, e.x)) / band_size_m.x, dot(p, e) / band_size_m.y);
		if (w > 0.0) {
			acc += w * vnoise(q + float(i) * 17.3);
			wsum += w;
		}
	}
	return acc / wsum;
}

// Нормаль по билинейной поверхности в точке (градиент внутри клетки сетки).
vec3 bilinear_normal(vec2 xz) {
	vec2 f = (xz - layer_origin) / layer_spacing;
	vec2 i = floor(f);
	vec2 t = f - i;
	ivec2 ij = ivec2(i);
	float a = h_node(ij);
	float b = h_node(ij + ivec2(1, 0));
	float c = h_node(ij + ivec2(0, 1));
	float d = h_node(ij + ivec2(1, 1));
	float dhdx = mix(b - a, d - c, t.y) / layer_spacing;
	float dhdz = mix(c - a, d - b, t.x) / layer_spacing;
	return normalize(vec3(-dhdx, 1.0, -dhdz));
}

// Рваная узкая кромка материала: вес w (0..1, плавный) → почти ступенька по изолинии 0,5,
// сдвинутой шумом 7–25 м (мелкий слой гаснет, когда мельче пикселя: подставляется его среднее);
// переход не уже ~1,5 пикселя foot (без «лесенки»).
float ragged_edge(float w, vec2 p, float foot) {
	if (w <= 0.0 || w >= 1.0) {
		return w;
	}
	float kf = 1.0 - smoothstep(2.0, 6.0, foot);
	float nz = vnoise(p / 23.0 + vec2(3.7, 8.1)) * 0.6
			+ mix(0.5, vnoise(p / 7.0 + vec2(1.3, 5.9)), kf) * 0.4;
	float hw = clamp(material_edge_hw + foot * 0.015, material_edge_hw, 0.5);
	return smoothstep(0.5 - hw, 0.5 + hw, w + material_edge_noise * (nz - 0.5));
}

// Скалы: доля по уклону (с шумом 40 м и рваной кромкой) до умножения на долю открытых классов.
float gc_rock(vec2 p, float slope_deg, float foot) {
	float rnoise = fbm(p / 40.0 + vec2(5.1, 2.3), 3);
	return ragged_edge(smoothstep(rock_slope_deg - rock_blend_deg * 0.5, rock_slope_deg + rock_blend_deg * 0.5,
			slope_deg + 10.0 * (rnoise - 0.5)), p, foot);
}

// Выходы породы на гребнях/буграх (выпуклость cv = −лапласиан / outcrop_convex_k) и крутых лугах:
// доля до умножения на долю открытых классов; convex/steep — для курумника рельефа. kfar — гашение
// вдали (рельеф), трава — 1.
float gc_outcrop(vec2 p, float slope_deg, vec3 n_class, float cv, float foot, float kfar,
		out float convex, out float steep, out float drv) {
	convex = smoothstep(0.25, 1.0, cv);
	steep = smoothstep(outcrop_slope_deg.x, outcrop_slope_deg.y, slope_deg);
	drv = max(convex, steep);
	if (drv <= 0.01) {
		return 0.0;
	}
	// пятна породы рваные: крупный шум + дробление 3–10 м (гаснет, когда мельче пикселя)
	float kf = 1.0 - smoothstep(2.0, 8.0, foot);
	float brk = vnoise(p / (outcrop_patch_m * 0.18));
	if (kf > 0.0) {
		brk = mix(brk, brk * 0.6 + vnoise(p / (outcrop_patch_m * 0.06) + vec2(3.7, 0.4)) * 0.4, kf);
	}
	float pn = fbm(p / outcrop_patch_m + vec2(12.7, 3.1), 2);
	// на крутом порода выходит рёбрами между кулуарами (вытянуты вдоль линии падения)
	if (steep > 0.01 && outcrop_ribs > 0.0) {
		vec2 dn0 = length(n_class.xz) > 1e-4 ? normalize(n_class.xz) : vec2(1.0, 0.0);
		pn = mix(pn, fall_bands(p + vec2(31.3, 17.9), dn0), outcrop_ribs * steep);
	}
	pn += 0.2 * (brk - 0.5);
	return smoothstep(0.5, 0.56, pn + 0.2 * (drv - 1.0)) * smoothstep(0.0, 0.3, drv)
			* outcrop_amount * kfar;
}

// Осыпь у подножия крутых участков: slope_up — уклон в scree_probe_m выше по склону; доля до
// умножения на (1 − скалы) и долю открытых классов.
float gc_scree(vec2 p, float slope_deg, float slope_up, float foot) {
	return ragged_edge(smoothstep(rock_slope_deg - 2.0, rock_slope_deg + 8.0, slope_up)
			* smoothstep(6.0, 14.0, slope_up - slope_deg)
			* smoothstep(scree_min_deg - 4.0, scree_min_deg + 4.0, slope_deg)
			* smoothstep(0.35, 0.6, fbm(p / 30.0 + vec2(4.4, 0.7), 3) + 0.15), p + 41.0, foot)
			* 0.85;
}

// Выпуклость (−лапласиан на шаге outcrop_scale_m, м/м) в узле — как v_convex вершины рельефа LOD 0.
float gc_convex_node(ivec2 ij, int k) {
	float gr = float(k) * layer_spacing;
	return -(h_node(ij + ivec2(k, 0)) + h_node(ij - ivec2(k, 0)) + h_node(ij + ivec2(0, k))
			+ h_node(ij - ivec2(0, k)) - 4.0 * h_node(ij)) / (4.0 * gr);
}

// --- трава ---
// Доля луга, не закрытая породой, в точке xz (n — нормаль билинейной клетки, как у травы): скалы,
// выходы породы, осыпь — те же функции, что у рельефа (на открытом классе, вблизи: kfar = 1, след
// пикселя gc_foot_m); выпуклость — билинейно по узлам (вершины LOD 0 рельефа интерполируют её
// линейно по треугольнику). Класс: 3 (пашня) — только скалы, 1 (лес) — породы нет (её нет и у рельефа).
// Отличия от рельефа (границы): уклон — билинейной клетки (у рельефа — центральные разности по
// мипам), без поправки кромки леса и без голого грунта класса 5 (его трава не берёт по классу).
const float GC_FOOT_M = 0.05;
float gc_meadow(vec2 xz, vec3 n, int c) {
	if (c == 1) {
		return 1.0;
	}
	float slope_deg = degrees(acos(clamp(n.y, 0.0, 1.0)));
	float rock = gc_rock(xz, slope_deg, GC_FOOT_M);
	if (c == 3) {
		return 1.0 - rock;
	}
	vec2 f = (xz - layer_origin) / layer_spacing;
	vec2 i = floor(f);
	vec2 t = f - i;
	ivec2 ij = ivec2(i);
	int k = max(int(round(outcrop_scale_m / layer_spacing)), 1);
	float cvx = mix(mix(gc_convex_node(ij, k), gc_convex_node(ij + ivec2(1, 0), k), t.x),
			mix(gc_convex_node(ij + ivec2(0, 1), k), gc_convex_node(ij + ivec2(1, 1), k), t.x), t.y);
	float cv;
	float st;
	float drv;
	float ocw = 0.0;
	if (outcrop_amount > 0.0) {
		ocw = gc_outcrop(xz, slope_deg, n, cvx / outcrop_convex_k, GC_FOOT_M, 1.0, cv, st, drv) * (1.0 - rock);
	}
	float scree = 0.0;
	if (slope_deg > scree_min_deg - 4.0) {
		vec2 up_dir = length(n.xz) > 1e-3 ? -normalize(n.xz) : vec2(0.0);
		vec3 n_up = bilinear_normal(xz + up_dir * scree_probe_m);
		float slope_up = degrees(acos(clamp(n_up.y, 0.0, 1.0)));
		scree = gc_scree(xz, slope_deg, slope_up, GC_FOOT_M) * (1.0 - rock);
	}
	// рельеф смешивает последовательно: осыпь, выходы, скалы — доля луга в цвете
	return (1.0 - scree) * (1.0 - ocw) * (1.0 - rock);
}

// Доля пучков травы по доле луга m: ниже stone_keep.x — травы нет (порода рельефа закрывает ≥ 85 %
// пятна: смесь 0,1–0,15 цвета луга — оттенок, не трава), выше stone_keep.y — вся.
uniform vec2 stone_keep = vec2(0.15, 0.65);
float gc_grass_keep(vec2 xz, vec3 n, int c) {
	return smoothstep(stone_keep.x, stone_keep.y, gc_meadow(xz, n, c));
}

// Карта доли пучков вокруг камеры (GrassField: та же gc_grass_keep, запечённая на GPU в текстуру
// stone_mask_px² на stone_mask_m — раз на сдвиг камеры, не в каждой вершине каждого пучка): одна
// выборка вместо ~30 выборок высот и шума. Вне карты (кольца травинок режима blades дальше 64 м) или
// до первого запекания — расчёт на месте.
uniform sampler2D stone_mask_tex : filter_linear, repeat_disable, hint_default_white;
uniform vec4 stone_mask_rect = vec4(0.0);   // xy — мировые X/Z угла карты, м; zw — 1 / размер, 1/м
uniform bool stone_mask_on = false;
float gc_grass_keep_fast(vec2 xz, vec3 n, int c) {
	if (stone_mask_on) {
		vec2 uv = (xz - stone_mask_rect.xy) * stone_mask_rect.zw;
		if (uv.x > 0.0 && uv.y > 0.0 && uv.x < 1.0 && uv.y < 1.0) {
			return textureLod(stone_mask_tex, uv, 0.0).r;
		}
	}
	return gc_grass_keep(xz, n, c);
}
