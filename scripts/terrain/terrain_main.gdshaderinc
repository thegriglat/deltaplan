// Тело шейдера рельефа (контракт SL-К6): варианты — scripts/terrain/terrain.gdshader («full», без
// #define) и scripts/terrain/variants/terrain_<имя>.gdshader (shader_type/render_mode, строки
// #define T_<ЧАСТЬ>_OFF, этот #include). Дорогая часть под #ifndef T_<ЧАСТЬ>_OFF выключается при
// компиляции вместе со своими uniform-ами; без #define код тот же, что был в terrain.gdshader.
// Список частей — блоки #ifndef T_*_OFF здесь и в include-ах (tools/terrain/variant_bench.py parts).
//
// Рельеф: высоты из текстуры (вершинный шейдер), раскраска по карте поверхности (VR-4: лес,
// луг, пашня, кустарник, скалы/грунт, вода, застройка, снег — та же карта, что у источников
// термиков), по уклону (скалы на крутом) + шум детализации (FR-19). Все параметры задаёт
// terrain_renderer.gd из configs/world.json → terrain_look (числа в шейдере — только технические).

#include "res://scripts/terrain/terrain_common.gdshaderinc"
#include "res://scripts/terrain/ground_cover.gdshaderinc" // скалы, выходы породы, осыпь — правило общее с травой (GR-25)
#include "res://scripts/terrain/scene_look.gdshaderinc"
#include "res://scripts/terrain/terrain_wind.gdshaderinc"
#include "res://scripts/terrain/meadow_look.gdshaderinc"
#include "res://scripts/terrain/cloud_shadow.gdshaderinc"

// Стык с дальним вариантом (SL-23): части, которых нет в variant_far (выходы породы, скальная
// поверхность, рисунок породы, фактура луга, извилины кромок классов), гаснут по дальности к порогу
// его LOD (far_fade_m.y = порог, по 3D-дальности, как выбор LOD по AABB чанка) — на LOD ≥ порога
// их и так нет, стык без скачка. Задаёт TerrainRenderer; дальнего варианта нет — 1e9 (без гашения).
uniform vec2 far_fade_m = vec2(1e9, 2e9);

float far_k(float d) {
	return 1.0 - smoothstep(far_fade_m.x, far_fade_m.y, d);
}

// шаг между вершинами чанка в узлах сетки (1, 2, 4…) — для нормали вершины (тени)
uniform float lod_stride = 1.0;  // свой материал на каждый LOD (instance uniform переполняет Compatibility)
uniform float skirt_depth;      // глубина «юбки», м
// прямоугольник X/Z, где рисует более детальный слой (грубый слой там не рисуется)
uniform vec2 hole_min = vec2(1e9);
uniform vec2 hole_max = vec2(-1e9);
// Необязательные текстуры поверхностей (пути — configs/world.json → terrain_textures).
// Нет текстуры — процедурная раскраска. Текстура видна вблизи и растворяется к detail_fade_m.
uniform bool use_built_soft = false;
uniform sampler2D built_soft_tex : filter_linear, repeat_disable;
uniform vec2 built_soft_origin;
uniform float built_soft_spacing = 50.0;
uniform vec2 built_soft_texels = vec2(1.0);
uniform vec2 built_soft_range = vec2(0.05, 0.45);   // размытая доля → вес подложки (smoothstep)
uniform float built_soft_max = 0.85;
#ifndef T_GRASS_TEX_OFF
uniform sampler2D grass_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
#endif
uniform sampler2D forest_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
#ifndef T_ROCK_TEX_OFF
uniform sampler2D rock_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
#endif
uniform sampler2D snow_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
#ifndef T_GRASS_TEX_OFF
uniform bool use_grass_tex = false;
// ближняя фактура луга (0…grass_near_m): карта нормалей (RG, OpenGL) + AO (B) той же текстуры,
// стохастический тайлинг (без повтора), рисунок и цвет текстуры сильнее, чем вдали
uniform sampler2D grass_normal_tex : filter_linear_mipmap_anisotropic, repeat_enable;
uniform bool use_grass_normal = false;
uniform vec2 grass_near_m = vec2(25.0, 70.0);   // полная сила / растворилась к, м
uniform float grass_near_contrast = 1.0;        // контраст рисунка вблизи
uniform float grass_near_color_mix = 0.6;       // доля цветовых пятен текстуры вблизи (оттенок — палитры)
uniform float grass_normal_strength = 0.8;
uniform float grass_ao_strength = 0.8;
uniform float grass_macro_k = 6.0;               // крупный слой той же текстуры: тайл ×k
uniform float grass_macro_strength = 0.7;
#endif
uniform bool use_forest_tex = false;
#ifndef T_ROCK_TEX_OFF
uniform bool use_rock_tex = false;
#endif
// --- скалы, осыпи, снег в кулуарах ---
#ifndef T_ROCK_TEX_OFF
uniform sampler2D rock_normal_tex : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform bool use_rock_normal = false;
uniform sampler2D scree_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform bool use_scree_tex = false;
#endif
uniform float scree_tex_tile_m = 4.0;
uniform vec3 rock_color2 : source_color = vec3(0.45, 0.36, 0.26);  // охристо-бурая порода
uniform vec3 lichen_color : source_color = vec3(0.5, 0.42, 0.2);   // рыжий/зеленоватый лишайник
uniform vec3 scree_color : source_color = vec3(0.58, 0.55, 0.5);   // светлая щебёнка
uniform float rock_tone_scale_m = 180.0;
uniform float lichen_amount = 0.35;
uniform float strata_m = 7.0;          // шаг слоёв на обрывах, м
#ifndef T_ROCK_DETAIL_OFF
uniform float strata_strength = 0.28;
#endif
uniform float gully_snow_line_m = 2500.0;  // ниже снега в кулуарах нет, м
#ifndef T_GULLY_SNOW_OFF
uniform float gully_scale_m = 60.0;    // масштаб ложбин (кривизна), м
uniform float gully_k = 0.08;          // вогнутость (м/м), с которой ложбина полностью в снегу
uniform float gully_north_m = 250.0;   // северные склоны: снег ниже на столько, м
#endif
uniform bool use_snow_tex = false;
#ifndef T_GRASS_TEX_OFF
uniform float grass_tex_tile_m = 4.0;
#endif
uniform float forest_tex_tile_m = 8.0;
uniform float rock_tex_tile_m = 6.0;
uniform float snow_tex_tile_m = 6.0;
uniform float texture_strength = 1.0;
// средний цвет каждой текстуры: текстура даёт вблизи рисунок (яркость, пятна),
// а общий цвет остаётся процедурным — без скачка на границе растворения
#ifndef T_GRASS_TEX_OFF
uniform vec3 grass_tex_avg = vec3(0.5);
#endif
uniform vec3 forest_tex_avg = vec3(0.5);
#ifndef T_ROCK_TEX_OFF
uniform vec3 rock_tex_avg = vec3(0.5);
#endif
uniform vec3 snow_tex_avg = vec3(0.5);
uniform float texture_color_mix = 0.3;
uniform float texture_contrast = 0.6; // степень контраста рисунка текстуры (1 — как есть) // доля собственного цвета текстуры (остальное — только её яркость)

// Применить текстуру поверх процедурного цвета c: яркость текстуры относительно средней + немного её цвета.
vec3 apply_tex(vec3 c, vec3 t, vec3 avg, float w) {
	const vec3 L = vec3(0.2126, 0.7152, 0.0722);
	float avg_l = max(dot(avg, L), 1e-3);
	// контраст рисунка ограничен: у тёмных пёстрых текстур светлые пятна не должны «белеть»
	float r = clamp(pow(dot(t, L) / avg_l, texture_contrast), 0.4, 1.7);
	vec3 own = t / avg_l * dot(c, L);
	return mix(c, mix(c * r, own, texture_color_mix), w);
}
#ifndef T_GRASS_TEX_OFF
// Стохастический тайлинг (IQ, «texture repetition» №3): два сдвига текстуры по индексу
// из плавного шума, смешанные по нему же — рисунок не повторяется. uv — в тайлах.
// Возвращает сдвиги (xy, zw) и вес смеси (через out) — те же для нормалей.
vec4 notile_offsets(vec2 uv, out float blend) {
	float k = vnoise(uv * 0.45) * 8.0;
	float i = floor(k);
	blend = smoothstep(0.2, 0.8, k - i);
	return vec4(sin(vec2(3.0, 7.0) * i), sin(vec2(3.0, 7.0) * (i + 1.0)));
}
#endif

// --- полог леса с высоты (кроны-ячейки, их освещение и тени) ---
uniform vec3 sun_dir = vec3(0.0, 1.0, 0.0);   // направление НА солнце (мир), задаёт Terrain
uniform float canopy_cell_m = 6.0;            // шаг крон, м
#ifndef T_CANOPY_OFF
// Город (CityTrees, деревья-модели на местах крон): рисунок крон на земле гасится, чтобы деревья не двоились.
// Маска — city_at плана CityTreePlan (R8, узлы сетки cell_m), включает CityTrees, пока модели видны.
uniform bool use_city_canopy = false;
uniform sampler2D city_canopy_tex : filter_linear, repeat_disable;
uniform vec2 city_canopy_origin;              // мир X/Z центра текселя (0,0), м
uniform float city_canopy_cell_m = 200.0;
uniform vec2 city_canopy_texels = vec2(1.0);
uniform vec2 city_canopy_range_m = vec2(900.0, 1100.0);   // дальше радиуса деревьев города кроны рисуются как прежде
uniform vec2 canopy_crown_k = vec2(0.55, 0.85); // радиус кроны / шаг, мин/макс
uniform float canopy_gap_dark = 0.35;         // яркость просветов между кронами (тень под пологом)
uniform float canopy_tone_var = 0.22;         // разброс яркости крон
uniform float canopy_shadow = 0.55;           // сила тени от соседних крон
uniform float canopy_height_k = 1.6;          // вытянутость крон (форма нормали: 1 — полусфера)
#endif
uniform float canopy_edge_dark = 0.2;         // опушка темнее (тень леса на краю) — только внутри леса
#ifndef T_FOREST_EDGE_OFF
uniform float canopy_edge_depth_m = 25.0;     // ширина тёмной полосы опушки внутрь леса, м
#endif
uniform float canopy_far_shade = 0.62;        // средняя яркость полога, когда кроны мельче пикселя
uniform float canopy_stand_var = 0.3;         // разброс яркости древостоев (пятна 50–200 м) вблизи
uniform float canopy_far_var = 0.3;           // то же вдали (кроны мельче пикселя)
uniform float canopy_far_big = 0.0;           // доля крупных пятен (массивы 300–800 м) в разбросе
uniform float canopy_far_sat = 1.0;           // насыщенность среднего тона полога (1 — как цвет пород)
#ifndef T_FOREST_EDGE_OFF
// кромка леса по маске 10 м: порог 0,5 + узкий шум (переход ≤ 1,5 клетки)
uniform float forest_edge_soft = 0.12;        // полуширина порога (доля маски)
uniform float forest_edge_noise = 0.35;       // сдвиг порога шумом (доля маски)
uniform float forest_edge_warp_m = 4.0;       // извилистость кромки (сдвиг выборки), м
// высота крон в DSM (Copernicus): ступенька на опушке; вычитается из уклона на лугу у кромки
uniform float canopy_dsm_height_m = 10.0;
#endif
// --- поля рельефа (TerrainRelief, считаются из DEM при загрузке): R — влажность, G — AO,
// B — сглаженная северность, A — горизонт к солнцу (0..60°, SL-К7) — тень рельефа при низком солнце ---
uniform float forest_wet_dark = 0.12;    // лес в ложбинах и на северных склонах гуще (темнее)
uniform float relief_ao_albedo = 0.25;   // AO ложбин в цвете
uniform float relief_ao_ambient = 0.8;   // AO ложбин в рассеянном свете
uniform float relief_shadow_strength = 0.85;
uniform float relief_shadow_soft_deg = 2.0;   // полутень по углу горизонта, °
uniform float relief_shadow_ambient = 0.35;   // рассеянный свет относительно прямого (тень не чёрная)
uniform vec2 relief_shadow_near_m = vec2(2200.0, 3000.0); // ближе — тени Godot (sun.shadow_max_distance_m)
uniform vec3 water_color : source_color;
uniform float water_roughness = 0.08;    // гладь в штиль (зеркало)
// --- вода от ветра (VR-16; configs/world.json → terrain_look: water_*) ---
uniform float water_rough_wind = 0.32;   // шероховатость при ветре water_wind_full_ms (матовая рябь)
uniform float water_wind_calm_ms = 0.7;  // до такого ветра — зеркало, м/с
uniform float water_wind_full_ms = 5.0;  // при таком ветре рябь полная, м/с
#ifndef T_WATER_WIND_OFF
uniform float water_ripple_m = 4.0;      // длина мелкой ряби, м (вторая октава — ×3)
uniform float water_ripple_tilt = 0.18;  // наклон нормали ряби при полном ветре
uniform float water_gust_rough = 0.35;   // добавка шероховатости в пятне порыва («кошачья лапа»)
uniform float water_gust_tilt = 0.2;     // добавка наклона нормали ряби в пятне порыва
uniform float water_lee_m = 150.0;       // ветровая тень у наветренного берега: дальняя выборка, м
uniform float water_lee_calm = 0.85;     // доля ветра, которую гасит суша вплотную с наветра
#endif
uniform float water_specular = 0.4;      // блик воды (PBR specular; 0.5 — F0 4 %)
uniform float roughness_value;
uniform float specular_value;

