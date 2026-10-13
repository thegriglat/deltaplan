// Дороги OSM (L7, OL-5): лента по рельефу с видом асфальта, разметкой и колеёй грунтовок.
// Геометрия и сдвиг к камере — как draped.gdshader. Данные ленты (RoadMesher):
//   UV.x — поперёк (0 левый край … 1 правый), UV.y — вдоль, метры от начала полилинии,
//   UV2.x — код вида: 0 асфальт, 1 пунктир по оси + края, 2 сплошная ось + края, 3 пунктир, 4 грунтовка;
//   UV2.y — ширина ленты, м. Цвет вершин — базовый цвет класса (линейный).
// SL-4: вдали лента расширяется до min_px пикселей (NORMAL меша — направление наружу поперёк ленты), а вклад
// в пиксель = доля покрытия (ширина / ширина на экране; дизеринг по IGN — без мерцания); цвет вдали — серо-бежевый
// грунт с потолком яркости относительно луга; свет — как у рельефа (specular, тень облаков).
// Без текстур: шум и пятна — от локальных координат меша (≤ ±1,5 км, без float-ряби от больших мировых
// координат) и от UV.y; пунктир — mod/fract малых чисел; детали гаснут с расстоянием (fwidth), чтобы не мерцали.
shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

#include "res://scripts/terrain/cloud_shadow.gdshaderinc"

uniform float depth_bias_m = 0.3;
uniform float depth_pull = 0.004;
uniform float roughness : hint_range(0.0, 1.0) = 0.95;
uniform float specular_value : hint_range(0.0, 1.0) = 0.2;  // как у рельефа (world.json terrain_look.specular)
uniform float min_px = 1.5;  // минимальная ширина ленты на экране, пикселей
uniform float edge_darken = 0.0;
// Край асфальта: растушёвка (дизеринг-альфа с шумом по миру), светлая пыльная обочина вместо тёмной кромки.
uniform float edge_feather_m = 1.2;
uniform float shoulder_w_m = 0.9;
uniform vec3 shoulder_color : source_color = vec3(0.45, 0.40, 0.33);
uniform float shoulder_amt = 0.45;
// Вдали лента теряет контраст и насыщенность и подтягивается к цвету обочины (средний план без резкой полосы).
uniform float far_fade_start_m = 1000.0;
uniform float far_fade_end_m = 4000.0;
uniform float far_desat = 0.5;
uniform float far_tint = 0.3;
// Цвет вдали: грунт рельефа (серо-бежевый, sRGB) и потолок яркости: не светлее луга (линейная яркость) в far_luma_max раз.
uniform vec3 far_ground_color : source_color = vec3(0.36, 0.33, 0.27);
uniform float far_ground_amt = 0.75;
uniform float meadow_luma = 0.25;
uniform float far_luma_max = 1.3;
// Асфальт: размах шума (доля яркости), пятна ремонта, мелкая «крупа».
uniform float noise_amp = 0.12;
uniform float patch_amp = 0.10;
uniform float speck_amp = 0.06;
uniform float detail_fade_start_m = 250.0;
uniform float detail_fade_end_m = 1400.0;
// Разметка: цвета, ширины линий, пунктир (период и длина штриха), отступ краевой линии от края.
uniform vec3 mark_color : source_color = vec3(0.86, 0.86, 0.82);
uniform float center_w_m = 0.16;
uniform float edge_w_m = 0.12;
uniform float edge_inset_m = 0.35;
uniform float dash_period_m = 9.0;
uniform float dash_len_m = 3.0;
uniform float mark_wear = 0.25;
// Грунтовка: колея (две полосы), отступ от оси и ширина, трава по середине.
uniform vec3 rut_color : source_color = vec3(0.26, 0.19, 0.12);
uniform vec3 grass_tint : source_color = vec3(0.30, 0.34, 0.16);
uniform float rut_offset_m = 0.72;
uniform float rut_w_m = 0.45;

varying vec2 lp;
varying float view_dist;
varying float v_cover;
varying float v_cs_sun;


float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}


float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash12(i);
	float b = hash12(i + vec2(1.0, 0.0));
	float c = hash12(i + vec2(0.0, 1.0));
	float d = hash12(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}


// Покрытие линии шириной w вокруг c на координате x с учётом размера пикселя aa: тонкая линия
// вдали не пропадает и не мерцает, а тускнеет пропорционально ширине.
float line_cov(float x, float c, float w, float aa) {
	float we = max(w, aa);
	return clamp((we * 0.5 - abs(x - c)) / aa + 0.5, 0.0, 1.0) * (w / we);
}


