// Облака для рендера Compatibility: одна MultiMesh, по боксу на облако (экземпляры отсортированы
// от дальних к ближним), параметры облаков — в float-текстуре (строка = экземпляр, 5 текселей —
// запись облака, см. cloud_common.gdshaderinc). Без instance uniform — нет лимита на число облаков.
// Форма, свет и проход луча — общие с compute-путём (cloud_common.gdshaderinc).
shader_type spatial;
render_mode unshaded, cull_front, depth_test_disabled, depth_draw_never, blend_premul_alpha, fog_disabled, shadows_disabled;

uniform sampler3D noise_shape : filter_linear_mipmap, repeat_enable;
uniform sampler3D noise_detail : filter_linear_mipmap, repeat_enable;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;
uniform sampler2D cloud_data : filter_nearest;

// Солнце и свет.
uniform vec3 sun_dir = vec3(0.3, 0.77, 0.56);
uniform vec3 sun_color = vec3(1.0, 0.97, 0.92);
uniform float sun_energy = 1.3;
uniform vec3 ambient_top = vec3(0.55, 0.66, 0.85);
uniform vec3 ambient_bottom = vec3(0.32, 0.33, 0.33);
uniform float ambient_energy = 0.9;
uniform float base_darkness = 0.45;
uniform float base_relief_m = 18.0;
uniform float sky_occlusion_m = 350.0;
uniform float surface_sharpness = 0.15;
uniform float light_step_growth = 2.0;

// Движение шума: перенос ветром (м) и «кипение».
uniform vec3 wind_offset = vec3(0.0);
uniform float boil = 0.0;

// Масштабы шума.
uniform float shape_period_m = 1400.0;
uniform float detail_period_m = 260.0;
uniform float top_period_m = 3000.0;
uniform float hf_period_m = 90.0;
uniform float curl_strength_m = 25.0;
uniform float shape_tex_size = 96.0;
uniform float detail_tex_size = 64.0;

// Оптика.
uniform float extinction = 0.06;
uniform float light_absorb = 0.7;
uniform float powder_strength = 0.6;
uniform float phase_forward = 0.6;
uniform float phase_back = -0.2;
uniform float phase_mix = 0.25;
uniform float silver = 1.4;
uniform float ms_strength = 0.35;

// Cb.
uniform float anvil_spread = 2.2;
uniform float anvil_shift = 0.6;
uniform float virga_depth_m = 1300.0;
uniform float virga_density = 0.35;

// Качество.
uniform int coarse_steps = 48;
uniform int max_iterations = 160;
uniform float fine_step_per_m = 0.006;
uniform float fine_step_min_m = 4.0;
uniform int light_steps = 4;
uniform int detail_enabled = 1;
uniform float light_step_m = 40.0;
uniform float lod_distance_m = 12000.0;

// Дымка.
uniform vec3 fog_color = vec3(0.66, 0.74, 0.86);
uniform float fog_density = 0.00004;
uniform float fog_sun_scatter = 0.15;

varying flat int v_idx;

#include "res://scripts/atmosphere/cloud_common.gdshaderinc"

void vertex() {
	v_idx = INSTANCE_ID;
}

void fragment() {
	vec3 ro = CAMERA_POSITION_WORLD;
	vec3 wp = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 rd = normalize(wp - ro);
	vec4 r0 = texelFetch(cloud_data, ivec2(0, v_idx), 0);
	vec4 r1 = texelFetch(cloud_data, ivec2(1, v_idx), 0);
	float tn;
	float tf;
	if (!cloud_box_hit(r0, r1, ro, rd, tn, tf)) {
		discard;
	}
	Cloud cl = cloud_make(vec3(r0.x, 0.0, r0.z), vec3(r1.x, 0.0, r1.y),
			texelFetch(cloud_data, ivec2(2, v_idx), 0), texelFetch(cloud_data, ivec2(3, v_idx), 0),
			texelFetch(cloud_data, ivec2(4, v_idx), 0), texelFetch(cloud_data, ivec2(5, v_idx), 0).x,
			ro, length(fwidth(rd)));

	// Глубина сцены: рельеф перед облаком или внутри бокса обрезает луч.
	float depth = texture(depth_tex, SCREEN_UV).r;
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
	vec3 ndc = vec3(SCREEN_UV, depth) * 2.0 - 1.0;
#else
	vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, depth);
#endif
	vec4 vpos = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
	vpos.xyz /= vpos.w;
	tf = min(tf, length(vpos.xyz));
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
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
	// Compatibility не переводит вывод этого материала (unshaded + premul alpha) из линейного
	// пространства в sRGB — облака выходили темнее и контрастнее, чем в Forward+ (замер:
	// GL(x^0,45) ≈ FP(x)). Переводим сами, на непремультиплицированном цвете.
	vec3 lin = col / max(alpha, 1e-4);
	vec3 srgb = mix(lin * 12.92, 1.055 * pow(max(lin, vec3(0.0)), vec3(1.0 / 2.4)) - 0.055,
			step(vec3(0.0031308), lin));
	col = srgb * alpha;
#endif
	ALBEDO = col;
	ALPHA = alpha;
}