// та же текстура высот с мипмапами (среднее высот): нормаль во фрагменте с шагом базовой сетки
// слоя вблизи и по следу пикселя вдали — не зависит от LOD меша (TerrainRenderer)
uniform sampler2D height_mip_tex : filter_linear_mipmap, repeat_disable;
uniform float height_mip_max_lod = 0.0;
// --- промоины (эрозионный рисунок только в нормалях, по образцу erosion filter runevision /
// gullies Clay John): ветвящиеся полосы вдоль линии падения, октавы; configs/world.json →
// terrain_look: erosion_* ---
#ifndef T_EROSION_OFF
uniform bool erosion_enabled = true;
uniform float erosion_strength = 0.45;            // наклон нормали промоин, доля уклона склона
uniform float erosion_scale_m = 140.0;            // шаг крупных промоин, м (октавы — вдвое мельче)
uniform float erosion_octaves = 3.0;
uniform float erosion_gain = 0.55;                // сила следующей октавы
uniform float erosion_branch = 1.0;               // поворот октавы по уклону от предыдущих (ветвление)
uniform vec2 erosion_slope_deg = vec2(5.0, 18.0); // уклон появления / полной силы
uniform vec2 erosion_fade_m = vec2(7000.0, 14000.0);   // гаснут с расстоянием, м
#endif
// --- скальная поверхность на крутизне (скалы и выходы породы; terrain_look: rock_macro_*,
// rock_normal_strength, ledge_*, outcrop_ribs): та же текстура породы крупным масштабом по трём
// проекциям (рисунок и нормаль видны с километров, где мелкий тайл усреднён мипами), уступы
// слоёв в нормали, пятна породы на крутом — рёбрами вдоль линии падения ---
uniform float rock_macro_k = 24.0;                // крупный слой: тайл ×k
#ifndef T_ROCK_TEX_OFF
uniform float rock_macro_contrast = 1.6;         // степень контраста рисунка крупного слоя (мипы его сглаживают)
uniform float rock_macro_strength = 0.8;          // контраст рисунка крупного слоя (яркость)
uniform float rock_macro_normal = 0.5;            // наклон нормали крупного слоя
#endif
#ifndef T_ROCK_SURFACE_OFF
uniform vec2 rock_macro_fade_m = vec2(6000.0, 12000.0);
#endif
#ifndef T_ROCK_TEX_OFF
uniform float rock_normal_strength = 0.6;         // мелкий слой (тайл rock.tile_m), вблизи
#endif
#ifndef T_ROCK_SURFACE_OFF
uniform float ledge_strength = 0.3;               // уступы слоёв: ± доля уклона (ступень/полка)
uniform vec2 ledge_slope_deg = vec2(25.0, 45.0);  // уступы появляются / в полную силу, °
#endif
#ifndef T_EROSION_OFF
uniform float erosion_rock_boost = 1.0;          // промоины на скальной поверхности сильнее (× 1 + boost)
#endif
#ifndef T_ROCK_SURFACE_OFF
// фактура скальной зоны на средней дистанции (300–2000 м), без моделей камней
uniform float rock_tone_var = 0.35;               // разброс яркости породы пятнами 30–150 м
uniform float rock_crack_m = 22.0;                // шаг трещин-кулуаров (вдоль линии падения ×3), м
uniform float rock_crack_dark = 0.3;              // затемнение трещин
uniform float rock_scree_streaks = 0.45;          // доля светлых полос осыпей вдоль линии падения
uniform float rock_curv_shade = 0.25;
uniform vec2 rock_fall_flat_deg = vec2(2.0, 8.0);  // ниже — рисунок по постоянному направлению, выше — по линии падения, °
uniform float rock_fall_bin_deg = 30.0;           // шаг направлений рисунка (смешиваются два соседних), °
// порода высокогорья (ниже линии снега в кулуарах на rock_alpine_below_m — полностью): холодная
// тёмная (гранит, сланец), пятнами 0,5–2 км ржавая; на крутом темнее
uniform vec3 rock_alpine_color : source_color = vec3(0.22, 0.23, 0.25);
uniform vec3 rock_alpine_rust : source_color = vec3(0.33, 0.27, 0.2);
uniform vec2 rock_alpine_below_m = vec2(1100.0, 400.0);
uniform float rock_alpine_mix = 0.85;             // гребни светлее, ложбины темнее (кривизна 35 м)                 // доля «рёбер вдоль линии падения» в пятнах породы на крутом
#endif

varying vec3 v_world;
// тень облаков: множитель прямого солнца и SPECULAR — в light() (cloud_shadow.gdshaderinc)
varying float v_cs_sun;
varying float v_cs_spec;
// выпуклость рельефа (−лапласиан, м/м) в масштабе outcrop_scale_m (ground_cover) — в вершине, дёшево
varying float v_convex;

// Градиент высоты (dh/dx, dh/dz) центральными разностями с шагом d = тексель мип-уровня lod:
// мип — среднее высот, разность средних — средний уклон по окрестности ±d (фильтр без муара).
// lod 0 — шаг базовой сетки слоя (как прежняя нормаль вершины LOD 0), билинейно между узлами.
vec2 height_grad(vec2 xz, float lod) {
	float d = layer_spacing * exp2(lod);
	vec2 uv = ((xz - layer_origin) / layer_spacing + 0.5) / layer_texels;
	vec2 du = vec2(d / layer_spacing / layer_texels.x, 0.0);
	vec2 dv = vec2(0.0, d / layer_spacing / layer_texels.y);
	float hx1 = textureLod(height_mip_tex, uv + du, lod).r;
	float hx0 = textureLod(height_mip_tex, uv - du, lod).r;
	float hz1 = textureLod(height_mip_tex, uv + dv, lod).r;
	float hz0 = textureLod(height_mip_tex, uv - dv, lod).r;
	return vec2(hx1 - hx0, hz1 - hz0) / (2.0 * d);
}

// --- форма гор вдали (только картинка: высоты физики, столкновения и полёта не меняются) ---
// terrain_look: relief_*. Источник (Copernicus 30 м) при сборке сглажен (σ 0,8 клетки — против
// ступенек леса в DSM): кривизна гребней ×0,6, гребни ниже на ~5 м; сетка LOD на 1,5–7 км срезает
// гребни ещё на 8–15 м. Вершины вдали: гребни/ложбины заострены (нерезкая маска по ±1 узлу),
// промоины (тот же рисунок, что в нормали фрагмента, erosion_*) вдавлены в рельеф. Вблизи камеры
// (relief_near_m) — гасится до нуля: у земли картинка совпадает с высотами физики.
#ifndef T_RELIEF_DETAIL_OFF
uniform bool relief_detail_enabled = true;
uniform vec2 relief_near_m = vec2(200.0, 350.0);   // от камеры: нет / в полную силу, м
uniform vec2 relief_slope_deg = vec2(15.0, 30.0);  // с уклона: появляется / в полную силу, °
uniform float relief_sharpen = 0.8;                 // доля кривизны ±1 узла, добавляемая обратно
uniform float relief_sharpen_max_m = 8.0;           // предел заострения, м
uniform float relief_gully = 1.0;
uniform float relief_lod_m = 1000.0;               // оценка шага вершин для промоин: шаг слоя × дальность / это, м
// MLK-К2 v2. (а) Силуэт без потери пиков между вершинами LOD: вершина выпуклого места (гребень, пик)
// поднимается к максимуму высот в окне вокруг своего узла (пирамида максимумов height_max_tex);
// размер окна — от дальности до камеры через пороги LOD слоя (lod_dist_m), не от шага LOD чанка:
// одна точка на любом LOD — тот же dh. В долинах и на ровных склонах вес 0 (не «надуваются»). Ближе
// relief_peak_near_m — нет: там окно сдвигает гребень к камере (угол h/r² · сдвиг) сильнее, чем LOD его срезает.
// (б) Заострение гребней (relief_sharpen) у высоких гор сильнее: перепад высот max − среднее на
// relief_scale_m — от холмов (relief_high_m.x) до высоких гор (.y): доля кривизны relief_sharpen →
// relief_sharpen_high, предел relief_sharpen_max_m → подсеточный гребень relief_subgrid_k·шаг·tg уклона
// (не больше relief_sharpen_cap_m).
uniform sampler2D height_max_tex : filter_linear_mipmap, repeat_disable;
uniform bool use_height_max = false;
uniform vec4 lod_dist_m = vec4(1e9);                 // пороги LOD слоя (render.<слой>.lod_distances_m), м
uniform float relief_peak = 1.0;                     // доля недобора пика в окне (max − h), возвращаемая вершине
uniform float relief_peak_level = -1.0;              // уровень окна относительно шага вершин LOD, log2
uniform float relief_peak_ramp = 0.25;               // окно растёт перед порогом LOD на эту долю порога
uniform vec2 relief_peak_near_m = vec2(5000.0, 10000.0); // подъём пиков: нет ближе / полностью дальше, м
uniform float relief_peak_convex = 0.25;             // выпуклость (h − среднее)/(max − h) для полного веса
uniform float relief_peak_summit = 0.5;              // вершина горы в окне: (max вдвое шире − max)/(max − h) до этого
uniform float relief_peak_max_m = 400.0;             // предел подъёма вершины, м
uniform float relief_scale_m = 1000.0;               // масштаб перепада высот «холмы / высокие горы», м
uniform vec2 relief_high_m = vec2(150.0, 400.0);     // перепад max − среднее: холмы / высокие горы, м
uniform float relief_sharpen_high = 1.0;             // доля кривизны у высоких гор
uniform float relief_subgrid_k = 0.25;               // подсеточный гребень: k · шаг слоя · tg уклона, м
uniform float relief_sharpen_cap_m = 30.0;           // верхний предел заострения, м
#endif

#ifndef T_RELIEF_DETAIL_OFF
// Уровень окна максимумов (log2 шага вершин в узлах слоя) по дальности d: сумма ступеней LOD,
// каждая — плавно на relief_peak_ramp доли порога перед ним (без ступеньки по дальности).
float relief_lod_level(float d) {
	vec4 r = lod_dist_m * (1.0 - relief_peak_ramp);
	vec4 k = smoothstep(r, lod_dist_m, vec4(d));
	return k.x + k.y + k.z + k.w;
}

// Максимум высот узлов в окне ±2^(L−1) узла вокруг ij (по блокам 2^L пирамиды: 2×2 текселя уровня L
// покрывают окно; L = 0 — сам узел).
float relief_max_window(ivec2 ij, int L) {
	if (L <= 0) {
		return h_node(ij);
	}
	ivec2 sz = max(ivec2(layer_texels) >> L, ivec2(1));
	int hw = 1 << (L - 1);
	ivec2 a = clamp((ij - ivec2(hw)) >> L, ivec2(0), sz - ivec2(1));
	ivec2 b = clamp((ij + ivec2(hw)) >> L, ivec2(0), sz - ivec2(1));
	float m0 = texelFetch(height_max_tex, a, L - 1).r;
	float m1 = texelFetch(height_max_tex, ivec2(b.x, a.y), L - 1).r;
	float m2 = texelFetch(height_max_tex, ivec2(a.x, b.y), L - 1).r;
	float m3 = texelFetch(height_max_tex, b, L - 1).r;
	return max(max(m0, m1), max(m2, m3));
}
#endif

#ifndef T_EROSION_OFF
// Промоины по высоте: ячейка — значение cos фазы (z) и его производная по p (xy), как gully_cell.
vec3 gully_cell3(vec2 ip, vec2 fp, vec2 o, vec2 dir) {
	float hs = hash12(ip + o);
	vec2 pp = fp - o - (vec2(hs, fract(hs * 37.17)) - 0.5) * 0.5;
	float ph = dot(pp, dir) * 6.2832;
	return vec3(-sin(ph) * dir * 6.2832, cos(ph));
}

vec3 gully_octave3(vec2 p, vec2 dir) {
	vec2 ip = floor(p);
	vec2 fp = p - ip;
	vec2 u = fp * fp * (3.0 - 2.0 * fp);
	vec3 a = mix(gully_cell3(ip, fp, vec2(0.0, 0.0), dir), gully_cell3(ip, fp, vec2(1.0, 0.0), dir), u.x);
	vec3 b = mix(gully_cell3(ip, fp, vec2(0.0, 1.0), dir), gully_cell3(ip, fp, vec2(1.0, 1.0), dir), u.x);
	return mix(a, b, u.y);
}

// Высота промоин в точке, м: октавы как erosion_octave (уклон октавы amp_o — высота amp_o·λ·cos),
// октава реже ~3 вершин сетки (шаг vs, м) — без неё.
float erosion_height(vec2 xz, vec2 g, float vs, float k) {
	float amp0 = erosion_strength * length(g) / 6.2832 * k;
	vec2 dg = vec2(0.0);
	float hsum = 0.0;
	for (int i = 0; i < 3; i++) {
		float o = float(i);
		float lambda = erosion_scale_m * exp2(-o);
		float kv = smoothstep(2.5, 4.0, lambda / vs) * step(o + 0.5, erosion_octaves);
		if (kv > 0.0) {   // без break: цикл из 3 шагов разворачивается
			vec2 gg = g + dg * erosion_branch;
			vec2 dir = length(gg) > 1e-4 ? normalize(vec2(-gg.y, gg.x)) : vec2(1.0, 0.0);
			float a = amp0 * pow(erosion_gain, o) * kv;
			vec3 r = gully_octave3(xz / lambda + o * 17.3, dir);
			dg += r.xy * a;
			hsum += r.z * a * lambda;
		}
	}
	return hsum;
}
#endif