void vertex() {
	lp = VERTEX.xz;
	vec4 v = MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	float d = length(v.xyz);
	view_dist = d;
	v_cs_sun = cloud_sun_at((MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz);
	// расширение до min_px пикселей; доля покрытия идёт в альфу
	float px_m = max(-v.z, 1.0) * 2.0 / (PROJECTION_MATRIX[1][1] * VIEWPORT_SIZE.y);
	float w_m = max(UV2.y, 0.5);
	float w_scr = max(w_m, min_px * px_m);
	v_cover = w_m / w_scr;
	vec3 side_v = (MODELVIEW_MATRIX * vec4(NORMAL, 0.0)).xyz;
	v.xyz += side_v * ((w_scr - w_m) * 0.5);
	NORMAL = vec3(0.0, 1.0, 0.0);
	float pull = min(depth_bias_m + d * depth_pull, d * 0.5);
	v.xyz -= v.xyz / max(d, 1e-3) * pull;
	POSITION = PROJECTION_MATRIX * v;
}


void fragment() {
	float style = floor(UV2.x + 0.5);
	float width = max(UV2.y, 0.5);
	float across = (UV.x - 0.5) * width;  // м от оси
	float e = abs(UV.x - 0.5) * 2.0;
	float along = UV.y;
	float near = 1.0 - smoothstep(detail_fade_start_m, detail_fade_end_m, view_dist);
	float aa_x = max(fwidth(across), 1e-3);
	float aa_v = max(fwidth(along), 1e-3);

	vec3 c = COLOR.rgb;
	float alpha = 1.0;
	if (style > 3.5) {
		// грунтовка: рваный край, колея, трава по середине
		float n = vnoise(lp / 1.3) - 0.5;
		alpha = 1.0 - smoothstep(0.75, 1.0, e + n * 0.5);
		float g = vnoise(vec2(along / 2.5, across * 1.7 + 7.0));
		float mid = (1.0 - smoothstep(0.0, rut_offset_m * 0.8, abs(across))) * smoothstep(0.35, 0.7, g);
		c = mix(c, grass_tint, mid * 0.55 * near);
		float rut = max(line_cov(abs(across), rut_offset_m, rut_w_m, aa_x), 0.0);
		float rn = 0.65 + 0.7 * vnoise(vec2(along / 3.0, across * 3.0));
		c = mix(c, rut_color, clamp(rut * 0.8 * rn, 0.0, 1.0));
		c *= 1.0 + (vnoise(lp / 0.6) - 0.5) * 0.3 * near;
	} else {
		// асфальт: крупное пятно, ремонтные заплаты вдоль, мелкая крупа
		float cell = floor(along / 14.0);
		float hp = hash12(vec2(cell, floor(lp.x / 300.0) + floor(lp.y / 300.0) * 17.0));
		float side = step(0.5, hash12(vec2(cell, 3.0)));
		float patch_m = step(0.82, hp) * step(0.0, (across * (side * 2.0 - 1.0)));
		float n1 = vnoise(lp / 7.0) - 0.5;
		float n2 = vnoise(lp / 1.6) - 0.5;
		float k = hash12(floor(lp * 6.0)) - 0.5;
		float v = 1.0 + (n1 * noise_amp * 2.0 + n2 * noise_amp + k * speck_amp) * near;
		v *= 1.0 - patch_amp * patch_m * (0.6 + 0.8 * hash12(vec2(cell, 9.0)));
		c *= v;
		// колея накатана: чуть темнее по полосам движения, светлее по краям
		float lanes = abs(abs(across) - width * 0.22) / (width * 0.12 + 0.01);
		c *= 1.0 - 0.07 * (1.0 - smoothstep(0.0, 1.0, lanes)) * near;
		float m = 0.0;
		float wear = 1.0 - mark_wear * vnoise(vec2(along / 1.1, across * 2.0 + 3.0)) * near;
		if (style > 0.5) {
			float dash = 1.0;
			if (style < 1.5 || style > 2.5) {
				float ph = mod(along, dash_period_m);
				dash = clamp((dash_len_m * 0.5 - abs(ph - dash_period_m * 0.5)) / aa_v + 0.5, 0.0, 1.0);
				dash = mix(dash, dash_len_m / dash_period_m, smoothstep(dash_period_m * 0.15, dash_period_m * 0.5, aa_v));
			}
			m = line_cov(across, 0.0, center_w_m, aa_x) * dash;
			if (style < 2.5) {
				float ec = width * 0.5 - edge_inset_m;
				m = max(m, max(line_cov(across, ec, edge_w_m, aa_x), line_cov(across, -ec, edge_w_m, aa_x)));
			}
		}
		c = mix(c, mark_color, clamp(m * wear, 0.0, 1.0));
	}
	c *= 1.0 - edge_darken * smoothstep(0.6, 1.0, e);
	float far = smoothstep(far_fade_start_m, far_fade_end_m, view_dist);
	if (style < 3.5) {
		float edge_m = (1.0 - e) * width * 0.5;  // м до края ленты
		float fw = min(edge_feather_m, width * 0.3);
		float en = (vnoise(lp / 0.9) - 0.5) * fw * 0.8;
		alpha = smoothstep(0.0, fw, edge_m + en);
		float sh = 1.0 - smoothstep(0.0, shoulder_w_m + fw, edge_m);
		c = mix(c, shoulder_color, shoulder_amt * sh * (0.7 + 0.6 * vnoise(lp / 2.0)));
	}
	float lum = dot(c, vec3(0.299, 0.587, 0.114));
	c = mix(c, vec3(lum), far * far_desat);
	c = mix(c, shoulder_color, far * far_tint);
	// вдали — в тон грунта рельефа, яркость не выше far_luma_max × луг
	c = mix(c, far_ground_color, far * far_ground_amt);
	float lum2 = dot(c, vec3(0.299, 0.587, 0.114));
	c *= mix(1.0, min(1.0, far_luma_max * meadow_luma / max(lum2, 1e-4)), far);
	alpha *= v_cover;
	if (alpha < 0.999) {
		float ign = fract(52.9829189 * fract(dot(FRAGCOORD.xy, vec2(0.06711056, 0.00583715))));
		if (alpha < ign) {
			discard;
		}
	}
	ALBEDO = c;
	ROUGHNESS = roughness;
	SPECULAR = specular_value;
	AO = cloud_sky_ao(v_cs_sun);
	AO_LIGHT_AFFECT = 0.0;
	NORMAL = FRONT_FACING ? NORMAL : -NORMAL;
}


void light() {
	cloud_light(NORMAL, VIEW, LIGHT, LIGHT_COLOR, ATTENUATION, LIGHT_IS_DIRECTIONAL, v_cs_sun,
			ALBEDO, ROUGHNESS, METALLIC, specular_value, vec3(0.0), CS_BURLEY, SPECULAR_AMOUNT,
			DIFFUSE_LIGHT, SPECULAR_LIGHT);
}
