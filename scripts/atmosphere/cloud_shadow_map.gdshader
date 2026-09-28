// Карта теней облаков (CloudShadowMap): вид сверху на опорную плоскость вокруг пилота, в пикселе —
// доля прямого солнца, прошедшая сквозь облака (пропускание T = exp(−∫плотность·ослабление)) по
// лучу к солнцу. Плотность — та же, что рисуется (cloud_common.gdshaderinc, качество 1): тень
// повторяет форму облака, его клубы, распад и таяние. Один квад на облако (MultiMesh), квад
// накрывает проекцию бокса облака вдоль солнца; облака перемножаются (blend_mul по белому фону).
// Землю этой картой затеняют шейдеры рельефа, травы, леса (scripts/terrain/cloud_shadow.gdshaderinc).
shader_type canvas_item;
render_mode blend_mul, unshaded;

uniform sampler2D cloud_data : filter_nearest;
// Карта: мировые x, z левого верхнего угла, метров на пиксель, высота опорной плоскости, м.
uniform vec4 map_rect = vec4(0.0, 0.0, 50.0, 0.0);
uniform int shadow_steps = 8;
uniform sampler3D noise_shape : filter_linear_mipmap, repeat_enable;
uniform sampler3D noise_detail : filter_linear_mipmap, repeat_enable;

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
uniform float virga_density = 0.022;
uniform float virga_period_m = 1500.0;

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
varying vec2 v_w;

#include "res://scripts/atmosphere/cloud_common.gdshaderinc"

void vertex() {
	v_idx = INSTANCE_ID;
	vec4 r0 = texelFetch(cloud_data, ivec2(0, INSTANCE_ID), 0);
	vec4 r1 = texelFetch(cloud_data, ivec2(1, INSTANCE_ID), 0);
	// Бокс облака (низ и верх) — вдоль солнца на опорную плоскость.
	vec2 s = sun_dir.xz / max(sun_dir.y, 0.05);
	vec2 c_lo = r0.xz - s * (r0.y - r0.w - map_rect.w);
	vec2 c_hi = r0.xz - s * (r0.y + r0.w - map_rect.w);
	float rad = length(r1.zw);
	vec2 lo = min(c_lo, c_hi) - rad;
	vec2 hi = max(c_lo, c_hi) + rad;
	// Квад — QuadMesh 1×1 с центром в нуле.
	v_w = mix(lo, hi, VERTEX + 0.5);
	VERTEX = (v_w - map_rect.xy) / map_rect.z;
}

void fragment() {
	vec4 r0 = texelFetch(cloud_data, ivec2(0, v_idx), 0);
	vec4 r1 = texelFetch(cloud_data, ivec2(1, v_idx), 0);
	Cloud cl = cloud_make(vec3(r0.x, 0.0, r0.z), vec3(r1.x, 0.0, r1.y),
			texelFetch(cloud_data, ivec2(2, v_idx), 0), texelFetch(cloud_data, ivec2(3, v_idx), 0),
			texelFetch(cloud_data, ivec2(4, v_idx), 0), texelFetch(cloud_data, ivec2(5, v_idx), 0).x,
			vec3(0.0), 0.0);
	float sy = max(sun_dir.y, 0.05);
	vec2 s = sun_dir.xz / sy;
	float y0 = r0.y - r0.w;
	float dy = 2.0 * r0.w / float(shadow_steps);
	// Шаг по лучу; детали мельче шага не берём (мип шума по шагу) — тень без «искр».
	cl.foot = dy / sy;
	float tau = 0.0;
	for (int i = 0; i < 32; i++) {
		if (i >= shadow_steps) {
			break;
		}
		float y = y0 + (float(i) + 0.5) * dy;
		vec3 q = vec3(v_w.x + s.x * (y - map_rect.w), y, v_w.y + s.y * (y - map_rect.w));
		tau += cloud_density(cl, q, 1);
	}
	COLOR = vec4(vec3(exp(-tau * extinction * cl.foot)), 1.0);
}