void vertex() {
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec2 f = (wp.xz - layer_origin) / layer_spacing;
	ivec2 ij = ivec2(round(f));
	float h = h_node(ij);
	int s = int(max(lod_stride, 1.0));
	float hx0 = h_node(ij - ivec2(s, 0));
	float hx1 = h_node(ij + ivec2(s, 0));
	float hz0 = h_node(ij - ivec2(0, s));
	float hz1 = h_node(ij + ivec2(0, s));
	vec3 n = normalize(vec3(hx0 - hx1, 2.0 * float(s) * layer_spacing, hz0 - hz1));
	// COLOR.r = 1 у вершин «юбки»: опускаем их вниз
	float dh = 0.0;
#ifndef T_RELIEF_DETAIL_OFF
	if (relief_detail_enabled) {
		vec3 cam = MAIN_CAM_INV_VIEW_MATRIX[3].xyz;
		float dcam = length(wp.xz - cam.xz);
		float kd = smoothstep(relief_near_m.x, relief_near_m.y, dcam);
		// всё — от мира и дальности, не от шага LOD: на стыках чанков разных LOD одна и та же высота
		vec2 g1 = vec2(h_node(ij + ivec2(1, 0)) - h_node(ij - ivec2(1, 0)),
				h_node(ij + ivec2(0, 1)) - h_node(ij - ivec2(0, 1))) / (2.0 * layer_spacing);
		float ks = kd * smoothstep(relief_slope_deg.x, relief_slope_deg.y, degrees(atan(length(g1))));
		// (а) окно максимумов по дальности (3D — как выбор LOD по AABB чанка)
		float lw = 0.0;
		float kp = smoothstep(relief_peak_near_m.x, relief_peak_near_m.y, dcam);
		if (use_height_max && relief_peak > 0.0 && kp > 0.0) {
			lw = clamp(relief_lod_level(length(vec3(wp.x, h, wp.z) - cam)) + relief_peak_level, 0.0, 6.0);
		}
		float ko = 1.0;
		if (ks > 0.0 || lw > 0.0) {
			// открытые склоны (не лес — ступеньки крон DSM, не вода/застройка)
			vec4 swa;
			vec4 swb;
			surface_weights_k(wp.xz, far_k(length(vec3(wp.x, h, wp.z) - cam)), swa, swb);
			ko = (1.0 - swa.x) * (1.0 - swb.y) * (1.0 - swb.z);
			ks *= ko;
		}
		if (lw > 0.0 && ko > 0.0) {
			int l0 = int(floor(lw));
			float fw = lw - float(l0);
			float m1 = relief_max_window(ij, l0 + 1);
			float m = mix(relief_max_window(ij, l0), m1, fw);
			// вершина в окне своей вершины горы: в окне вдвое шире максимум не выше (иначе это склон —
			// окно лишь «дотянулось» вверх по склону)
			float m2 = mix(m1, relief_max_window(ij, l0 + 2), fw);
			vec2 uvm = ((wp.xz - layer_origin) / layer_spacing + 0.5) / layer_texels;
			float mean = textureLod(height_mip_tex, uvm, lw + 1.0).r;
			float up = m - h + 0.5;
			float w = smoothstep(0.0, relief_peak_convex, (h - mean) / up)
					* (1.0 - smoothstep(0.0, relief_peak_summit, (m2 - m) / up));
			dh += relief_peak * w * clamp(m - h, 0.0, relief_peak_max_m) * kp * ko;
		}
		if (ks > 0.0) {
			// (б) перепад высот на relief_scale_m: холмы — как v1, высокие горы — сильнее
			float kr = 0.0;
			if (use_height_max) {
				float lr = log2(relief_scale_m / layer_spacing);
				vec2 uvr = ((wp.xz - layer_origin) / layer_spacing + 0.5) / (2.0 * vec2(max(ivec2(layer_texels) >> 1, ivec2(1))));
				vec2 uvh = ((wp.xz - layer_origin) / layer_spacing + 0.5) / layer_texels;
				float rl = textureLod(height_max_tex, uvr, max(lr - 1.0, 0.0)).r - textureLod(height_mip_tex, uvh, lr).r;
				kr = smoothstep(relief_high_m.x, relief_high_m.y, rl);
			}
			float cap = mix(relief_sharpen_max_m,
					clamp(relief_subgrid_k * layer_spacing * length(g1), relief_sharpen_max_m, relief_sharpen_cap_m), kr);
			float l1 = (h_node(ij + ivec2(1, 0)) + h_node(ij - ivec2(1, 0)) + h_node(ij + ivec2(0, 1))
					+ h_node(ij - ivec2(0, 1))) * 0.25 - h;
			float ds = clamp(-mix(relief_sharpen, relief_sharpen_high, kr) * l1, -cap, cap);
#ifndef T_EROSION_OFF
			if (erosion_enabled && relief_gully > 0.0) {
				float lod_e = clamp(log2(0.5 * erosion_scale_m / layer_spacing), 0.0, height_mip_max_lod);
				vec2 ge = height_grad(wp.xz, lod_e);
				float ek = smoothstep(erosion_slope_deg.x, erosion_slope_deg.y, degrees(atan(length(ge))));
				// шаг вершин по дальности (LOD ×2 на каждом пороге ~1,5/3,5/7 км) — непрерывно
				float vs = layer_spacing * max(1.0, dcam / relief_lod_m);
				ds += relief_gully * erosion_height(wp.xz, ge, vs, ek);
			}
#endif
			dh += ds * ks;
		}
	}
#endif
	// юбка — от высоты узла без подъёма (dh > 0): поднятая вершина не укорачивает юбку (щели LOD как в v1)
	VERTEX.y = h + dh - COLOR.r * (skirt_depth + max(dh, 0.0));
	NORMAL = n;   // только смещение теней; освещение — нормаль фрагмента (height_grad)
	v_world = vec3(wp.x, VERTEX.y, wp.z);
	int k = max(int(round(outcrop_scale_m / layer_spacing)), s);
	float gr = float(k) * layer_spacing;
	v_convex = -(h_node(ij + ivec2(k, 0)) + h_node(ij - ivec2(k, 0)) + h_node(ij + ivec2(0, k))
			+ h_node(ij - ivec2(0, k)) - 4.0 * h) / (4.0 * gr);
}

vec2 canopy_hash2(vec2 c) {
	return vec2(hash12(c * 1.31 + 7.7), hash12(c * 0.77 + 2.9));
}

#ifndef T_CANOPY_OFF
// Ближайшая крона к точке p: x — нормированное расстояние d/r, y — радиус, zw — вектор от центра.
// id — клетка кроны.
vec4 canopy_nearest(vec2 p, float cell, out vec2 id) {
	vec2 g = floor(p / cell);
	vec4 best = vec4(1e9, 1.0, 0.0, 0.0);
	id = g;
	for (int j = -1; j <= 1; j++) {
		for (int i = -1; i <= 1; i++) {
			vec2 c = g + vec2(float(i), float(j));
			vec2 pt = (c + 0.5 + (canopy_hash2(c) - 0.5) * 0.7) * cell;
			float r = cell * mix(canopy_crown_k.x, canopy_crown_k.y, hash12(c + 1.7));
			vec2 v = p - pt;
			float d = length(v) / r;
			if (d < best.x) {
				best = vec4(d, r, v);
				id = c;
			}
		}
	}
	return best;
}

// Полог леса в точке: shade — множитель яркости (освещение крон, просветы, тени соседей),
// n_c — нормаль кроны (мир), tone — множитель цвета кроны, conifer_p — доля хвойных.
void canopy(vec2 p, float cell, float conifer_p, out float shade, out vec3 n_c, out vec3 tint) {
	vec2 id;
	vec4 c = canopy_nearest(p, cell, id);
	float inside = 1.0 - smoothstep(0.85, 1.05, c.x);
	float z = sqrt(max(1.0 - c.x * c.x, 0.0));
	bool con = hash12(id + 5.5) < conifer_p;
	float hk = con ? canopy_height_k * 1.4 : canopy_height_k;
	n_c = normalize(vec3(c.z, z * c.y * hk + 0.001, c.w));
	n_c = normalize(mix(vec3(0.0, 1.0, 0.0), n_c, inside));
	vec3 sd = normalize(sun_dir);
	float lit = clamp(dot(n_c, sd), 0.0, 1.0) / max(sd.y, 0.2);
	// тень от соседней кроны, стоящей ближе к солнцу
	vec2 toward = sd.xz / max(sd.y, 0.25) * c.y * 0.9;
	vec2 id2;
	vec4 c2 = canopy_nearest(p + toward, cell, id2);
	float shadowed = (1.0 - smoothstep(0.6, 1.0, c2.x)) * (1.0 - 0.8 * z * inside)
			* float(id2 != id);
	shade = mix(canopy_gap_dark, 0.55 + 0.45 * lit, inside) * (1.0 - canopy_shadow * shadowed);
	float tv = 1.0 + canopy_tone_var * (hash12(id + 3.3) - 0.5) * 2.0;
	tint = (con ? forest_color : birch_color) * tv;
}
#endif

// --- фактура луга в трёх масштабах (terrain_look: tuft_*, stone_*, band_*, terrace_*, tone_*) ---
#ifndef T_MEADOW_DETAIL_OFF
uniform float tuft_scale_m = 9.0;             // куртины и кочки 5–20 м
uniform float tuft_strength = 0.3;
uniform float stone_cell_m = 7.0;             // шаг сетки, в клетке которой может лежать камень, м
uniform float stone_density = 0.08;           // доля клеток с камнем на лугу
uniform vec2 stone_size_m = vec2(0.4, 1.3);   // радиус камня мин/макс, м
uniform vec3 stone_color : source_color = vec3(0.44, 0.42, 0.38);
#endif
#ifndef T_MEADOW_DETAIL_OFF
uniform float band_strength = 0.85;
uniform float terrace_m = 2.2;                // шаг скотобойных тропинок по склону, м
uniform vec2 terrace_deg = vec2(16.0, 28.0);  // тропинки появляются / полностью с этого уклона
uniform float terrace_strength = 0.45;
uniform vec2 tone_scale_m = vec2(380.0, 1500.0); // крупные пятна тона, м
uniform float tone_strength = 0.18;
#endif
// --- выходы породы и курумник на гребнях/выпуклостях и крутых лугах ---
uniform vec2 snow_slope_deg = vec2(35.0, 45.0);   // снег WorldCover: держится / гаснет по уклону, градусы
uniform float snow_hollow_deg = 6.0;            // в ложбине снег держится круче на столько градусов (при вогнутости outcrop_convex_k)
uniform float snow_bare_merge = 1.0;          // выше снеговой линии голый грунт WorldCover — в один пул со снегом (0 — как класс)
uniform float snow_ridge_blow = 0.6;            // выпуклый гребень: доля снега, сдуваемая ветром (0..1)
#ifndef T_OUTCROP_OFF
uniform float kurum_share = 0.5;              // доля курумника среди выходов (остальное — коренная порода)
uniform float kurum_block_m = 2.2;            // шаг глыб курумника, м
#endif
// вблизи камни — 3D (RockScatter): рисованные глыбы и камни гаснут в этом интервале дальности, м
uniform vec2 painted_rocks_fade_m = vec2(220.0, 300.0);
#ifndef T_OUTCROP_OFF
uniform vec3 kurum_color : source_color = vec3(0.3, 0.29, 0.27);
#endif


#ifndef T_MEADOW_DETAIL_OFF
// Фактура луга: 5–20 м (куртины, кочки, камни), 20–200 м (полосы вдоль склона, скотобойные
// тропинки поперёк), 200 м–2 км (пятна тона). foot — след пикселя, м; nc — нормаль (класс);
// stones_k — множитель густоты камней (у выходов породы больше).
vec3 meadow_detail(vec2 p, vec3 c, float foot, float h, vec3 nc, float slope_deg, float stones_k) {
	const vec3 L = vec3(0.2126, 0.7152, 0.0722);
	float k1 = 1.0 - smoothstep(1.5, 7.0, foot);
	float k2 = 1.0 - smoothstep(20.0, 80.0, foot);
	float k_mid = 1.0 - smoothstep(1.5, 6.0, foot);
	float k_fine = 1.0 - smoothstep(0.4, 1.5, foot);
	vec3 c_dry = mix(c, straw_color * (dot(c, L) / max(dot(straw_color, L), 1e-3)) * 1.15, 0.7);
	vec3 c_lush = mix(c, grass_color * (dot(c, L) / max(dot(grass_color, L), 1e-3)), 0.6) * 0.8;
	// 200 м–2 км: крупные пятна тона (не гаснут вдали)
	float tone = vnoise(p / tone_scale_m.x + vec2(6.1, 2.4)) * 0.6
			+ vnoise(p / tone_scale_m.y + vec2(1.7, 8.3)) * 0.4;
	c *= 1.0 + tone_strength * 2.0 * (tone - 0.5) * vec3(1.0, 0.92, 0.65);
	// 20–200 м: полосы выгоревшей/сочной травы вдоль линии падения (на пологом — пятна)
	float sw = smoothstep(4.0, 16.0, slope_deg);
	vec2 dn = length(nc.xz) > 1e-4 ? normalize(nc.xz) : vec2(1.0, 0.0);
	float bw = band_strength * k2;
	if (bw > 0.0) {
		float b = sw < 1.0 ? vnoise(p / (band_size_m.x * 1.6) + vec2(2.3, 7.7)) : 0.5;
		if (sw > 0.0) {
			b = mix(b, fall_bands(p, dn), sw);
		}
		c = mix(c, mix(c_lush, c_dry, smoothstep(0.3, 0.7, b)), bw);
	}
	// скотобойные тропинки: вдоль горизонталей (по высоте), с шагом terrace_m по склону
	float tanv = length(nc.xz) / max(nc.y, 0.05);
	float kt = smoothstep(terrace_deg.x, terrace_deg.y, slope_deg) * terrace_strength;
	// след пикселя в долях шага (≈ fwidth фазы; без производных внутри ветвления)
	float fw = foot / max(terrace_m, 0.01);
	if (kt > 0.0 && fw < 0.6) {
		float per = max(terrace_m * tanv, 0.05);
		float ph = (h + (vnoise(p / 14.0) - 0.5) * 1.6 * per) / per;
		kt *= 1.0 - smoothstep(0.25, 0.6, fw);
		kt *= smoothstep(0.3, 0.5, vnoise(p / 18.0 + vec2(4.2, 9.9)));   // тропинки рвутся
		float fr = fract(ph);
		float path = smoothstep(0.34 - fw, 0.44, abs(fr - 0.5));
		float riser = smoothstep(0.1, 0.25, fr) * (1.0 - smoothstep(0.3, 0.45, fr));
		c = mix(c, mix(c_dry, bare_color, 0.45), path * kt);
		c *= 1.0 - 0.18 * riser * kt;
	}
	// 5–20 м: куртины гуще (темнее, зеленее) / реже (светлее, суше)
	if (k1 > 0.0) {
		float tuft = fbm(p / tuft_scale_m + vec2(2.3, 7.7), 2);
		c = mix(c, mix(c_lush, c_dry, smoothstep(0.3, 0.7, tuft)), tuft_strength * 2.0 * k1);
	}
	// кочки и пучки 2–6 м
	if (k_mid > 0.0) {
		float tus = vnoise(p / 3.5) * 0.6 + vnoise(p / 1.3) * 0.4;
		c *= mix(1.0, 0.82 + 0.36 * tus, k_mid);
		// тропинки: извилистые линии ~1,5 м (светлее, к грунту)
		float tr = abs(fbm(p / 260.0 + vec2(9.1, 3.3), 2) - 0.5);
		float path2 = (1.0 - smoothstep(0.0012, 0.003, tr)) * step(0.62, vnoise(p / 400.0));
		c = mix(c, mix(c, bare_color, 0.6), path2 * k_mid * 0.6);
	}
	if (k_fine > 0.0) {
		c *= mix(1.0, 0.92 + 0.16 * vnoise(p / 0.5), k_fine);
	}
	// камни в траве (одна клетка — один камень или пусто)
	float ks = 1.0 - smoothstep(0.3 * stone_size_m.y, 1.5 * stone_size_m.y, foot);
	if (ks > 0.0) {
		vec2 g = floor(p / stone_cell_m);
		float hs = hash12(g + vec2(41.3, 7.9));
		float dens = stone_density * stones_k * (1.0 + 2.0 * sw);
		if (hs < dens) {
			vec2 ctr = (g + 0.5 + (vec2(hash12(g + 3.1), hash12(g + 8.7)) - 0.5) * 0.5) * stone_cell_m;
			float r = mix(stone_size_m.x, stone_size_m.y, hash12(g + 5.3));
			vec2 v = (p - ctr) / r;
			v.x += 0.3 * sin(atan(v.y, v.x) * 3.0 + hs * 20.0) * length(v) * 0.3;
			float dd = length(v);
			float st = 1.0 - smoothstep(0.8, 1.0 + foot / r, dd);
			// камень — низкий купол: освещённость по его нормали (солнце), тёмная щель у земли
			// (AO) и бугристость; вокруг — тень/примятая трава
			float top = sqrt(max(1.0 - dd * dd, 0.0));
			vec3 dn3 = normalize(vec3(v.x, 1.2 * top + 0.05, v.y)
					+ 0.35 * (vec3(vnoise(p * 3.0), 0.0, vnoise(p * 3.0 + 7.7)) - 0.5));
			float lit = 0.35 + 0.8 * max(dot(dn3, sun_dir), 0.0);
			float ao = mix(0.45, 1.0, smoothstep(0.0, 0.6, top));
			vec3 sc = stone_color * (0.75 + 0.5 * hash12(g + 1.1)) * lit * ao
					* (0.85 + 0.3 * vnoise(p * 6.0 + hs * 9.0));
			float ring = smoothstep(0.9, 1.15, dd) * (1.0 - smoothstep(1.15, 1.6, dd));
			c = mix(c * (1.0 - 0.45 * ring * ks), sc, st * ks);
		}
	}
	return c;
}
#endif

