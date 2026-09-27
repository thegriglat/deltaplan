// Объёмное кучевое облако: raymarch внутри своего бокса (MeshInstance3D с BoxMesh).
// Форма: купол с плоской нижней кромкой + эрозия 3D-шумом (клубы Уорли).
// Свет: Бир (поглощение по пути к солнцу), powder-эффект, двулепестковая фаза
// Хеньи — Гринстейна (серебристая кайма против солнца), рассеянный свет неба/земли.
// Стадия жизни — через параметры экземпляра: растущее облако плотное с чёткими клубами,
// распадающееся — рваное, прозрачное, с приподнятой рваной кромкой.
// Работает в Forward+ и Compatibility (глубина сцены — с учётом разных диапазонов NDC).
shader_type spatial;
render_mode unshaded, cull_front, depth_test_disabled, depth_draw_never, blend_premul_alpha, fog_disabled, shadows_disabled;

uniform sampler3D noise_shape : filter_linear_mipmap, repeat_enable;
uniform sampler3D noise_detail : filter_linear_mipmap, repeat_enable;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;

// Солнце (к солнцу) и свет.
uniform vec3 sun_dir = vec3(0.3, 0.77, 0.56);
uniform vec3 sun_color = vec3(1.0, 0.97, 0.92);
uniform float sun_energy = 1.3;
uniform vec3 ambient_top = vec3(0.55, 0.66, 0.85);
uniform vec3 ambient_bottom = vec3(0.32, 0.33, 0.33);
uniform float ambient_energy = 0.9;
uniform float base_darkness = 0.45;   // рассеянный свет у основания (доля)
uniform float base_relief_m = 18.0;   // неровность основания, м
uniform float sky_occlusion_m = 350.0;
uniform float surface_sharpness = 0.15;
uniform float light_step_growth = 2.0; // меньше — резче поверхность живого облака // толщина облака, ослабляющая свет неба в e раз, м

// Движение шума: перенос ветром (м) и «кипение».
uniform vec3 wind_offset = vec3(0.0);
uniform float boil = 0.0;

// Масштабы шума (период текстуры, м).
uniform float shape_period_m = 1400.0;
uniform float detail_period_m = 260.0;
uniform float top_period_m = 3000.0;
uniform float hf_period_m = 90.0;
uniform float curl_strength_m = 25.0;
uniform float shape_tex_size = 96.0;
uniform float detail_tex_size = 64.0;

// Оптика.
uniform float extinction = 0.06;       // 1/м при плотности 1
uniform float light_absorb = 0.7;      // поглощение по пути к солнцу (доля extinction)
uniform float powder_strength = 0.6;
uniform float phase_forward = 0.6;
uniform float phase_back = -0.2;
uniform float phase_mix = 0.25;
uniform float silver = 1.4;            // усиление серебристой каймы
uniform float ms_strength = 0.35;      // вклад многократного рассеяния

// Качество.
uniform int coarse_steps = 48;          // шагов по пустоте через весь бокс
uniform int max_iterations = 160;      // предел выборок на пиксель
uniform float fine_step_per_m = 0.006; // мелкий шаг = расстояние × множитель
uniform float fine_step_min_m = 4.0;
uniform int light_steps = 4;
uniform int detail_enabled = 1;        // мелкая эрозия краёв (0/1)
uniform float light_step_m = 40.0;
uniform float lod_distance_m = 12000.0;

// Дымка (из WorldEnvironment, экспоненциальная).
uniform vec3 fog_color = vec3(0.66, 0.74, 0.86);
uniform float fog_density = 0.00004;
uniform float fog_sun_scatter = 0.15;

// Параметры облака (на экземпляр).
instance uniform vec4 cloud_shape;  // x: нижняя кромка (м, мир), y: мощность (м), z: полудлина вдоль ветра (м), w: полуширина (м)
instance uniform vec4 cloud_state;  // x: рост 0..1, y: распад 0..1, z: активность термика (подсос) 0..1, w: зерно
instance uniform vec4 cloud_extra;  // x: переразвитие/растекание верха 0..1

#include "res://scripts/atmosphere/cloud_common.gdshaderinc"

void fragment() {
	vec3 ro = CAMERA_POSITION_WORLD;
	vec3 wp = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 rd = normalize(wp - ro);

	vec3 mx = MODEL_MATRIX[0].xyz;
	vec3 my = MODEL_MATRIX[1].xyz;
	vec3 mz = MODEL_MATRIX[2].xyz;
	vec3 bc = MODEL_MATRIX[3].xyz;
	Cloud cl = cloud_make(bc, normalize(mx), cloud_shape, cloud_state, cloud_extra, ro, length(fwidth(rd)));

	// Пересечение луча с боксом (в осях бокса).
	vec3 dl = ro - bc;
	vec3 lo = vec3(dot(dl, mx) / dot(mx, mx), dot(dl, my) / dot(my, my), dot(dl, mz) / dot(mz, mz));
	vec3 ld = vec3(dot(rd, mx) / dot(mx, mx), dot(rd, my) / dot(my, my), dot(rd, mz) / dot(mz, mz));
	vec3 inv = 1.0 / ld;
	vec3 t0 = (vec3(-0.5) - lo) * inv;
	vec3 t1 = (vec3(0.5) - lo) * inv;
	vec3 tmin = min(t0, t1);
	vec3 tmax = max(t0, t1);
	float tn = max(max(max(tmin.x, tmin.y), tmin.z), 0.0);
	float tf = min(min(tmax.x, tmax.y), tmax.z);

	// Глубина сцены: рельеф перед облаком или внутри бокса обрезает луч.
	float depth = texture(depth_tex, SCREEN_UV).r;
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
	vec3 ndc = vec3(SCREEN_UV, depth) * 2.0 - 1.0;
#else
	vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, depth);
#endif
	vec4 vpos = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
	vpos.xyz /= vpos.w;
	float scene_t = length(vpos.xyz);
	tf = min(tf, scene_t);
	if (tf <= tn) {
		discard;
	}

	float ign = fract(52.9829189 * fract(dot(FRAGCOORD.xy, vec2(0.06711056, 0.00583715))));
	float trans = 1.0;
	vec3 col = vec3(0.0);
	float t_acc = 0.0;
	float w_acc = 0.0;
	cloud_march(cl, ro, rd, tn, tf, ign, trans, col, t_acc, w_acc);
	float alpha = 1.0 - trans;
	if (alpha < 0.002) {
		discard;
	}
	// Дымка по средней глубине облака.
	float dist = w_acc > 0.0 ? t_acc / w_acc : tn;
	float fog = 1.0 - exp(-dist * fog_density);
	float cos_t = dot(rd, sun_dir);
	vec3 fc = fog_color * (1.0 + fog_sun_scatter * pow(max(cos_t, 0.0), 8.0));
	col = col * (1.0 - fog) + fc * alpha * fog;
	ALBEDO = col;
	ALPHA = alpha;
}
