// Травинки вокруг камеры (VR-17, VR-6): пучки на сетке, привязанной к миру (при движении не
// «прыгают»), MultiMesh без трансформов — положение, высоту и цвет каждого пучка считает шейдер.
// Где трава — решает карта поверхности (луг, пашня — выше, кустарник — реже, лес — реже, ниже и
// темнее, тень полога; скалы, вода, застройка — нет); цвет — цвет земли луга в этой точке (meadow_look.gdshaderinc: палитра,
// влажность, экспозиция, пятна с высоты — как рисует terrain.gdshader). Качание — тем же полем
// ветра, что колышет рельеф (порывы, термики), приминание у ног пилота. Параметры задаёт
// GrassField из configs/vegetation.json → grass.
shader_type spatial;
render_mode cull_disabled, diffuse_lambert_wrap, world_vertex_coords, specular_disabled;

#include "res://scripts/terrain/terrain_common.gdshaderinc"
#include "res://scripts/terrain/ground_cover.gdshaderinc"   // скалы, выходы породы, осыпь — как у рельефа (GR-25)
#include "res://scripts/terrain/terrain_wind.gdshaderinc"
#include "res://scripts/terrain/meadow_look.gdshaderinc"
#include "res://scripts/terrain/scene_look.gdshaderinc" // SL
#include "res://scripts/terrain/cloud_shadow.gdshaderinc"