#ifndef T_FIELD_DETAIL_OFF
// Фактура поля: направление обработки по участку, полосы и колеи техники, межи.
vec3 field_detail(vec2 p, vec3 c, vec3 meadow, float foot) {
	vec2 q = p / field_size_m + vec2(floor(p.y / (field_size_m.y * 6.0)) * 0.37, 0.0);
	vec2 cell = floor(q);
	vec2 f = q - cell;
	float h = hash12(cell + 19.1);
	vec2 dir = h < 0.5 ? vec2(1.0, 0.0) : vec2(0.0, 1.0);   // полосы вдоль длинной/короткой стороны
	float along = dot(p, vec2(dir.y, dir.x));
	float k_mid = 1.0 - smoothstep(2.0, 8.0, foot);
	float k_big = 1.0 - smoothstep(8.0, 30.0, foot);
	// борозды ~3 м
	c *= mix(1.0, 0.9 + 0.2 * (0.5 + 0.5 * sin(along * 6.2832 / 3.0)), k_mid);
	// технологические колеи каждые 18 м (тёмные двойные линии)
	float tram = abs(fract(along / 18.0) - 0.5) * 18.0;
	c *= 1.0 - 0.25 * (1.0 - smoothstep(0.3, 0.9, tram)) * k_mid;
	// спелость пятнами по полю
	c *= mix(1.0, 0.88 + 0.24 * fbm(p / 45.0 + h * 13.0, 2), k_big);
	// межа: полоса травы по краю участка ~3 м
	vec2 e = min(f, 1.0 - f) * field_size_m;
	float edge = 1.0 - smoothstep(1.5, 3.0, min(e.x, e.y));
	return mix(c, meadow * 0.9, edge * k_big);
}
#endif

// --- ветер с высоты (configs/world.json → wind_visual: wind_far_*; задаёт TerrainWind) ---
uniform float wind_far_gust_m = 320.0;   // размер бегущих пятен порывов, м
uniform float wind_far_wave_m = 45.0;    // длина серебристой волны по траве вдоль ветра, м
uniform float wind_far_shade = 0.14;     // посветление травы в порыве (доля яркости)
uniform float wind_far_silver = 0.1;     // доля «серебра» (к серому) в порыве
uniform float wind_far_fade_m = 3500.0;  // дальше этого волн не видно (мягко от 0,6 этой дальности), м
uniform float wind_far_morph_k = 0.75;   // второй слой пятен бежит медленнее — пятна меняют форму

// Поле крупных порывов (0..1): пятна вытянуты поперёк ветра (фронт порыва), бегут по ветру.
// d — единичный вектор ветра; foot — размер пикселя в мире, м. Общее для травы и воды (VR-16).
float wind_far_gusts(vec2 xz, vec2 d, float foot) {
	vec2 dp = vec2(-d.y, d.x);
	vec2 p1 = xz - wind_offset * wind_gust_speed_k;
	vec2 p2 = xz - wind_offset * wind_gust_speed_k * wind_far_morph_k;
	vec2 a1 = vec2(dot(p1, d) / wind_far_gust_m, dot(p1, dp) / (wind_far_gust_m * 1.6));
	vec2 a2 = vec2(dot(p2, d) / (wind_far_gust_m * 0.55), dot(p2, dp) / (wind_far_gust_m * 0.8));
	// шум — из текстуры macro_noise_tex (пятно = MACRO_NOISE_FEATURE текселей)
	float lod = log2(max(foot * MACRO_NOISE_SIZE / (MACRO_NOISE_FEATURE * wind_far_gust_m), 1e-3)) + 1.0;
	float g = textureLod(macro_noise_tex, (a1 + vec2(3.7, 1.1)) / MACRO_NOISE_FEATURE, lod).z * 0.6
			+ textureLod(macro_noise_tex, (a2 + vec2(8.2, 5.5)) / MACRO_NOISE_FEATURE, lod - 0.8).w * 0.4;
	return smoothstep(0.36, 0.76, g);
}

#ifndef T_GRASS_WIND_OFF
// Крупные порывы и серебристая волна (0..~1) — видны с сотен метров до wind_far_fade_m.
// Рисунок сдвигается накопленным на CPU wind_offset (без TIME) — смена ветра не даёт скачка.
float grass_wind_far(vec2 xz, float dist, float foot) {
	if (dist > wind_far_fade_m || wind_far_shade <= 0.0) {
		return 0.0;
	}
	float spd = length(wind_vec);
	float amp = smoothstep(0.5, wind_full_ms, spd);
	if (amp <= 0.0) {
		return 0.0;
	}
	amp *= 1.0 + gust_gain * smoothstep(0.0, gust_full_ms, wind_gust_ms);
	amp *= 1.0 - smoothstep(wind_far_fade_m * 0.6, wind_far_fade_m, dist);
	vec2 d = wind_vec / spd;
	vec2 dp = vec2(-d.y, d.x);
	vec2 p1 = xz - wind_offset * wind_gust_speed_k;
	float g = wind_far_gusts(xz, d, foot);
	// серебристая волна: фронты поперёк ветра, изогнуты шумом, гаснут, когда мельче пикселя
	float kw = 1.0 - smoothstep(0.12 * wind_far_wave_m, 0.35 * wind_far_wave_m, foot);
	float wave = 0.0;
	if (kw > 0.0) {
		float along = dot(p1, d) / wind_far_wave_m;
		float bend = textureLod(macro_noise_tex, (vec2(dot(p1, dp), dot(p1, d)) / (wind_far_wave_m * 5.0)
				+ vec2(1.9, 7.3)) / MACRO_NOISE_FEATURE, 0.0).x;
		wave = (0.5 + 0.5 * sin(6.2832 * (along + 2.0 * bend))) * kw;
	}
	return amp * g * (0.4 + 0.6 * wave + 0.6 * (1.0 - kw) * 0.5);
}
#endif

#ifdef T_GRASS_WIND_OFF
// Подсос над термиками без ветра по траве (замена части GRASS_WIND, SL-23) — цикл термиков из
// grass_wind (terrain_wind.gdshaderinc), та же картинка у термика.
void grass_thermals(vec2 xz, float t, float fine, inout float shade, inout vec2 bend) {
	for (int k = 0; k < wind_thermal_count; k++) {
		vec4 th = wind_thermals[k];
		vec2 v = xz - th.xy;
		float r = length(v);
		float s = r / max(th.z, 1.0);
		if (s > thermal_reach) {
			continue;
		}
		float env = th.w * (1.0 - smoothstep(thermal_reach * 0.5, thermal_reach, s))
				* smoothstep(0.05, 0.35, s);
		float ang = atan(v.y, v.x);
		float wob = wind_noise(v / 25.0 + vec2(float(k) * 7.1, t * 0.2));
		float ph = r / thermal_ring_m + t * thermal_inflow_hz + ang * thermal_arms / 6.2832
				+ 2.5 * wob;
		float wave = (0.5 + 0.5 * sin(6.2832 * ph)) * smoothstep(0.2, 0.7, wind_noise(v / 11.0 + 3.7 + t * 0.3));
		float tw = env * (0.45 + 0.55 * wave * mix(0.6, 1.0, fine)) * thermal_gain;
		vec2 inward = r > 0.1 ? -v / r : vec2(0.0);
		vec2 swirl = vec2(-inward.y, inward.x);
		shade = max(shade, tw);
		bend = mix(bend, (inward + 0.4 * swirl) * tw, clamp(env, 0.0, 1.0));
	}
}
#endif

#ifndef T_WATER_WIND_OFF
// Вода от ветра (VR-16): штиль — зеркало; ветер — матовая рябь; в пятнах порывов рябь сильнее
// («кошачьи лапы»: темнее — меньше отражения неба, против солнца — искрятся); у наветренного
// берега — гладкая полоса ветровой тени. Цвет воды не трогаем — всё через нормаль и шероховатость.
// rough — шероховатость; nw — нормаль воды (мир); rip — рябь −0,5..0,5 (лёгкий оттенок).
void water_wind(vec2 xz, float dist, float foot, out float rough, out vec3 nw, out float rip) {
	// поле ветра (AM-10, WF-10): рябь по локальному ветру поля, если есть (та же текстура, что
	// у травы) — штиль в ветровой тени рельефа, сильнее у бровки; без поля — прежний wind_vec.
	vec2 local_wind = wind_vec;
	if (field_wind_size_m > 0.0) {
		vec2 fuv = (xz - field_wind_origin) / field_wind_size_m;
		if (fuv.x > 0.0 && fuv.x < 1.0 && fuv.y > 0.0 && fuv.y < 1.0) {
			local_wind = texture(field_wind_tex, fuv).rg;
		}
	}
	float spd = length(local_wind);
	vec2 d = spd > 0.05 ? local_wind / spd : vec2(1.0, 0.0);
	// ветровая тень: суша с наветра (маска воды 10 м, 4 выборки ~0,13–1 × water_lee_m) — ближе
	// берег, сильнее тень
	float lee = 0.0;
	if (use_forest_mask && water_lee_m > 0.0 && spd > water_wind_calm_ms) {
		lee = max(lee, 1.0 - forest_mask_g(xz - d * water_lee_m * 0.13));
		lee = max(lee, (1.0 - forest_mask_g(xz - d * water_lee_m * 0.33)) * 0.85);
		lee = max(lee, (1.0 - forest_mask_g(xz - d * water_lee_m * 0.62)) * 0.6);
		lee = max(lee, (1.0 - forest_mask_g(xz - d * water_lee_m)) * 0.35);
	}
	// порывы: то же поле, что у травы с высоты; порывистость атмосферы усиливает
	float gust = 0.0;
	if (spd > water_wind_calm_ms && dist < wind_far_fade_m) {
		gust = wind_far_gusts(xz, d, foot) * (1.0 - smoothstep(wind_far_fade_m * 0.6, wind_far_fade_m, dist));
		gust *= 1.0 + gust_gain * smoothstep(0.0, gust_full_ms, wind_gust_ms);
	}
	float w_eff = spd * (1.0 - water_lee_calm * lee) * (1.0 + 0.6 * gust);
	float k = smoothstep(water_wind_calm_ms, water_wind_full_ms, w_eff);
	float tilt = water_ripple_tilt * k + water_gust_tilt * gust * (1.0 - lee);
	rough = mix(water_roughness, water_rough_wind, k) + water_gust_rough * gust * (1.0 - lee);
	// мелкая рябь: гребни поперёк ветра, бегут по ветру; две октавы, градиент конечными разностями
	vec2 dp = vec2(-d.y, d.x);
	vec2 p = xz - wind_offset * 0.35 + vec2(TIME * 0.15, 0.0);
	vec2 a = vec2(dot(p, d), dot(p, dp) * 0.5) / water_ripple_m;
	float e = 0.25;
	float r0 = vnoise(a);
	float r1 = vnoise(a * 0.33 + 7.1);
	rip = (r0 * 0.6 + r1 * 0.4) - 0.5;
	// рябь мельче пикселя — не нормалью (мерцает), а шероховатостью
	float kn = 1.0 - smoothstep(0.3 * water_ripple_m, 1.5 * water_ripple_m, foot);
	nw = vec3(0.0, 1.0, 0.0);
	if (kn > 0.0 && tilt > 0.0) {
		float gx = (vnoise(a + vec2(e, 0.0)) - r0) * 0.6 + (vnoise(a * 0.33 + 7.1 + vec2(e * 0.33, 0.0)) - r1) * 0.4;
		float gy = (vnoise(a + vec2(0.0, e)) - r0) * 0.6 + (vnoise(a * 0.33 + 7.1 + vec2(0.0, e * 0.33)) - r1) * 0.4;
		vec2 g = (d * gx + dp * gy * 0.5) / e;
		nw = normalize(vec3(-g.x * tilt * kn, 1.0, -g.y * tilt * kn));
	}
	rough += tilt * (1.0 - kn) * 0.8;
	rough = clamp(rough, 0.0, 0.8);
}
#endif

