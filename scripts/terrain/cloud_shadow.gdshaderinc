// Тени облаков на земле (VR-2): облако закрывает ПРЯМОЕ солнце, рассеянный свет неба остаётся.
// Карта пропускания облаков вдоль луча к солнцу — CloudShadowMap (scripts/atmosphere/
// cloud_shadow_map.gd): вид сверху на опорную плоскость вокруг пилота; точка земли на высоте y
// берёт её в точке, где её луч к солнцу пересекает опорную плоскость (рельеф любой высоты — точно).
// Прямое солнце гасится в своём light(): формулы — как у встроенного освещения Godot 4
// (diffuse_burley / lambert_wrap / lambert, specular_schlick_ggx), солнце × cloud_sun.
// Подключение (см. terrain.gdshader, grass.gdshader …):
//   varying float v_cs_sun;   varying float v_cs_spec;   (присвоить в vertex или fragment)
//   v_cs_sun = cloud_sun_at(мировая точка);  v_cs_spec = SPECULAR материала (0.5 по умолчанию);
//   во fragment: AO *= cloud_sky_ao(v_cs_sun) (облако закрывает и часть неба);
//   void light() { cloud_light(NORMAL, VIEW, LIGHT, LIGHT_COLOR, ATTENUATION, LIGHT_IS_DIRECTIONAL,
//       v_cs_sun, ALBEDO, ROUGHNESS, METALLIC, v_cs_spec, BACKLIGHT, режим, SPECULAR_AMOUNT,
//       DIFFUSE_LIGHT, SPECULAR_LIGHT); }
// Глобальные параметры (project.godot → [shader_globals]) ставит CloudShadowMap.

global uniform sampler2D cloud_shadow_map;
// x, z левого верхнего угла карты, 1 / размер карты (м), сила тени (0 — теней нет).
global uniform vec4 cloud_shadow_rect;
// sun.x / sun.y, sun.z / sun.y, высота опорной плоскости (м), доля края карты, где тень тает.
global uniform vec4 cloud_shadow_sun;
// Доля рассеянного света неба, которую облако над точкой закрывает в полной тени (0..1).
global uniform float cloud_shadow_sky;

const int CS_LAMBERT = 0;
const int CS_LAMBERT_WRAP = 1;
const int CS_BURLEY = 2;

// Множитель прямого солнца в мировой точке wp: 1 — солнце, 1 − сила — полная тень.
float cloud_sun_at(vec3 wp) {
	if (cloud_shadow_rect.w <= 0.0) {
		return 1.0;
	}
	vec2 xz = wp.xz + cloud_shadow_sun.xy * (cloud_shadow_sun.z - wp.y);
	vec2 uv = (xz - cloud_shadow_rect.xy) * cloud_shadow_rect.z;
	vec2 e = min(uv, 1.0 - uv);
	float edge = smoothstep(0.0, cloud_shadow_sun.w, min(e.x, e.y));
	if (edge <= 0.0) {
		return 1.0;
	}
	float t = textureLod(cloud_shadow_map, uv, 0.0).r;
	return 1.0 - cloud_shadow_rect.w * edge * (1.0 - t);
}

// Множитель рассеянного света (в AO) по множителю солнца sun_k: облако закрывает и часть неба.
float cloud_sky_ao(float sun_k) {
	float shade = (1.0 - sun_k) / max(cloud_shadow_rect.w, 1e-3);
	return 1.0 - cloud_shadow_sky * clamp(shade, 0.0, 1.0);
}

float cs_schlick(float u) {
	float m = clamp(1.0 - u, 0.0, 1.0);
	float m2 = m * m;
	return m2 * m2 * m;
}

// Свет одного источника как у встроенного освещения; у солнца (directional) — × sun_k.
void cloud_light(vec3 n, vec3 v, vec3 l, vec3 light_color, float atten, bool directional,
		float sun_k, vec3 albedo, float roughness, float metallic, float spec, vec3 backlight,
		int diffuse_mode, float specular_amount, inout vec3 diffuse_light, inout vec3 specular_light) {
	float a = atten * (directional ? sun_k : 1.0);
	if (a <= 0.0) {
		return;
	}
	float ndotl = min(dot(n, l), 1.0);
	float c_ndotl = max(ndotl, 0.0);
	float c_ndotv = max(dot(n, v), 1e-4);
	vec3 h = normalize(v + l);
	float c_ldoth = clamp(dot(l, h), 0.0, 1.0);
	float brdf;
	if (diffuse_mode == CS_LAMBERT_WRAP) {
		brdf = max(0.0, (ndotl + roughness) / ((1.0 + roughness) * (1.0 + roughness))) * (1.0 / PI);
	} else if (diffuse_mode == CS_BURLEY) {
		float fd90_m1 = 2.0 * c_ldoth * c_ldoth * roughness - 0.5;
		float fdv = 1.0 + fd90_m1 * cs_schlick(c_ndotv);
		float fdl = 1.0 + fd90_m1 * cs_schlick(c_ndotl);
		brdf = (1.0 / PI) * fdv * fdl * c_ndotl;
	} else {
		brdf = c_ndotl * (1.0 / PI);
	}
	diffuse_light += light_color * brdf * a;
	diffuse_light += light_color * (vec3(1.0 / PI) - brdf) * backlight * a;
	if (spec > 0.0 && c_ndotl > 0.0) {
		float c_ndoth = clamp(dot(n, h), 0.0, 1.0);
		float alpha = roughness * roughness;
		float ah = c_ndoth * alpha;
		float k = alpha / (1.0 - c_ndoth * c_ndoth + ah * ah);
		float d = k * k * (1.0 / PI);
		float g = 0.5 / mix(2.0 * c_ndotl * c_ndotv, c_ndotl + c_ndotv, alpha);
		vec3 f0 = mix(vec3(0.16 * spec * spec), albedo, metallic);
		float f90 = clamp(dot(f0, vec3(50.0 * 0.33)), metallic, 1.0);
		vec3 f = f0 + (f90 - f0) * cs_schlick(c_ldoth);
		specular_light += c_ndotl * d * g * f * light_color * a * specular_amount;
	}
}