uniform vec2 grid_center_cell;
uniform float clump_spacing_m = 0.5;
uniform float area_radius_m = 35.0;
uniform vec2 blade_height_m = vec2(0.25, 0.55);   // луг, мин/макс
uniform vec2 crop_height_m = vec2(0.6, 0.9);      // посевы (нива)
uniform float shrub_density = 0.5;
// трава под пологом леса (К2 v2): доля пучков, высота мин/макс, множитель цвета (тень полога)
uniform float forest_density = 0.0;
uniform vec2 forest_height_m = vec2(0.12, 0.3);
uniform float forest_shade = 1.0;
uniform float color_variation = 0.15;
uniform vec3 blade_tint = vec3(1.08, 1.0, 0.85);  // оттенок травинок поверх цвета луга
uniform float dry_clump_share = 0.0;              // доля сухих соломенных пучков (редкие)
uniform vec2 blade_shade = vec2(1.25, 1.75);      // яркость у корня / у кончика, × цвет земли
uniform float sway_hz = 0.8;                      // частота собственного качания, Гц
uniform float sway_hz_var = 0.0;                  // разброс частоты качания по пучкам (±доля)
uniform float sway_amp = 0.12;                    // собственное качание (доля высоты) при полном ветре
uniform float bend_amp = 0.7;                     // наклон по ветру/порыву (доля высоты)
// скошенные места (посадочные площадки, круг — пока не подключены прямоугольники): xy — центр,
// z — радиус, м; w — доля высоты
uniform vec4 mowed[4];
uniform int mowed_count = 0;
// посадки прямоугольником (рекомендация 4, GrassField.set_landing_sites): landing_pos —
// xy центр, z half_len (по оси), w half_width (поперёк); landing_dir — xy ось (курс), zw
// перпендикуляр; landing_hk — доля высоты скошенной травы.
uniform vec4 landing_pos[4];
uniform vec4 landing_dir[4];
uniform float landing_hk[4];
uniform int landing_count = 0;
// приминание у ног пилота
uniform vec3 press_pos = vec3(1e9);
uniform float press_radius_m = 1.5;
uniform float press_agl_full_m = 0.4;   // ноги ниже — приминание полное
uniform float press_agl_zero_m = 1.2;   // ноги выше — приминания нет
// примятая трава у старта (SC-K6, GrassField.set_trample_mask): R8-маска (0 — нетронута, 1 — до земли),
// trample_rect — xy начало мира, zw — 1/размер, м; вне маски и при trample_on = 0 — трава как была.
uniform sampler2D trample_tex : filter_linear, repeat_disable, hint_default_black;
uniform vec4 trample_rect = vec4(0.0, 0.0, 1.0, 1.0);
uniform float trample_on = 0.0;
uniform float trample_height_k = 0.12;   // высота травы при полном приминании (доля)
uniform float trample_lean = 1.3;        // наклон в случайную сторону при полном приминании
uniform vec3 trample_tint = vec3(1.12, 1.0, 0.72);   // чуть желтее
// прореживание вдали (рекомендация 1): rank пучка < far_density(d) — виден
uniform float far_density_min = 0.12;
uniform float thin_start_k = 0.1;
uniform float thin_end_k = 0.85;
uniform float far_width_k = 1.7;
// кольца слоёв (ближний — травинки, дальний — крупные редкие пучки): внутренний край
// дальнего слоя проявляется по rank на [inner_radius_m; inner_radius_m + inner_fade_m],
// внешний край ближнего растворяется по rank с xfade_k·area_radius_m; высота гаснет с
// height_fade_k·area_radius_m до area_radius_m.
uniform float inner_radius_m = -1.0;
uniform float inner_fade_m = 0.001;
uniform float xfade_k = 1.0;
uniform float height_fade_k = 0.6;
uniform float height_k = 1.0;   // множитель высоты слоя
// ранний выход вне поля зрения (GR-3): пучок, целиком лежащий за плоскостью пирамиды камеры,
// прячется до выборок цвета/класса/ветра. clump_reach_m — радиус пучка в плане (корни + изгиб +
// полуширина травинки, GrassField по сетке пучка); cull_enabled — только для теста (GR-3).
uniform float clump_reach_m = 0.35;
uniform bool cull_enabled = true;
// своя нормаль травинки (GR-6). Сетка пучка (GrassField.clump_mesh): NORMAL — лицо травинки
// (горизонталь, в плане пучка), UV.x — поперёк −1…+1 (0 — кончик), UV.y — случайное число травинки.
// Нормаль освещения — наклон нормали листа от вертикали leaf_tilt_deg (средний угол наклона листа
// злаков от горизонта ~60–70°, эректофильный полог) между нормалью полога (земля + наклон ветром) и
// нормалью лица; поперёк листа нормаль поворачивается на ±groove_deg («желобок»). Вдали (blade_normal_fade_m)
// — к нормали полога, как было: среднее и дальнее кольца сходятся с рельефом.
uniform float leaf_tilt_deg = 60.0;
// Яркость листа при своей нормали (GR-14): наклонённая к камере нормаль в среднем ловит меньше прямого
// солнца, чем нормаль полога (≈cos leaf_tilt_deg по азимутам), а цвет травинки подобран к лугу,
// освещённому по нормали полога (земля, дальние кольца). Множитель альбедо, гаснет вместе со своей
// нормалью (blade_normal_fade_m): средняя яркость ближней травы = яркость при нормали полога (замер —
// tests/vegetation/test_grass_specks_gpu.gd); перепад по солнцу (лицо/изнанка) остаётся.
uniform float leaf_tilt_gain = 1.0;
uniform float groove_deg = 30.0;
uniform vec2 blade_normal_fade_m = vec2(8.0, 20.0);
// цвет вдоль/поперёк/между травинками (GR-6): край листа темнее середины на across_shade (доля),
// разброс яркости травинок пучка ±blade_variation, кончики суше: доля tip_dry к соломе на верхней
// трети (кончики злаков отмирают первыми), разброс сухости кончика по травинкам.
uniform float across_shade = 0.12;
uniform float blade_variation = 0.1;
uniform float tip_dry = 0.25;

varying vec3 v_col;
varying float v_t;
// нормаль освещения — во фрагменте из трёх частей (GR-14): v_n — полог·cos(наклон листа),
// v_nf/v_ns — лицо/бок травинки·sin(наклон листа); желобок (поворот к боку на groove_deg·поперёк)
// считается по поперёк, зажатому в −1…+1. При MSAA фрагмент тонкой травинки закрашивается в центре
// пикселя вне треугольника — varying'и экстраполируются (поперёк ±5 и дальше): без зажима край
// листа уходил в отрицательную яркость и интерполированная нормаль — в ноль, «чёрная сыпь».
varying vec3 v_n;
varying vec3 v_nf;
varying vec3 v_ns;
varying float v_across;   // поперёк травинки −1…+1
varying float v_gain;     // множитель альбедо своей нормали (leaf_tilt_gain по bk)
// тень облаков: множитель прямого солнца (cloud_shadow.gdshaderinc) — в light()
varying float v_cs_sun;