#ifndef T_ROCK_SURFACE_OFF
// Трещины-кулуары и полосы осыпей одного направления d (линии вдоль d): x — трещина, y — полоса.
vec2 rock_fall_lines(vec2 p, vec2 d, float foot) {
	vec2 q = vec2(dot(p, vec2(-d.y, d.x)), dot(p, d));
	float cn = vnoise(vec2(q.x / rock_crack_m, q.y / (rock_crack_m * 3.0)) + vec2(5.5, 0.9));
	float crack = 1.0 - smoothstep(0.0, 0.05 + foot / rock_crack_m * 0.25, abs(cn - 0.5));
	float sn = vnoise(vec2(q.x / (rock_crack_m * 1.5), q.y / (rock_crack_m * 6.0)) + vec2(2.2, 9.4));
	return vec2(crack, smoothstep(0.6, 0.72, sn));
}

// Рисунок вдоль линии падения без сетки: направление уклона (hg — градиент высот) на пологом
// плавно уходит к постоянному (там оно шумит от ячейки к ячейке текстуры высот); рисунок не
// поворачивается за направлением непрерывно (q = поворот мировых координат: сдвиг ∝ |p|·Δугла
// рвал его на каждой ячейке), а берётся у двух соседних фиксированных направлений с шагом
// rock_fall_bin_deg и смешивается по углу. Ось рисунка без знака: углы по модулю 180°.
vec2 rock_fall_pattern(vec2 p, vec2 hg, float foot) {
	float g = length(hg);
	float kf = smoothstep(tan(radians(rock_fall_flat_deg.x)), tan(radians(rock_fall_flat_deg.y)), g);
	vec2 v = -hg / max(g, 1e-6) * kf + vec2(1.0, 0.0) * (1.0 - kf);
	float bin = radians(max(rock_fall_bin_deg, 5.0));
	float nb = floor(PI / bin + 0.5);
	float a = mod(atan(v.y, v.x), PI) / (PI / nb);
	float i0 = floor(a);
	float t = smoothstep(0.3, 0.7, a - i0);
	vec2 r = vec2(0.0);
	if (t < 0.999) {
		float a0 = mod(i0, nb) * PI / nb;
		r += rock_fall_lines(p, vec2(cos(a0), sin(a0)), foot) * (1.0 - t);
	}
	if (t > 0.001) {
		float a1 = mod(i0 + 1.0, nb) * PI / nb;
		r += rock_fall_lines(p, vec2(cos(a1), sin(a1)), foot) * t;
	}
	return r;
}
#endif

// Мип-уровень по следу пикселя foot (м): тексель уровня ≈ пиксель; не мельче базовой сетки.
float height_lod(float foot) {
	return clamp(log2(max(foot, 1e-3) / layer_spacing), 0.0, height_mip_max_lod);
}

#ifndef T_EROSION_OFF
// Промоины: вклад одной ячейки сетки (шаг 1) — полосы вдоль линии падения (фаза — вдоль
// горизонтали dir) с началом фазы в сдвинутом центре ячейки. Производная рисунка cos по p.
vec2 gully_cell(vec2 ip, vec2 fp, vec2 o, vec2 dir) {
	float hs = hash12(ip + o);
	vec2 pp = fp - o - (vec2(hs, fract(hs * 37.17)) - 0.5) * 0.5;
	return -sin(dot(pp, dir) * 6.2832) * dir;
}

// Промоины: одна октава — 4 ближайшие ячейки, смешанные гладкими весами (как value noise;
// у ячеек разная фаза — полосы рвутся и сдвигаются). Возвращает производную рисунка по p
// (значение не нужно — только нормаль), |·| ≤ 2π.
// Без циклов (здесь и в erosion_grad): цикл с телом такого размера драйвер (NVIDIA) не
// разворачивает и не выбрасывает из прохода глубины/теней, где нужен только discard, — туда
// тянется вся раскраска, от которой зависит сила (замер: тени +2,5 мс).
vec2 gully_octave(vec2 p, vec2 dir) {
	vec2 ip = floor(p);
	vec2 fp = p - ip;
	vec2 u = fp * fp * (3.0 - 2.0 * fp);
	vec2 a = mix(gully_cell(ip, fp, vec2(0.0, 0.0), dir), gully_cell(ip, fp, vec2(1.0, 0.0), dir), u.x);
	vec2 b = mix(gully_cell(ip, fp, vec2(0.0, 1.0), dir), gully_cell(ip, fp, vec2(1.0, 1.0), dir), u.x);
	return mix(a, b, u.y) * 6.2832;
}

// Октава o (0, 1, 2…) промоин: шаг erosion_scale_m / 2^o, ориентирована по уклону g с учётом
// предыдущих октав dg — промоины ветвятся. Октава мельче ~3 пикселей — без неё (муар).
vec2 erosion_octave(vec2 xz, vec2 g, vec2 dg, float o, float foot, float amp0) {
	float lambda = erosion_scale_m * exp2(-o);
	float kaa = (1.0 - smoothstep(0.15 * lambda, 0.35 * lambda, foot))
			* step(o + 0.5, erosion_octaves);
	if (kaa <= 0.0) {
		return dg;
	}
	vec2 gg = g + dg * erosion_branch;
	vec2 dir = length(gg) > 1e-4 ? normalize(vec2(-gg.y, gg.x)) : vec2(1.0, 0.0);
	return dg + gully_octave(xz / lambda + o * 17.3, dir) * amp0 * pow(erosion_gain, o) * kaa;
}

// Возмущение градиента высоты промоинами в точке xz: g — уклон в масштабе промоин (мир),
// foot — след пикселя, м; k — общая сила (маска поверхности × крутизна × дальность).
// До 4 октав (erosion_octaves).
vec2 erosion_grad(vec2 xz, vec2 g, float foot, float k) {
	float amp0 = erosion_strength * length(g) / 6.2832 * k;
	vec2 dg = erosion_octave(xz, g, vec2(0.0), 0.0, foot, amp0);
	dg = erosion_octave(xz, g, dg, 1.0, foot, amp0);
	dg = erosion_octave(xz, g, dg, 2.0, foot, amp0);
	dg = erosion_octave(xz, g, dg, 3.0, foot, amp0);
	return dg;
}
#endif


