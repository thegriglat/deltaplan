// Отмывка рельефа для карты выбора места: декодирует высоты Terrarium из RGB,
// красит по высоте (гипсометрия) и затеняет по уклону относительно света.
shader_type canvas_item;

uniform float m_per_px = 100.0;       // метров в пикселе тайла (на широте центра)
uniform vec3 light_dir = vec3(-0.5, -0.5, 0.7); // x — восток, y — юг, z — вверх
uniform float exaggeration = 2.0;
uniform vec3 low_color : source_color;
uniform vec3 high_color : source_color;
uniform vec3 snow_color : source_color;
uniform vec3 water_color : source_color;
uniform float low_height_m;
uniform float high_height_m;
uniform float snow_height_m;

float decode(sampler2D tex, vec2 uv) {
	vec3 c = texture(tex, uv).rgb * 255.0;
	return c.r * 256.0 + c.g + c.b / 256.0 - 32768.0;
}

void fragment() {
	vec2 px = TEXTURE_PIXEL_SIZE;
	float h = decode(TEXTURE, UV);
	float dx = (decode(TEXTURE, UV + vec2(px.x, 0.0)) - decode(TEXTURE, UV - vec2(px.x, 0.0))) / (2.0 * m_per_px);
	float dy = (decode(TEXTURE, UV + vec2(0.0, px.y)) - decode(TEXTURE, UV - vec2(0.0, px.y))) / (2.0 * m_per_px);
	vec3 n = normalize(vec3(-dx * exaggeration, -dy * exaggeration, 1.0));
	float shade = clamp(dot(n, normalize(light_dir)), 0.0, 1.0);
	float t = clamp((h - low_height_m) / max(1.0, high_height_m - low_height_m), 0.0, 1.0);
	vec3 col = mix(low_color, high_color, t);
	col = mix(col, snow_color, smoothstep(snow_height_m - 200.0, snow_height_m + 200.0, h));
	col *= 0.45 + 0.75 * shade;
	if (h <= 0.0) {
		col = water_color;
	}
	COLOR = vec4(col, 1.0);
}