// GR-3: пучок целиком вне пирамиды камеры текущего прохода. Тело пучка — вертикальный столбик
// от корня (h − 0,02) до самой высокой травинки (высота не выше max диапазонов классов × height_k:
// сезон полей, скос, приминание, затухание вдали её только уменьшают) радиусом
// reach = clump_reach_m · ширина вдали + наибольший вынос кончика вбок (наклон lean × высота;
// |lean| не больше наклона ветром+качанием, приминания у пилота 1,5 и примятой травы trample_lean —
// lean их выпуклая смесь). Отсекается, только если столбик с этим радиусом целиком за одной из
// боковых плоскостей (из строк PROJECTION_MATRIX — учтены FOV, соотношение сторон, любой вьюпорт)
// или позади камеры. Ближе 2 м по горизонтали — никогда. Считается в том же кадре, что и
// рисование, — запаса на поворот камеры не нужно.
// Высота и уклон в точке (GR-6): те же четыре узла, что у h_bilinear, — уклон билинейной клетки
// (поверхность, которую рисует рельеф), без четырёх лишних билинейных выборок на вершину.
float h_grad(vec2 xz, out vec2 g) {
	vec2 f = (xz - layer_origin) / layer_spacing;
	vec2 i = floor(f);
	vec2 t = f - i;
	ivec2 ij = ivec2(i);
	float h00 = h_node(ij);
	float h10 = h_node(ij + ivec2(1, 0));
	float h01 = h_node(ij + ivec2(0, 1));
	float h11 = h_node(ij + ivec2(1, 1));
	g = vec2(mix(h10 - h00, h11 - h01, t.y), mix(h01 - h00, h11 - h10, t.x)) / layer_spacing;
	return mix(mix(h00, h10, t.x), mix(h01, h11, t.x), t.y);
}

bool clump_out_of_view(vec2 xz, float h, float d, float width_scale, mat4 proj, mat4 view) {
	if (d < 2.0) {
		return false;
	}
	float h_max = max(max(blade_height_m.y, crop_height_m.y), forest_height_m.y) * height_k;
	// множители высоты > 1 (скошенные места mowed.w, площадки landing_hk, приминание) — в запас:
	// перекрывающиеся места перемножаются, поэтому произведение max(1, k)
	for (int k = 0; k < mowed_count; k++) {
		h_max *= max(mowed[k].w, 1.0);
	}
	for (int k = 0; k < landing_count; k++) {
		h_max *= max(landing_hk[k], 1.0);
	}
	h_max *= max(trample_height_k, 1.0);
	// наклон ветром (terrain_wind.gdshaderinc, grass_wind): пятна порывов |bend| ≤ 1 + gust_gain,
	// термик |inward + 0,4·swirl|·tw ≤ 1,08·th.w·thermal_gain
	float bend_max = 1.0 + max(gust_gain, 0.0);
	for (int k = 0; k < wind_thermal_count; k++) {
		bend_max = max(bend_max, 1.08 * abs(wind_thermals[k].w) * thermal_gain);
	}
	float lean_max = bend_max * abs(bend_amp) + 0.15 + abs(sway_amp);
	lean_max = max(lean_max, max(1.5, abs(trample_lean)));
	float reach = clump_reach_m * width_scale + lean_max * h_max;
	// концы оси столбика в пространстве вида (вид смотрит в −Z; масштаб вида единичный)
	vec3 a = (view * vec4(xz.x, h - 0.02, xz.y, 1.0)).xyz;
	vec3 b = (view * vec4(xz.x, h + h_max, xz.y, 1.0)).xyz;
	if (min(a.z, b.z) > reach) {
		return true;   // позади камеры
	}
	mat4 t = transpose(proj);   // t[i] — строка i проекции: плоскости пирамиды в пространстве вида
	vec4 pl[4] = vec4[4](t[3] + t[0], t[3] - t[0], t[3] + t[1], t[3] - t[1]);
	for (int i = 0; i < 4; i++) {
		float inv = inversesqrt(max(dot(pl[i].xyz, pl[i].xyz), 1e-20));
		float da = dot(pl[i].xyz, a) + pl[i].w;
		float db = dot(pl[i].xyz, b) + pl[i].w;
		if (max(da, db) * inv < -reach) {
			return true;
		}
	}
	return false;
}

