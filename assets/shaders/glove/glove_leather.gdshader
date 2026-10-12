shader_type spatial;
// Кожа краг и кистей пилота: Leather037 (ambientCG, CC0) по коробочным UV меша; потёртость и
// глянец у трубы и на костяшках — из UV2 кисти (x — ладонь у трубы, y — костяшки); у крага
// UV2 = (−расстояние от кромки, м; доля обхода) — строчка шва и затёртая кромка.

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D rough_tex : hint_roughness_gray, filter_linear_mipmap, repeat_enable;
uniform vec3 tint : source_color = vec3(0.06, 0.036, 0.024);
uniform vec3 worn_tint : source_color = vec3(0.2, 0.12, 0.075);
uniform vec3 thread_tint : source_color = vec3(0.3, 0.22, 0.14);
uniform float normal_strength = 1.0;
uniform float base_rough = 0.62;
uniform float seam_d = 0.012;

varying vec2 wear;

void vertex() {
	wear = UV2;
}

void fragment() {
	vec2 uv = UV;
	vec3 tex = texture(albedo_tex, uv).rgb;
	float lum = dot(tex, vec3(0.299, 0.587, 0.114));
	vec3 nm = texture(normal_tex, uv).xyz * 2.0 - 1.0;
	nm.xy *= normal_strength;
	nm.z = sqrt(max(1.0 - dot(nm.xy, nm.xy), 0.0));
	// касательный базис по производным UV (в меше нет касательных)
	vec3 n0 = normalize(NORMAL);
	vec3 dp1 = dFdx(VERTEX);
	vec3 dp2 = dFdy(VERTEX);
	vec2 du1 = dFdx(uv);
	vec2 du2 = dFdy(uv);
	vec3 p2 = cross(dp2, n0);
	vec3 p1 = cross(n0, dp1);
	vec3 t = p2 * du1.x + p1 * du2.x;
	vec3 b = p2 * du1.y + p1 * du2.y;
	float inv = inversesqrt(max(max(dot(t, t), dot(b, b)), 1e-12));
	NORMAL = normalize(mat3(t * inv, b * inv, n0) * nm);

	float rough_tex_v = texture(rough_tex, uv * 0.7).r;
	float grain = texture(albedo_tex, uv * 0.23).r;           // крупное пятно потёртости
	float crease = clamp((1.0 - nm.z) * 3.0, 0.0, 1.0);
	float use = 0.0;
	float cuff = step(wear.x, -0.0001);
	float d = -wear.x;
	if (cuff < 0.5) {
		use = clamp(wear.x, 0.0, 1.0) * (0.55 + 0.6 * grain) + wear.y * 0.8;
	} else {
		use = smoothstep(0.016, 0.0, d) * (0.5 + 0.5 * grain);   // затёртая кромка отворота
	}
	use = clamp(use, 0.0, 1.0);
	vec3 col = tint * (0.55 + 1.3 * lum);
	col *= 1.0 - 0.4 * crease;                                    // в складках темнее
	col = mix(col, worn_tint * (0.7 + 0.6 * lum), use * 0.65);
	float rough = base_rough * (0.75 + 0.5 * rough_tex_v);
	rough = mix(rough, 0.26 + 0.1 * rough_tex_v, use);            // глянец на тёртых местах
	if (cuff > 0.5) {
		// строчка: пунктир на seam_d от кромки
		float line = smoothstep(0.0012, 0.0004, abs(d - seam_d));
		float dash = step(fract(wear.y * 64.0), 0.58);
		float st = line * dash * step(0.002, d);
		col = mix(col, thread_tint, st);
		rough = mix(rough, 0.8, st);
		col *= 1.0 - 0.25 * smoothstep(0.0022, 0.0004, abs(d - seam_d - 0.002)) * (1.0 - st);
	}
	ALBEDO = col;
	ROUGHNESS = clamp(rough, 0.05, 1.0);
	METALLIC = 0.0;
	SPECULAR = 0.45;
}