void fragment() {
	vec3 wp = v_world;
	v_cs_sun = cloud_sun_at(wp);
	if (all(greaterThan(wp.xz, hole_min)) && all(lessThan(wp.xz, hole_max))) {
		discard;
	}
	float dist = length(wp - CAMERA_POSITION_WORLD);
	float h = wp.y;
	float fade = 1.0 - smoothstep(detail_fade_m * 0.25, detail_fade_m, dist);
	vec2 fw_m = fwidth(wp.xz);
	float foot_m = max(fw_m.x, fw_m.y);
	// Нормаль рельефа — во фрагменте, из мипов текстуры высот: вблизи центральные разности с
	// шагом базовой сетки слоя (±1 узел, как прежняя нормаль вершины LOD 0), вдали — средний
	// уклон по следу пикселя (не мерцает). От LOD меша не зависит: вдали детали не «надуты»
	// крупными треугольниками, на стыках LOD нормаль одна и та же. По ней же классификация
	// (уклон, экспозиция); ступеньку крон DSM на опушке вычитаем ниже по маске 10 м.
	float foot_px = max(length(dFdx(wp.xz)), length(dFdy(wp.xz)));
	float n_lod = height_lod(foot_px);
	float n_d = layer_spacing * exp2(n_lod);   // полушаг разностей нормали, м
	vec2 hg = height_grad(wp.xz, n_lod);
	vec3 n_class = normalize(vec3(-hg.x, 1.0, -hg.y));
	vec3 n = n_class;

	vec4 wa;
	vec4 wb;
	float kfar = far_k(dist);   // гашение частей, которых нет в дальнем варианте (стык LOD, SL-23)
	surface_weights_k(wp.xz, kfar, wa, wb);
	// Подложка застройки (NO-10): размытая доля detail_built10 вместо квадратов 25 м класса built.
	if (use_built_soft) {
		vec2 buv = ((wp.xz - built_soft_origin) / built_soft_spacing + 0.5) / built_soft_texels;
		float bs = textureLod(built_soft_tex, buv, 0.0).r;
		float bn = smoothstep(built_soft_range.x, built_soft_range.y, bs) * built_soft_max;
		float bo = wb.z;
		float rest = 1.0 - bo;
		float kr = (1.0 - bn) / max(rest, 0.02);
		wa *= kr;
		wb *= kr;
		wa.y += (1.0 - bn) - rest * kr;
		wb.z = bn;
	}
	// поля рельефа: влажность (−1 сухо … +1 сыро), AO, сглаженная северность, горизонт к солнцу
	vec4 rel = vec4(0.5, 1.0, 0.5, 0.0);
	if (use_relief) {
		vec2 ruv = ((wp.xz - relief_origin) / relief_cell_m + 0.5) / relief_texels;
		rel = textureLod(relief_tex, ruv, 0.0);
	}
	float hz_deg = rel.a * 60.0;   // SL-К7: горизонт — канал A relief_tex (без полей A = 0)
	float wet = rel.r * 2.0 - 1.0;
	float north_s = rel.b * 2.0 - 1.0;
	// глубина внутри леса 0..1 (затемнение опушки — только внутри)
	float forest_in = smoothstep(0.5, 0.95, wa.x);
	// Лес — по маске 10 м: резкий порог 0,5 с узким шумом; вдали (клетка мельче пикселя) —
	// карта классов 25 м (и без выборок из большой маски — дёшево). Остальные классы делят долю
	// «не лес» в прежней пропорции.
#ifndef T_FOREST_EDGE_OFF
	float k10 = use_forest_mask
			? 1.0 - smoothstep(forest_mask_spacing, 2.5 * forest_mask_spacing, foot_m) : 0.0;
	if (k10 > 0.0) {
		vec2 q = wp.xz;
		vec2 jit = vec2(vnoise(q / 9.0), vnoise(q / 9.0 + vec2(5.2, 1.3))) - 0.5;
		float r0 = forest_mask_r(q + jit * forest_edge_warp_m);
		float nz = vnoise(q / 3.0 + vec2(1.7, 9.2)) - 0.5;
		float f10 = smoothstep(0.5 - forest_edge_soft, 0.5 + forest_edge_soft,
				r0 + nz * forest_edge_noise);
		// окрестность ±d (шаг нормали): ступенька крон DSM и глубина в лесу
		float d = max(n_d, canopy_edge_depth_m);
		float rx1 = forest_mask_r(q + vec2(d, 0.0));
		float rx0 = forest_mask_r(q - vec2(d, 0.0));
		float rz1 = forest_mask_r(q + vec2(0.0, d));
		float rz0 = forest_mask_r(q - vec2(0.0, d));
		float fnew = mix(wa.x, f10, k10);
		float rest = 1.0 - wa.x;
		float kr = (1.0 - fnew) / max(rest, 0.02);
		wa.yzw *= kr;
		wb *= kr;
		wa.y += (1.0 - fnew) - rest * kr;   // под «не лес» в лесной клетке 25 м — луг
		wa.x = fnew;
		float r_min = min(min(rx0, rx1), min(rz0, rz1));
		forest_in = mix(forest_in, smoothstep(0.3, 0.9, min(r_min, r0 + 0.3)), k10);
		// Уклон земли у кромки — без ступеньки крон: градиент DSM минус H·градиент маски.
		// Лес освещается по DSM (кроны), луг и классы по уклону — по «земле».
		vec2 g = k10 * canopy_dsm_height_m * vec2(rx1 - rx0, rz1 - rz0) / (2.0 * d);
		vec2 gc = n_class.xz / max(n_class.y, 0.05) + g;
		n_class = normalize(vec3(gc.x, 1.0, gc.y));
		vec2 gn = n.xz / max(n.y, 0.05) + g * (1.0 - wa.x);
		n = normalize(vec3(gn.x, 1.0, gn.y));
	}
#else
	float k10 = 0.0;   // кромка леса — по карте классов 25 м (как вдали)
#endif
	float slope_deg = degrees(acos(clamp(n_class.y, 0.0, 1.0)));
	float forest = wa.x;
#ifndef T_SL_TRAILS_OFF
	float sl_fh = fwidth(h); // SL
#endif
	float crop = wa.z;
	float shrub = wa.w;
	float bare = wb.x;
	float built = wb.z;
	float snow = wb.w;
	// снег класса 8: на крутом гаснет (порода видна), в ложбинах держится, с выпуклых гребней сдут;
	// выше снеговой линии голый грунт (класс 5, пёстрая смесь с 8) — тот же пул: снег или порода решает
	// уклон/вогнутость, а не пёстрая карта классов; кромка рваная (как у скал), без завитков карты классов
	float snow_rest = 1.0;
	float snow_alp = snow_bare_merge * smoothstep(gully_snow_line_m - 150.0, gully_snow_line_m + 150.0, h);
	float snow_pool = snow + bare * snow_alp;
	if (snow_pool > 0.001) {
		float cv = v_convex / outcrop_convex_k;
		float s_eff = slope_deg - snow_hollow_deg * smoothstep(0.0, 1.0, -cv);
		float keep = (1.0 - smoothstep(snow_slope_deg.x, snow_slope_deg.y, s_eff))
				* (1.0 - snow_ridge_blow * smoothstep(0.7, 1.6, cv) * smoothstep(22.0, 32.0, slope_deg));
		float snow_new = ragged_edge(snow_pool * keep, wp.xz + 31.0, foot_m);
		float dsn = snow_new - snow;
		float rest_old = max(1.0 - snow - bare, 0.0);
		float excess = max(dsn - bare, 0.0);
		snow_rest = rest_old > 1e-3 ? max(rest_old - excess, 0.0) / rest_old : 1.0;
		bare = max(bare - dsn, 0.0);   // освободившаяся доля — грунт; скалы подхватят её по уклону
		snow = snow_new;
	}
	float north = northness(n_class);
	float patch2 = meadow_patch(wp.xz);

	// --- выходы породы и курумник: гребни/бугры (выпуклость по сетке высот) и крутые луга ---
	float outcrop = 0.0;
	float kurum = 0.0;
	float open_w = wa.y + shrub + bare;
#ifndef T_OUTCROP_OFF
	if (open_w > 0.01 && outcrop_amount > 0.0 && kfar > 0.0) {
		float convex;
		float steep;
		float drv;
		outcrop = gc_outcrop(wp.xz, slope_deg, n_class, v_convex / outcrop_convex_k, foot_m, kfar,
				convex, steep, drv);
		if (drv > 0.01) {
			kurum = clamp(smoothstep(0.35, 0.65, vnoise(wp.xz / 160.0 + vec2(3.3, 1.1))
					+ kurum_share - 0.5) + 0.35 * (steep - convex), 0.0, 1.0);
		}
	}
#endif

	// --- луг: сухая трава на южных склонах и пятнами ---
	vec3 gcol = meadow_ground_color(wp.xz, north, patch2, wet, north_s);
	gcol = sl_meadow(gcol, wp); // SL
#ifndef T_SL_SEASON_OFF
	float sl_rel; vec4 sl_ss = sl_season_b(h, sl_rel); // SL
	gcol = sl_meadow_season(gcol, sl_ss); // SL
#endif

	float tex_w = fade * texture_strength;

	// --- пашня/поля: прямоугольные участки разного цвета (пашня, всходы, стерня) ---
	vec3 fcol = field_plot_color(wp.xz, gcol);
#ifndef T_SL_SEASON_OFF
	if (crop > 0.01) fcol = sl_field_season(fcol, wp.xz, sl_rel); // SL
#endif
#ifndef T_FIELD_DETAIL_OFF
	if (crop > 0.01) {
		fcol = field_detail(wp.xz, fcol, gcol, foot_m);
	}
#endif
	if (wa.y + wa.w + crop > 0.01) {
#ifndef T_MEADOW_DETAIL_OFF
		if (kfar > 0.0) {
			float painted_k = smoothstep(painted_rocks_fade_m.x, painted_rocks_fade_m.y, dist);
			gcol = mix(gcol, meadow_detail(
				wp.xz, gcol, foot_m, h, n_class, slope_deg, (1.0 + 6.0 * outcrop) * painted_k
			), kfar);
		}
#endif
#ifndef T_SL_TRAILS_OFF
		gcol = sl_trails(gcol, wp.xz, h, n_class, slope_deg, sl_fh, sun_dir, dist); // SL
#endif
	}
	// пятна с высоты: оттенок/яркость 20 м … 2 км, выгоревшие пятна, покосы (после фактуры
	// луга — её полосы не смывают оттенок пятен)
#ifndef T_MEADOW_MACRO_OFF
	if (wa.y + shrub > 0.01) {
		gcol = meadow_macro(wp.xz, gcol, foot_m, wet, dist,
				wa.y * (1.0 - smoothstep(mow_max_slope_deg * 0.6, mow_max_slope_deg, slope_deg)));
	}
#endif

	// --- кустарник: пятнистая тёмная зелень на траве ---
	float bush = smoothstep(0.35, 0.65, fbm(wp.xz / (detail_scale_m * 3.0), 3));
	vec3 scol = mix(gcol, shrub_color, mix(0.6, 1.0, bush * fade + (1.0 - fade) * 0.5));

	vec3 col = gcol * wa.y + fcol * crop + scol * shrub;
	vec3 gn_add = vec3(0.0);
#ifndef T_GRASS_TEX_OFF
	if (use_grass_tex) {
		float gw = tex_w * (wa.y + crop + shrub);
		vec2 guv = wp.xz / grass_tex_tile_m;
		vec2 gdx = dFdx(guv);
		vec2 gdy = dFdy(guv);
		float gnear = 1.0 - smoothstep(grass_near_m.x, grass_near_m.y, dist);
		if (gw > 0.0) {
			float gb;
			vec4 go = notile_offsets(guv, gb);
			vec3 ta = textureGrad(grass_tex, guv + go.xy, gdx, gdy).rgb;
			vec3 tb = textureGrad(grass_tex, guv + go.zw, gdx, gdy).rgb;
			vec3 t = mix(ta, tb, smoothstep(0.0, 1.0, gb - 0.1 * dot(ta - tb, vec3(1.0))));
			// вдали — прежний рисунок (яркость); вблизи — контрастнее и с цветовыми пятнами
			// текстуры в палитре локации (цвет/средний цвет × процедурный: сухость сохраняется)
			const vec3 L = vec3(0.2126, 0.7152, 0.0722);
			float avg_l = max(dot(grass_tex_avg, L), 1e-3);
			float r = clamp(pow(dot(t, L) / avg_l, mix(texture_contrast, grass_near_contrast, gnear)),
					mix(0.4, 0.3, gnear), mix(1.7, 2.0, gnear));
			vec3 chroma = clamp(t / max(grass_tex_avg, vec3(1e-3)) / max(dot(t, L) / avg_l, 1e-3), 0.6, 1.6);
			vec3 cn = col * r * mix(vec3(1.0), chroma, grass_near_color_mix * gnear);
			col = mix(col, mix(cn, t / avg_l * dot(col, L), texture_color_mix * (1.0 - gnear)), gw);
			// крупный масштаб той же текстуры (×grass_macro_k): пятна пучков и проплешин там,
			// где мелкий рисунок уже усреднён мипами (10–150 м)
			float mb;
			vec2 muv = guv / grass_macro_k + 0.37;
			vec4 mo = notile_offsets(muv, mb);
			float ml = dot(mix(textureGrad(grass_tex, muv + mo.xy, gdx / grass_macro_k, gdy / grass_macro_k).rgb,
					textureGrad(grass_tex, muv + mo.zw, gdx / grass_macro_k, gdy / grass_macro_k).rgb, mb), L) / avg_l;
			col *= mix(1.0, clamp(pow(ml, 1.2), 0.5, 1.6), grass_macro_strength * gw);
			if (use_grass_normal && gnear > 0.0) {
				vec3 na = textureGrad(grass_normal_tex, guv + go.xy, gdx, gdy).rgb;
				vec3 nb = textureGrad(grass_normal_tex, guv + go.zw, gdx, gdy).rgb;
				vec3 nt = mix(na, nb, gb);
				// касательная плоскость xz: u → x, v → z; B — AO травы
				gn_add = vec3(nt.x * 2.0 - 1.0, 0.0, nt.y * 2.0 - 1.0) * grass_normal_strength * gnear * gw;
				col *= mix(1.0, clamp(nt.z / 0.8, 0.2, 1.2), grass_ao_strength * gnear * gw);
			}
		}
	}
#endif

	// --- ветер (VR-17): волны порывов по траве и ниве, закрученный подсос над термиками ---
#ifndef T_GRASS_WIND_OFF
	float sway_w = wa.y + 1.3 * crop + 0.5 * shrub;
#endif
	vec2 grass_bend = vec2(0.0);
#ifndef T_GRASS_WIND_OFF
	if (sway_w > 0.01) {
		float wshade;
		grass_wind(wp.xz, dist, TIME, wshade, grass_bend);
		col *= 1.0 + wind_shade * wshade * sway_w;
		grass_bend *= wind_bend * sway_w;
		// с высоты: крупные бегущие пятна порывов и серебристая волна по траве вдоль ветра
		float far = grass_wind_far(wp.xz, dist, foot_m) * min(sway_w, 1.3);
		if (far > 0.0) {
			const vec3 LS = vec3(0.2126, 0.7152, 0.0722);
			vec3 silver = vec3(dot(col, LS)) * vec3(0.97, 1.0, 1.04);
			col = mix(col, silver, clamp(wind_far_silver * far, 0.0, 1.0)) * (1.0 + wind_far_shade * far);
#ifndef T_SL_WIND_SHEEN_OFF
			col = sl_wind_sheen(col, far, wind_far_shade, wind_vec, normalize(CAMERA_POSITION_WORLD - wp)); // SL
#endif
		}
	}
#else
	// без колыхания от ветра (порывы, рябь, волны с высоты) остаётся подсос над термиками. Он и
	// дешёвый (вне термиков — 0 итераций), и нужен компилятору: без этого цикла NVIDIA собирает
	// весь шейдер хуже — кадр дороже на 0,4–0,7 мс при нулевой работе цикла (SL-23)
	float sway_w = wa.y + 1.3 * crop + 0.5 * shrub;
	if (sway_w > 0.01 && dist < wind_fade_m) {
		float tsh = 0.0;
		grass_thermals(wp.xz, TIME, 1.0 - smoothstep(wind_fade_m * 0.15, wind_fade_m * 0.5, dist), tsh, grass_bend);
		col *= 1.0 + wind_shade * tsh * sway_w;
		grass_bend *= wind_bend * sway_w;
	}
#endif

	// --- голый грунт / осыпи ---
	vec3 bcol = bare_color * (0.8 + 0.4 * fbm(wp.xz / 25.0 + vec2(3.3, 8.1), 3));
	// --- застройка: кварталы (крыши, дворы, дороги) ---
	vec3 ucol;
	if (use_built_soft) {
		// плавно: пятна дворов/садов и оттенка крыш без границ квадратов
		float bn1 = vnoise(wp.xz / 35.0 + vec2(3.3, 7.7));
		ucol = built_color * (0.85 + 0.3 * vnoise(wp.xz / 14.0));
		ucol = mix(ucol, gcol * 0.9, 0.2 + 0.5 * smoothstep(0.45, 0.7, bn1));
	} else {
		vec2 blk = floor(wp.xz / 18.0);
		float bh = hash12(blk + 3.3);
		ucol = built_color * (0.7 + 0.6 * bh);
		ucol = mix(ucol, gcol * 0.9, step(0.72, bh));   // дворы, сады
	}
	// --- снег ---
	vec3 wcol = snow_color;
	if (use_snow_tex) {
		wcol = apply_tex(wcol, texture(snow_tex, wp.xz / snow_tex_tile_m).rgb, snow_tex_avg, tex_w);
	}
#ifndef T_SL_GLACIER_OFF
	wcol = sl_glacier(wcol, wp.xz, n_class, slope_deg, v_convex / outcrop_convex_k, h, foot_m); // SL
#endif
	col = (col + ucol * built) * snow_rest + bcol * bare + wcol * snow;

	// --- лес: полог из крон (ячейки canopy_cell_m) с освещением и тенями; вдали — средний тон ---
	float con_p = conifer_share(patch2, north);
	vec3 fmean = mix(birch_color, forest_color, con_p);
	float foot = foot_m;
	float crown_k = 1.0 - smoothstep(0.2 * canopy_cell_m, 0.8 * canopy_cell_m, foot);
	// средний тон полога вдали: смесь крон и теней под ними приглушает цвет (по фото (a) стенда T01)
	// (плавно по следу пикселя 1–4 шага крон — без кольца на границе детального полога)
	float far_k = smoothstep(0.8 * canopy_cell_m, 2.5 * canopy_cell_m, foot_m);
	vec3 fcolor = mix(fmean * 0.62, mix(vec3(dot(fmean, vec3(0.2126, 0.7152, 0.0722))), fmean,
			canopy_far_sat) * canopy_far_shade, far_k);
	vec3 crown_n = vec3(0.0, 1.0, 0.0);
#ifndef T_CANOPY_OFF
	// куртины (группы крон, ×3 шага) — видны до нескольких км, когда отдельные кроны уже мельче пикселя
	float grp_cell = canopy_cell_m * 3.0;
	float grp_k = 1.0 - smoothstep(0.2 * grp_cell, 0.8 * grp_cell, foot);
	// город с деревьями-моделями: кроны на земле не рисуем (деревья стоят на местах кроны)
	float city_k = 0.0;
	if (use_city_canopy && forest > 0.01) {
		vec2 cuv = ((wp.xz - city_canopy_origin) / city_canopy_cell_m + 0.5) / city_canopy_texels;
		city_k = smoothstep(0.4, 0.5, textureLod(city_canopy_tex, cuv, 0.0).r);
		city_k *= 1.0 - smoothstep(city_canopy_range_m.x, city_canopy_range_m.y, length(wp.xz - CAMERA_POSITION_WORLD.xz));
		crown_k *= 1.0 - city_k;
		grp_k *= 1.0 - city_k;
	}
	if (forest > 0.01 && grp_k > 0.0) {
		float gs;
		vec3 gn;
		vec3 gt;
		canopy(wp.xz + vec2(3.7, 1.3), grp_cell, con_p, gs, gn, gt);
		fcolor = mix(fcolor, fcolor * (0.55 + 0.75 * gs), grp_k * 0.8);
		crown_n = normalize(mix(crown_n, gn, grp_k * 0.5));
	}
	if (forest > 0.01 && crown_k > 0.0) {
		float cs;
		vec3 cn;
		vec3 ctint;
		canopy(wp.xz, canopy_cell_m, con_p, cs, cn, ctint);
		fcolor = mix(fcolor, ctint * cs, crown_k);
		crown_n = normalize(mix(crown_n, cn, crown_k));
	}
#else
	crown_k = 0.0;   // без крон: полог — средний тон (как вдали)
#endif
#ifndef T_SL_LIGHT_OFF
	vec3 sl_fc0 = fcolor; // SL
#endif
	// древостои: светлее/темнее пятнами 50–200 м (возраст, состав, густота)
	// + крупнее (массивы 300–800 м) — видны с 2 км, когда отдельные кроны и куртины уже мельче пикселя
	if (forest > 0.01) {
		float stands = fbm(wp.xz / 90.0 + vec2(8.1, 2.2), 3) - 0.5
				+ canopy_far_big * (fbm(wp.xz / 450.0 + vec2(2.6, 7.4), 2) - 0.5) * (1.0 - crown_k);
		float sv = mix(canopy_far_var, canopy_stand_var, crown_k);
		fcolor *= clamp(1.0 + sv * stands * 2.0, 0.25, 2.0);
		// опушка темнее (тень стены леса, густой подрост) — только внутри леса, луг у кромки не трогаем
		fcolor *= 1.0 - canopy_edge_dark * (1.0 - forest_in);
		// гуще в сырых ложбинах и на северных склонах, реже на сухих южных
		fcolor *= 1.0 - forest_wet_dark * clamp(0.6 * wet + 0.6 * north_s, -1.0, 1.0);
	}
#ifndef T_SL_LIGHT_OFF
	fcolor = sl_canopy_tone(fcolor, sl_fc0, fmean, con_p, dist, canopy_far_shade); // SL
#endif
#ifndef T_SL_TREELINE_OFF
	if (forest > 0.01) fcolor = sl_forest(fcolor, gcol, wp); // SL
#endif
#ifndef T_SL_SEASON_OFF
	if (forest > 0.01) fcolor = sl_canopy_season(fcolor, con_p, sl_ss, h); // SL
#endif
	if (use_forest_tex) {
		fcolor = apply_tex(fcolor, texture(forest_tex, wp.xz / forest_tex_tile_m).rgb, forest_tex_avg, tex_w);
	}
	col += fcolor * forest;
	// цвет суши без доли воды (вода смешивается ниже со своим блеском)
	float land = max(1.0 - wb.y, 1e-3);
	col /= land;

	// --- скалы: крутые склоны без леса (луг, кустарник, грунт на крутизне — выходы породы) ---
	float rnoise = fbm(wp.xz / 40.0 + vec2(5.1, 2.3), 3);   // тот же шум, что в gc_rock (кулуары снега ниже)
	float rock = gc_rock(wp.xz, slope_deg, foot_m) * (wa.y + crop + shrub + bare) / land;
	// цвет породы — только там, где есть скалы или выходы породы (текстуры — с производными,
	// посчитанными до ветвления)
	vec3 rcol = rock_color;
	vec3 rn_add = vec3(0.0);
#ifndef T_ROCK_TEX_OFF
	vec2 uv_xy = wp.xy / rock_tex_tile_m;
	vec2 uv_zy = wp.zy / rock_tex_tile_m;
	vec2 uv_xz = wp.xz / rock_tex_tile_m;
	vec4 dxy = vec4(dFdx(uv_xy), dFdy(uv_xy));
	vec4 dzy = vec4(dFdx(uv_zy), dFdy(uv_zy));
	vec4 dxz = vec4(dFdx(uv_xz), dFdy(uv_xz));
#endif
	if (rock > 0.001) {
#ifndef T_ROCK_DETAIL_OFF
		// порода: охра/бурые тона крупными пятнами, светлее/темнее по высоте
		float rtone = 0.5;
		if (kfar > 0.0) {
			rtone = fbm(wp.xz / rock_tone_scale_m + vec2(1.3, 8.8), 3);
			rcol = mix(rock_color, rock_color2, smoothstep(0.3, 0.7, rtone));
			rcol *= 0.75 + 0.5 * fbm(wp.xz / 12.0 + vec2(wp.y / 8.0), 3);
			// горизонтальная слоистость (видна издалека на обрывах)
			float sy = wp.y + 10.0 * (fbm(wp.xz / 250.0, 2) - 0.5) * 2.0;
			float strata = 0.5 + 0.5 * sin(6.2832 * sy / strata_m) * 0.7
					+ 0.3 * sin(6.2832 * sy / (strata_m * 3.7) + 1.3);
			rcol *= 1.0 - strata_strength * strata * (1.0 - smoothstep(0.7, 0.95, n_class.y));
			rcol = mix(rock_color, rcol, kfar);
		}
#endif
#ifndef T_ROCK_TEX_OFF
		if (use_rock_tex) {
			// скалы крутые — текстура по двум вертикальным проекциям (упрощённый triplanar)
			// (+ проекция сверху — для выходов породы на пологих гребнях)
			float bx = abs(n_class.x) / max(1e-3, abs(n_class.x) + abs(n_class.z));
			vec3 ta = textureGrad(rock_tex, uv_xy, dxy.xy, dxy.zw).rgb;
			vec3 tb = textureGrad(rock_tex, uv_zy, dzy.xy, dzy.zw).rgb;
			float by = smoothstep(0.75, 0.92, n_class.y);
			vec3 tsum = mix(ta, tb, bx);
			if (by > 0.0) {
				tsum = mix(tsum, textureGrad(rock_tex, uv_xz + 0.37, dxz.xy, dxz.zw).rgb, by);
			}
			rcol = apply_tex(rcol, tsum, rock_tex_avg, tex_w);
			if (use_rock_normal) {
				vec3 na = textureGrad(rock_normal_tex, uv_xy, dxy.xy, dxy.zw).rgb * 2.0 - 1.0;
				vec3 nb = textureGrad(rock_normal_tex, uv_zy, dzy.xy, dzy.zw).rgb * 2.0 - 1.0;
				// касательные возмущения в мировых осях проекций (xy → вдоль x и y, zy → вдоль z и y)
				rn_add = mix(vec3(na.x, na.y, 0.0), vec3(0.0, nb.y, nb.x), bx) * rock_normal_strength * fade;
			}
		}
#endif
#ifndef T_ROCK_DETAIL_OFF
		// лишайник пятнами на верхних гранях камней
		float lich = smoothstep(0.55, 0.75, fbm(wp.xz / 7.0 + vec2(wp.y / 5.0, 2.7), 3));
		rcol = mix(rcol, lichen_color * (0.8 + 0.4 * rtone), lich * lichen_amount * kfar * smoothstep(0.3, 0.8, n_class.y));
#endif
	}

	// осыпи: у подножия крутых участков — склон ниже обрыва (выше по склону круче скал)
	float slope_up = 0.0;
#ifndef T_SCREE_OFF
	if (slope_deg > scree_min_deg - 4.0 && forest < 0.99) {
		vec2 up_dir = length(n_class.xz) > 1e-3 ? -normalize(n_class.xz) : vec2(0.0);
		vec2 pu = wp.xz + up_dir * scree_probe_m;
		vec3 n_up = bilinear_normal(pu);
#ifndef T_FOREST_EDGE_OFF
		if (k10 > 0.0) {
			// ступенька крон выше по склону — не обрыв
			float e = layer_spacing * 0.5;
			vec2 g = k10 * canopy_dsm_height_m / (2.0 * e) * vec2(
					forest_mask_r(pu + vec2(e, 0.0)) - forest_mask_r(pu - vec2(e, 0.0)),
					forest_mask_r(pu + vec2(0.0, e)) - forest_mask_r(pu - vec2(0.0, e)));
			vec2 gu = n_up.xz / max(n_up.y, 0.05) + g;
			n_up = normalize(vec3(gu.x, 1.0, gu.y));
		}
#endif
		slope_up = degrees(acos(clamp(n_up.y, 0.0, 1.0)));
	}
	float scree = gc_scree(wp.xz, slope_deg, slope_up, foot_m) * (1.0 - rock) * (wa.y + shrub + bare) / land;
#else
	float scree = 0.0;   // без осыпей (и без конусов выноса SL: slope_up = 0)
#endif
#ifndef T_ROCK_TEX_OFF
	vec2 uv_sc = wp.xz / scree_tex_tile_m;
	vec4 dsc = vec4(dFdx(uv_sc), dFdy(uv_sc));
#endif
#ifndef T_SCREE_OFF
	if (scree > 0.001) {
		vec3 screecol = scree_color * (0.85 + 0.3 * fbm(wp.xz / 6.0, 3));
#ifndef T_ROCK_TEX_OFF
		if (use_scree_tex) {
			screecol = apply_tex(screecol, textureGrad(scree_tex, uv_sc, dsc.xy, dsc.zw).rgb,
					scree_color, tex_w);
		}
#endif
		col = mix(col, screecol, scree);
	}
#endif
	// выходы породы: коренная порода (rcol) или курумник — глыбы с тёмными щелями
	float ocw = outcrop * open_w / land * (1.0 - rock);
#ifndef T_OUTCROP_OFF
	if (ocw > 0.001) {
		float onz = vnoise(wp.xz / 9.0 + vec2(1.9, 4.4));
		vec3 kcol = kurum_color * (0.85 + 0.3 * onz);
		float kb = 1.0 - smoothstep(0.12 * kurum_block_m, 0.4 * kurum_block_m, foot_m);
		kb *= smoothstep(painted_rocks_fade_m.x, painted_rocks_fade_m.y, dist);
		if (kb > 0.0 && kurum > 0.01) {
			// одна глыба на клетку (без поиска соседей): центр чуть сдвинут, радиус 0.4–0.5 клетки
			vec2 bid = floor(wp.xz / kurum_block_m);
			vec2 bv = wp.xz - (bid + 0.5 + (canopy_hash2(bid) - 0.5) * 0.2) * kurum_block_m;
			float br = kurum_block_m * mix(0.4, 0.5, hash12(bid + 1.7));
			float bd = length(bv) / br;
			float inside = 1.0 - smoothstep(0.85, 1.0, bd);
			float top = sqrt(max(1.0 - bd * bd, 0.0));
			vec3 bn = normalize(vec3(bv.x / br, top + 0.001, bv.y / br));
			vec3 sd = normalize(sun_dir);
			float lit = 0.6 + 0.6 * clamp(dot(bn, sd), 0.0, 1.0);
			float blk = mix(0.45, lit * (0.75 + 0.5 * hash12(bid + 2.2)), inside);
			// среднее по пятну ≈ 1: без скачка яркости при растворении глыб вдали
			kcol *= mix(1.0, blk / 0.95, kb);
		}
#ifndef T_ROCK_TEX_OFF
		if (use_scree_tex) {
			kcol = apply_tex(kcol, textureGrad(scree_tex, uv_sc / 1.6, dsc.xy / 1.6, dsc.zw / 1.6).rgb,
					scree_color, tex_w * 0.7);
		}
#endif
		// коренная порода: плиты с тёмными трещинами и тенями уступов (видно с сотен метров)
		// (дешёвый цвет породы: тон пятнами + текстура вблизи; полный rcol — только у скал)
		float rt = vnoise(wp.xz / rock_tone_scale_m + vec2(1.3, 8.8));
		vec3 bed = mix(rock_color, rock_color2, smoothstep(0.3, 0.7, rt)) * (0.7 + 0.6 * onz);
		bed = mix(bed, lichen_color * (0.8 + 0.4 * rt),
				lichen_amount * 0.6 * smoothstep(0.55, 0.75, onz) * smoothstep(0.3, 0.8, n_class.y));
		float kc = 1.0 - smoothstep(0.3, 1.2, foot_m);
		if (kc > 0.0) {
#ifndef T_ROCK_TEX_OFF
			if (use_rock_tex) {
				bed = apply_tex(bed, textureGrad(rock_tex, uv_xz + 0.37, dxz.xy, dxz.zw).rgb,
						rock_tex_avg, tex_w * kc);
			}
#endif
			float crack = 1.0 - smoothstep(0.0, 0.06 + 0.05 * foot_m,
					abs(vnoise(wp.xz / 7.0 + 2.2) - 0.5));
			bed *= 1.0 - 0.45 * crack * kc;
		}
		vec3 ocol = mix(bed, kcol, kurum);
		col = mix(col, ocol, ocw);
	}
#endif
	col = mix(col, rcol, rock);
#ifndef T_SL_ROCK_OFF
	vec3 sl_rg; // SL
	col = sl_rock_look(col, wp, n_class, dist, max(rock, ocw), scree, clamp(open_w, 0.0, 1.0), slope_deg, slope_up, clamp(v_convex / outcrop_convex_k, -1.0, 1.0), scree_color, rock_tex_tile_m, rock_macro_k, scree_tex_tile_m, sl_rg); // SL
#endif

	// --- скальная поверхность (скалы и выходы породы): крупный слой текстуры породы по трём
	// проекциям — рисунок (яркость) и нормаль, видны до rock_macro_fade_m, когда мелкий тайл уже
	// усреднён мипами; уступы слоёв strata_m в нормали (ступень круче, полка положе) ---
	float rsw = max(rock, ocw);
	vec3 rs_n = vec3(0.0);
#ifndef T_ROCK_SURFACE_OFF
	float mk = (1.0 - smoothstep(rock_macro_fade_m.x, rock_macro_fade_m.y, dist)) * kfar;
	if (rsw > 0.001 && mk > 0.0) {
		// средняя дистанция: тон пятнами 30–150 м, тёмные трещины-кулуары и светлые полосы осыпей
		// вдоль линии падения, кривизна (гребни светлее, ложбины темнее) — читается без камней
		float tv = vnoise(wp.xz / 35.0 + vec2(7.3, 2.1)) * 0.6 + vnoise(wp.xz / 140.0 + vec2(1.1, 4.7)) * 0.4;
		float fr = 1.0 + rock_tone_var * 2.0 * (tv - 0.5);
		float big = fbm(wp.xz / 900.0 + vec2(4.1, 6.6), 2);
		float alp = smoothstep(gully_snow_line_m - rock_alpine_below_m.x, gully_snow_line_m - rock_alpine_below_m.y,
				h + 250.0 * (big - 0.5)) * rock_alpine_mix;
		if (alp > 0.0) {
			vec3 ac = mix(rock_alpine_color, rock_alpine_rust, smoothstep(0.55, 0.72, big))
					* (1.0 - 0.25 * smoothstep(35.0, 55.0, slope_deg));
			col = mix(col, ac * (0.85 + 0.3 * tv), alp * rsw * mk);
		}
		float cr_w = 1.0 - smoothstep(0.15 * rock_crack_m, 0.5 * rock_crack_m, foot_m);
		if (cr_w > 0.0) {
			vec2 fl = rock_fall_pattern(wp.xz, -n_class.xz / max(n_class.y, 0.05), foot_m);
			fr *= 1.0 - rock_crack_dark * fl.x * cr_w;
			float streak = fl.y * rock_scree_streaks * mix(0.5, 1.0, cr_w);
			col = mix(col, scree_color * (0.85 + 0.3 * tv), streak * rsw * mk);
		}
		fr *= 1.0 + rock_curv_shade * clamp(v_convex / outcrop_convex_k, -1.0, 1.0);
		col *= mix(1.0, fr, rsw * mk);
#ifndef T_ROCK_TEX_OFF
		if (use_rock_tex) {
			vec3 bw3 = n_class * n_class;
			bw3 *= bw3;
			bw3 /= max(bw3.x + bw3.y + bw3.z, 1e-4);
			float km = 1.0 / rock_macro_k;
			vec2 mzy = uv_zy * km + vec2(0.71, 0.43);
			vec2 mxy = uv_xy * km + vec2(0.31, 0.17);
			vec2 mxz = uv_xz * km + vec2(0.59, 0.23);
			const vec3 LM = vec3(0.2126, 0.7152, 0.0722);
			float lum = 0.0;
			vec3 mn = vec3(0.0);
			if (bw3.x > 0.02) {
				lum += dot(textureGrad(rock_tex, mzy, dzy.xy * km, dzy.zw * km).rgb, LM) * bw3.x;
			}
			if (bw3.z > 0.02) {
				lum += dot(textureGrad(rock_tex, mxy, dxy.xy * km, dxy.zw * km).rgb, LM) * bw3.z;
			}
			if (bw3.y > 0.02) {
				lum += dot(textureGrad(rock_tex, mxz, dxz.xy * km, dxz.zw * km).rgb, LM) * bw3.y;
			}
			float wsum3 = (bw3.x > 0.02 ? bw3.x : 0.0) + (bw3.z > 0.02 ? bw3.z : 0.0)
					+ (bw3.y > 0.02 ? bw3.y : 0.0);
			float avg_l = max(dot(rock_tex_avg, LM), 1e-3);
			float r = clamp(pow(lum / max(wsum3, 1e-3) / avg_l, rock_macro_contrast), 0.45, 1.8);
			col *= mix(1.0, r, rock_macro_strength * rsw * mk);
			if (use_rock_normal && rock_macro_normal > 0.0) {
				if (bw3.x > 0.02) {
					vec3 t = textureGrad(rock_normal_tex, mzy, dzy.xy * km, dzy.zw * km).rgb * 2.0 - 1.0;
					mn += vec3(0.0, t.y, t.x) * bw3.x;
				}
				if (bw3.z > 0.02) {
					vec3 t = textureGrad(rock_normal_tex, mxy, dxy.xy * km, dxy.zw * km).rgb * 2.0 - 1.0;
					mn += vec3(t.x, t.y, 0.0) * bw3.z;
				}
				if (bw3.y > 0.02) {
					vec3 t = textureGrad(rock_normal_tex, mxz, dxz.xy * km, dxz.zw * km).rgb * 2.0 - 1.0;
					mn += vec3(t.x, 0.0, t.y) * bw3.y;
				}
				rs_n += mn * rock_macro_normal * mk;
			}
		}
#endif
		// уступы: уклон ±ledge_strength по фазе слоёв (шаг strata_m и ×3,7); слой мельче
		// ~пикселя гаснет (муар)
		float kl = ledge_strength * smoothstep(ledge_slope_deg.x, ledge_slope_deg.y, slope_deg);
		if (kl > 0.0) {
			float sy = wp.y + 10.0 * (fbm(wp.xz / 250.0, 2) - 0.5) * 2.0;
			float a1 = 1.0 - smoothstep(0.25 * strata_m, 0.6 * strata_m, foot_px);
			float a2 = 1.0 - smoothstep(0.9 * strata_m, 2.2 * strata_m, foot_px);
			float w = sin(6.2832 * sy / strata_m) * 0.3 * a1
					+ 0.6 * sin(6.2832 * sy / (strata_m * 3.7) + 1.3) * a2;
			// уступы рвутся пятнами (иначе — сплошные «горизонтали»)
			w *= smoothstep(0.45, 0.65, vnoise(wp.xz / 70.0 + vec2(8.3, 1.6)));
			rs_n += vec3(-hg.x, 0.0, -hg.y) * kl * w;
		}
	}
#endif

	// снег в кулуарах и ложбинах высоких гор (по высоте, вогнутости, экспозиции), а не шапкой
#ifndef T_GULLY_SNOW_OFF
	float gd = max(gully_scale_m, 2.0 * layer_spacing);
	float lap = -1.0;
	if (h > gully_snow_line_m - gully_north_m - 200.0 && forest < 0.99) {
		lap = (h_bilinear(wp.xz + vec2(gd, 0.0)) + h_bilinear(wp.xz - vec2(gd, 0.0))
			+ h_bilinear(wp.xz + vec2(0.0, gd)) + h_bilinear(wp.xz - vec2(0.0, gd))
			- 4.0 * h_bilinear(wp.xz)) / (4.0 * gd);
	}
	float gully = smoothstep(0.0, gully_k, lap + 0.02 * (rnoise - 0.5));
	float gsnow = ragged_edge(gully * smoothstep(gully_snow_line_m - 100.0, gully_snow_line_m + 150.0,
			h + gully_north_m * max(north, 0.0) + 120.0 * (patch2 - 0.5))
			* (1.0 - smoothstep(48.0, 58.0, slope_deg)), wp.xz + 17.0, foot_m) * (1.0 - forest);
	col = mix(col, snow_color * (0.9 + 0.1 * fbm(wp.xz / 9.0, 2)), gsnow);
#else
	float gsnow = 0.0;   // без снега в кулуарах
#endif
#ifndef T_SL_SNOW_OFF
	col = sl_fresh_snow(col, snow_color, wp.xz, h, slope_deg, forest); // SL
#endif

	// --- мелкая детализация (кочки, пятна) ---
#ifndef T_DETAIL_OFF
	float d1 = fbm(wp.xz / detail_scale_m, 3);
	float d2 = vnoise(wp.xz / (detail_scale_m * 8.0));
	// самый мелкий масштаб (пучки травы, камни) — только совсем рядом
	float near_fade = 1.0 - smoothstep(detail_fade_m * 0.02, detail_fade_m * 0.1, dist);
	float d0 = vnoise(wp.xz / (detail_scale_m * 0.25)) * 0.6 + vnoise(wp.xz / (detail_scale_m * 0.05)) * 0.4;
	float grassy = (wa.y + crop + shrub) * (1.0 - rock) * (1.0 - outcrop);
	// оттенок травы гуляет пятнами 10–30 м
	// (на лугу пятна 20–200 м рисует meadow_detail — здесь слабее, без «камуфляжа»)
	float d2k = 1.0 - 0.6 * wa.y;
	col = mix(col, col * vec3(1.08, 1.0, 0.8), grassy * fade * d2k * smoothstep(0.4, 0.7, d2));
	col *= 1.0 + detail_strength * fade * ((d1 - 0.5) * 1.2 + (d2 - 0.5) * 0.8 * d2k)
			+ detail_strength * near_fade * (d0 - 0.5) * 1.2;
#endif

	// --- вода (реки, ручьи, озёра): класс «вода» WorldCover (карта 25 м) или маска 10 м (T03,
	// OSM — точнее по форме и не мигает с шагом карты классов); максимум из двух ---
	float water_g = use_forest_mask ? forest_mask_g_aa(wp.xz, foot_m) : 0.0;
	float water = max(wb.y, water_g);

	// промоины на открытых склонах (не на воде, снегу, под пологом леса, в застройке): только
	// нормаль; направление и сила — по уклону в масштабе крупных промоин (от камеры не зависит)
#ifndef T_EROSION_OFF
	if (erosion_enabled && erosion_strength > 0.0 && dist < erosion_fade_m.y) {
		float ek = (1.0 - forest) * (1.0 - snow) * (1.0 - gsnow) * (1.0 - water) * (1.0 - built)
				* (1.0 - smoothstep(erosion_fade_m.x, erosion_fade_m.y, dist));
		if (ek > 0.01 && foot_px < 0.35 * erosion_scale_m) {
			float lod_e = clamp(log2(0.5 * erosion_scale_m / layer_spacing), 0.0, height_mip_max_lod);
			vec2 ge = height_grad(wp.xz, lod_e);
			float sdeg = degrees(atan(length(ge)));
			ek *= smoothstep(erosion_slope_deg.x, erosion_slope_deg.y, sdeg);
			if (ek > 0.01) {
				vec2 dg = erosion_grad(wp.xz, ge, foot_px, ek * (1.0 + erosion_rock_boost * rsw));
				vec2 gn = -n.xz / max(n.y, 0.05) + dg;
				n = normalize(vec3(-gn.x, 1.0, -gn.y));
			}
		}
	}
#endif

	n = normalize(n + vec3(grass_bend.x, 0.0, grass_bend.y) + gn_add + rn_add * max(rock, outcrop * (1.0 - kurum))
			+ rs_n * rsw);
#ifndef T_SL_ROCK_OFF
	n = sl_rock_nrm(n, sl_rg, clamp(max(rsw, scree * (1.0 - rock)), 0.0, 1.0)); // SL
#endif
	// нормали крон (освещение полога)
	n = normalize(mix(n, normalize(n + vec3(crown_n.x, 0.0, crown_n.z) * 1.5), forest * crown_k * 0.6));
	// возмущение нормали шумом (кроны/кочки), чтобы вблизи поверхность не была «пластиковой»
#ifndef T_DETAIL_OFF
	if (fade > 0.0) {
		float e = detail_scale_m * 0.5;
		vec2 q = wp.xz / (detail_scale_m * 1.6);
		float c0 = fbm(q, 3);
		float cx = fbm(q + vec2(e / (detail_scale_m * 1.6), 0.0), 3);
		float cz = fbm(q + vec2(0.0, e / (detail_scale_m * 1.6)), 3);
		float amp = fade * mix(0.25, canopy_bump, forest);
		vec3 bump = vec3(-(cx - c0), 0.0, -(cz - c0)) * amp;
		n = normalize(n + bump);
	}
#endif

	// берег: тонкая полоса мокрого грунта/гальки у кромки воды маски 10 м (не на самой воде)
	float bank = use_forest_mask
			? smoothstep(0.02, 0.22, water_g) * (1.0 - smoothstep(0.22, 0.4, water_g))
			: 0.0;
#ifndef T_SL_RIPARIAN_OFF
	if (sl_riparian_enabled && use_forest_mask && dist < sl_riparian_fade_m.y && wa.y + shrub > 0.01) { // SL
		float sl_rw = sl_riparian_w(sl_riparian_ring(wp.xz), water, dist) * (wa.y + shrub) * (1.0 - snow) * (1.0 - rock) * (1.0 - bare); // SL
		col = sl_riparian_color(col, grass_color, sl_rw); // SL
	} // SL
#endif
	vec3 bank_color = mix(bare_color, rock_color, 0.3) * 0.55;
	col = mix(col, bank_color, bank * (1.0 - water));
	float water_rough = water_roughness;
	if (water > 0.001) {
		float ripple;
		vec3 nw;
#ifndef T_WATER_WIND_OFF
		water_wind(wp.xz, dist, foot_m, water_rough, nw, ripple);
#else
		// без ряби и порывов: шероховатость по среднему ветру (как вдали у полного — стык LOD без
		// скачка «зеркало ↔ матовая»), нормаль — гладь
		ripple = 0.0;
		nw = vec3(0.0, 1.0, 0.0);
		water_rough = mix(water_roughness, water_rough_wind,
				smoothstep(water_wind_calm_ms, water_wind_full_ms, length(wind_vec)));
#endif
		col = mix(col, water_color * (1.0 + 0.1 * ripple * fade), water);
		n = normalize(mix(n, nw, water));
	}

	// AO ложбин (цвет и рассеянный свет) и тень рельефа при низком солнце: вдали, где нет теней
	// Godot; тень гасит только долю прямого света (ndl), рассеянный остаётся
	if (use_relief) {
		col *= mix(1.0, rel.g, relief_ao_albedo);
		AO = mix(1.0, rel.g, relief_ao_ambient);
		AO_LIGHT_AFFECT = 0.0;
		vec3 sd = normalize(sun_dir);
		float sun_el = degrees(asin(clamp(sd.y, -1.0, 1.0)));
		float vis = smoothstep(hz_deg - relief_shadow_soft_deg, hz_deg + relief_shadow_soft_deg, sun_el);
		float ndl = max(dot(n, sd), 0.0);
		float sh = (relief_shadow_ambient + vis * ndl) / (relief_shadow_ambient + ndl);
		float kfar = smoothstep(relief_shadow_near_m.x, relief_shadow_near_m.y, dist);
		col *= mix(1.0, sh, relief_shadow_strength * kfar);
	}
	ALBEDO = clamp(col, 0.0, 1.0);
	ROUGHNESS = mix(roughness_value, water_rough, water);
	SPECULAR = mix(specular_value * (1.0 - forest * 0.7), water_specular, water);
	NORMAL = normalize((VIEW_MATRIX * vec4(n, 0.0)).xyz);
	v_cs_spec = SPECULAR;
	AO *= cloud_sky_ao(v_cs_sun);
#ifndef T_SL_LIGHT_OFF
	v_sl_ny = n.y; v_sl_ao = AO; v_sl_sun = v_cs_sun; // SL
	vec2 sl_rs = sl_relief_shadow(use_relief, n, hz_deg, dist, relief_shadow_ambient, relief_shadow_soft_deg, relief_shadow_strength, relief_shadow_near_m); // SL
	ALBEDO = min(ALBEDO / sl_rs.x, vec3(1.0)); // SL
	// SL-27: тень горизонта — отдельно, в light() min с тенью Godot
	v_sl_relief = sl_rs.y; // SL
	v_cs_sun *= sl_canopy_direct(n_class, normalize(CAMERA_POSITION_WORLD - wp), forest * sl_canopy_far(dist)); // SL
#endif
}

// Встроенное освещение (burley + schlick_ggx), прямое солнце — в тени облаков слабее.
void light() {
	float atten = ATTENUATION;
#ifndef T_SL_LIGHT_OFF
	// тень горизонта рельефа и тень Godot — одна тень солнца: берём более тёмную (SL-27)
	atten = LIGHT_IS_DIRECTIONAL ? min(atten, v_sl_relief) : atten; // SL
#endif
	cloud_light(NORMAL, VIEW, LIGHT, LIGHT_COLOR, atten, LIGHT_IS_DIRECTIONAL, v_cs_sun,
			ALBEDO, ROUGHNESS, METALLIC, v_cs_spec, vec3(0.0), CS_BURLEY, SPECULAR_AMOUNT,
			DIFFUSE_LIGHT, SPECULAR_LIGHT);
#ifndef T_SL_LIGHT_OFF
	sl_ground_light(DIFFUSE_LIGHT, LIGHT_COLOR, LIGHT_IS_DIRECTIONAL, ALBEDO, v_sl_ny, v_sl_ao, v_sl_sun); // SL
#endif
}