void vertex() {
	vec2 cell = grid_center_cell + INSTANCE_CUSTOM.xy;   // смещение клетки в кольце слоя
	vec2 jit = vec2(hash12(cell * 1.37 + 3.1), hash12(cell * 0.71 + 11.3)) - 0.5;
	vec2 xz = (cell + 0.5 + jit * 0.9) * clump_spacing_m;
	float d = length(xz - CAMERA_POSITION_WORLD.xz);
	// прореживание вдали (рекомендация 1): пучок виден, если rank < density(d);
	// дальние пучки шире — компенсируют разрежение (far_width_k, применяется к o ниже).
	float thin_t = clamp(d / max(area_radius_m, 0.001), 0.0, 1.0);
	float thin_s = smoothstep(thin_start_k, thin_end_k, thin_t);
	float density = mix(1.0, far_density_min, thin_s);
	density *= 1.0 - smoothstep(area_radius_m * xfade_k, area_radius_m + 1e-3, d);
	density *= smoothstep(inner_radius_m, inner_radius_m + inner_fade_m, d);
	float rank = hash12(cell + vec2(20.5, 0.0));
	float h = 0.0;
	vec2 hg = vec2(0.0);
	bool hidden = rank >= density;
	if (!hidden) {
		h = h_grad(xz, hg);   // единственная выборка высоты (и уклона) на вершину
		hidden = cull_enabled && clump_out_of_view(xz, h, d, mix(1.0, far_width_k, thin_s),
				PROJECTION_MATRIX, VIEW_MATRIX);
	}
	if (hidden) {
		VERTEX = vec3(xz.x, -1e4, xz.y);   // пучок скрыт: вырожденные треугольники, без выборок
		v_col = vec3(0.0);
		v_t = 0.0;
		v_n = vec3(0.0, 1.0, 0.0);
		v_nf = vec3(0.0);
		v_ns = vec3(0.0);
		v_across = 0.0;
		v_gain = 1.0;
		v_cs_sun = 1.0;
	} else {
		float sl_rel; vec4 sl_ss = sl_season_b(h, sl_rel); // SL
		// класс — ближайший узел карты (как Terrain.surface_at)
		int c = surface_node(ivec2(round((xz - surface_origin) / surface_spacing)));
		float r = hash12(cell + 2.2);
		float hh = 0.0;
		if (c == 2 || c == 0) {
			hh = mix(blade_height_m.x, blade_height_m.y, r);
		} else if (c == 3) {
			hh = mix(crop_height_m.x, crop_height_m.y, r) * sl_field_height(xz, sl_rel); // SL
		} else if (c == 4 && hash12(cell + 8.8) < shrub_density) {
			hh = mix(blade_height_m.x, blade_height_m.y, r);
		} else if (c == 1 && hash12(cell + 8.8) < forest_density) {
			hh = mix(forest_height_m.x, forest_height_m.y, r);
		}
		vec3 n = normalize(vec3(-hg.x, 1.0, -hg.y));
		// порода рельефа (скалы, выходы породы, осыпь — ground_cover, G2 v2): пучок остаётся с долей луга
			if (hh > 0.0 && hash12(cell + 23.7) >= gc_grass_keep_fast(xz, n, c)) {
				hh = 0.0;
			}
		for (int k = 0; k < mowed_count; k++) {
			if (length(xz - mowed[k].xy) < mowed[k].z) {
				hh *= mowed[k].w;
			}
		}
		// посадки прямоугольником (рекомендация 4): вдоль оси / поперёк, не кругом
		for (int k = 0; k < landing_count; k++) {
			vec2 dv = xz - landing_pos[k].xy;
			float along = dot(dv, landing_dir[k].xy);
			float across = dot(dv, landing_dir[k].zw);
			if (abs(along) <= landing_pos[k].z && abs(across) <= landing_pos[k].w) {
				hh *= landing_hk[k];
			}
		}
		// примятая трава (SC-K6): одна выборка маски; вне маски tr = 0 — высота и наклон прежние
		float tr = 0.0;
		if (trample_on > 0.5) {
			vec2 tuv = (xz - trample_rect.xy) * trample_rect.zw;
			if (tuv.x >= 0.0 && tuv.y >= 0.0 && tuv.x < 1.0 && tuv.y < 1.0) {
				tr = textureLod(trample_tex, tuv, 0.0).r;
			}
		}
		hh *= mix(1.0, trample_height_k, tr);
		hh *= height_k * (1.0 - smoothstep(area_radius_m * height_fade_k, area_radius_m, d));
		float width_scale = mix(1.0, far_width_k, thin_s);
		// нет травы (класс без травы, круто, скошено до нуля, край кольца) — дальше не считаем:
		// ветер, нормаль, цвет пучка пропускаются целиком (ветвь одна на пучок)
		if (hh < 0.02) {
			VERTEX = vec3(xz.x, -1e4, xz.y);
			v_col = vec3(0.0);
			v_t = 0.0;
			v_n = vec3(0.0, 1.0, 0.0);
			v_nf = vec3(0.0);
			v_ns = vec3(0.0);
			v_across = 0.0;
			v_gain = 1.0;
			v_cs_sun = 1.0;
		} else {

			// ветер: наклон по полю порывов/термиков + собственное качание
			float t = VERTEX.y;                 // 0 — корень, 1 — кончик
			float wshade;
			vec2 bend;
			grass_wind(xz, d, TIME, wshade, bend);
			float spd = length(wind_vec);
			float amp = smoothstep(0.3, wind_full_ms, spd);
			vec2 dir = spd > 0.05 ? wind_vec / spd : vec2(1.0, 0.0);
			// у каждого пучка своя фаза и немного своя частота — без синхронного «полотна»
			float ph = hash12(cell + 4.4) * 6.2832;
			float fk = 1.0 + sway_hz_var * (2.0 * hash12(cell + 4.9) - 1.0);
			vec2 lean = bend * bend_amp + dir * amp * (0.15 + sway_amp * sin(TIME * sway_hz * fk * 6.2832 + ph));
			// приминание: пилот стоит/бежит — трава клонится от него и ложится
			vec2 pv = xz - press_pos.xz;
			float pd = length(pv);
			float near_ground = 1.0 - smoothstep(press_agl_full_m, press_agl_zero_m, press_pos.y - h);
			float press = near_ground * (1.0 - smoothstep(press_radius_m * 0.4, press_radius_m, pd));
			lean = mix(lean, (pd > 0.01 ? pv / pd : vec2(0.0)) * 1.5, press);
			// примятая трава ложится в случайную сторону (на tr = 0 lean не меняется)
			float ta = hash12(cell + 9.3) * 6.2832;
			lean = mix(lean, vec2(cos(ta), sin(ta)) * trample_lean, tr * 0.85);
			float l2 = min(dot(lean, lean), 2.0);
			// поворот пучка
			float a = hash12(cell + 6.6) * 6.2832;
			// дальние пучки шире (компенсация прореживания, рекомендация 1)
			mat2 rot = mat2(vec2(cos(a), sin(a)), vec2(-sin(a), cos(a)));
			vec2 o = rot * VERTEX.xz * width_scale;   // м
			float y = t * hh * inversesqrt(1.0 + l2 * t * t);   // стебель не вытягивается при наклоне
			vec2 off = lean * hh * t * t;
			VERTEX = vec3(xz.x + o.x + off.x, h + y - 0.02, xz.y + o.y + off.y);
			// нормаль полога (как было) и своя нормаль травинки (GR-6)
			vec3 nc = normalize(n + vec3(lean.x, 0.0, lean.y) * 0.3);
			float bk = 1.0 - smoothstep(blade_normal_fade_m.x, blade_normal_fade_m.y, d);
			if (bk > 0.0) {
				vec2 f2 = rot * NORMAL.xz;
				vec3 fn = vec3(f2.x, 0.0, f2.y);
				// лицом к камере (решение по центру пучка — у всех вершин травинки одно)
				fn *= dot(f2, CAMERA_POSITION_WORLD.xz - xz) < 0.0 ? -1.0 : 1.0;
				// касательная стебля по изгибу: d/dt (lean·t², t/√(1 + l2·t²)), без множителя hh
				float ik = inversesqrt(1.0 + l2 * t * t);
				vec3 tg = normalize(vec3(2.0 * t * lean.x, ik * ik * ik, 2.0 * t * lean.y));
				fn = normalize(fn - tg * dot(fn, tg));
				vec3 sd = cross(tg, fn);
				float lt = radians(leaf_tilt_deg) * bk;
				// нормаль = полог·cos lt + (лицо·cos gr + бок·sin gr)·sin lt, gr = groove·поперёк (во фрагменте)
				v_n = nc * cos(lt);
				v_nf = fn * sin(lt);
				v_ns = sd * sin(lt);
			} else {
				v_n = nc;
				v_nf = vec3(0.0);
				v_ns = vec3(0.0);
			}
			v_across = UV.x;
			v_gain = mix(1.0, leaf_tilt_gain, bk);

			// цвет подложки: тот же луг, что рисует рельеф под травой (включая пятна с высоты)
			vec4 rel = relief_at(xz);
			float wet = rel.r * 2.0 - 1.0;
			vec3 base = meadow_ground_color(xz, northness(n), meadow_patch(xz), wet, rel.b * 2.0 - 1.0);
			base = meadow_macro(xz, base, 0.05, wet, d, 0.0);
			base = sl_meadow_season(base, sl_ss); // SL
			if (c == 3) {
				base = sl_field_season(field_plot_color(xz, base), xz, sl_rel); // SL
			} else if (c == 1) {
				base *= forest_shade;   // под пологом темнее
			}
			// редкие сухие пучки — солома той же яркости (основной тон — из палитры луга: сухо там,
			// где сухо по локации, южным склонам и пятнам)
			const vec3 LB = vec3(0.2126, 0.7152, 0.0722);
			if (hash12(cell + 17.9) < dry_clump_share) {
				base = straw_color * (dot(base, LB) / max(dot(straw_color, LB), 1e-3)) * 1.15;
			}
			base *= 1.0 + color_variation * (hash12(cell + 13.3) - 0.5) * 2.0;
			base *= blade_tint * (1.0 + wind_shade * wshade);
			base *= mix(vec3(1.0), trample_tint, tr);
			// травинка пучка: своя яркость, кончик суше (к соломе той же яркости)
			float br = UV.y;
			base *= 1.0 + blade_variation * (2.0 * br - 1.0);
			vec3 straw = straw_color * (dot(base, LB) / max(dot(straw_color, LB), 1e-3));
			base = mix(base, straw, tip_dry * mix(0.4, 1.0, fract(br * 7.31)) * smoothstep(0.55, 1.0, t));
			v_col = base;
			v_t = t;
			v_cs_sun = cloud_sun_at(VERTEX);
		}
	}
}

void fragment() {
	// у корня темнее (затенение в гуще), к кончику светлее
	// поперёк — край листа темнее середины (желобок затеняет края)
	// varying'и зажаты в пределы травинки (MSAA: центр пикселя вне тонкого треугольника, см. v_n)
	float across = clamp(v_across, -1.0, 1.0);
	ALBEDO = v_col * mix(blade_shade.x, blade_shade.y, clamp(v_t, 0.0, 1.0)) * v_gain
			// край темнее середины без потери средней яркости (GR-14): среднее 1 − across_shade/3 по ширине
			* (1.0 - across_shade * across * across) / (1.0 - across_shade / 3.0);
	// освещение как у земли под травой (обе стороны травинки): нормаль явная и одна и та же
	// для лица и изнанки (render_mode cull_disabled, без FRONT_FACING-переворота — иначе
	// изнанка темнеет); тонкий стебель просвечивает — BACKLIGHT держит изнанку не темнее
	// лица против солнца (VR-6, S1 yaw+180).
	float gr = radians(groove_deg) * across;
	vec3 n = v_n + v_nf * cos(gr) + v_ns * sin(gr);
	n = dot(n, n) > 1e-8 ? n : vec3(0.0, 1.0, 0.0);
	NORMAL = normalize((VIEW_MATRIX * vec4(n, 0.0)).xyz);
	ROUGHNESS = 0.9;
	BACKLIGHT = vec3(0.85) * v_col;
	AO = cloud_sky_ao(v_cs_sun);
}

// Встроенное освещение, прямое солнце — в тени облаков слабее (cloud_shadow.gdshaderinc).
void light() {
	cloud_light(NORMAL, VIEW, LIGHT, LIGHT_COLOR, ATTENUATION, LIGHT_IS_DIRECTIONAL, v_cs_sun,
			ALBEDO, ROUGHNESS, METALLIC, 0.0, BACKLIGHT, CS_LAMBERT_WRAP, SPECULAR_AMOUNT,
			DIFFUSE_LIGHT, SPECULAR_LIGHT);
}
