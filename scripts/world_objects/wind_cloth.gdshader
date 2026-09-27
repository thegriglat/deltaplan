// Чулок ветроуказателя / лента на ветру (VR-7). Меш вытянут вдоль −Z от вертлюга (Pivot),
// корень — на расстоянии root_offset. Шейдер гнёт его: провисание (fill → 0 — висит вниз),
// сужение хвоста у пустого чулка, болтание бегущей волной. Параметры экземпляра выставляет
// WindIndicator из WindClothModel (свой материал у каждого ветроуказателя: instance uniform
// в Compatibility упираются в общий буфер, занятый облаками); длина, углы — из configs/world_objects.json.
shader_type spatial;
render_mode cull_disabled, depth_draw_opaque;

uniform vec3 albedo : source_color = vec3(1.0, 0.4, 0.05);
uniform float roughness : hint_range(0.0, 1.0) = 0.8;
uniform float cloth_length = 2.4;
uniform float root_offset = 0.32;
// Угол провисания у корня и на конце при fill = 0, рад (π/2 — строго вниз).
uniform float droop_root = 1.2;
uniform float droop_tip = 1.55;
// Изгиб дугой пропорционален limp^bend_power: давление ветра натягивает ткань, наполненный
// конус остаётся прямым и лишь наклонён целиком (как на фото); дугой висит только почти пустой.
uniform float bend_power = 2.5;
// Насколько сужается хвост пустого чулка (0 — не сужается).
uniform float collapse = 0.55;
// Волн болтания на длину.
uniform float wave_count = 1.2;
// Доля вертикальной составляющей болтания.
uniform float flutter_vertical = 0.2;

uniform float fill = 1.0;
uniform float flutter_amp = 0.05;
uniform float flutter_phase = 0.0;


// Поворот вектора в плоскости (вперёд, вверх) на угол a: (1,0) → (cos a, −sin a).
vec2 bend(vec2 fu, float a) {
	float c = cos(a);
	float s = sin(a);
	return vec2(fu.x * c + fu.y * s, -fu.x * s + fu.y * c);
}


void vertex() {
	float along = -VERTEX.z - root_offset;
	float s = clamp(along / cloth_length, 0.0, 1.0);
	float limp = 1.0 - fill;
	float a0 = limp * droop_root;
	float k = pow(limp, bend_power) * (droop_tip - droop_root);
	float a = a0 + k * s;
	// Осевая линия: интеграл (cos a, −sin a) по длине (вперёд, вверх).
	vec2 axis;
	if (abs(k) > 1e-4) {
		axis = cloth_length * vec2(sin(a) - sin(a0), cos(a) - cos(a0)) / k;
	} else {
		axis = cloth_length * s * vec2(cos(a0), -sin(a0));
	}
	float shrink = 1.0 - limp * limp * collapse * s;
	vec2 rad = bend(vec2(0.0, VERTEX.y * shrink), a);
	float w = TAU * wave_count * s;
	float amp = flutter_amp * cloth_length * s * s;
	float lat = amp * sin(flutter_phase - w);
	float vert = amp * flutter_vertical * sin(1.7 * flutter_phase - w + 1.0);
	VERTEX = vec3(
		VERTEX.x * shrink + lat,
		axis.y + rad.y + vert,
		-(root_offset + axis.x + rad.x)
	);
	vec2 n = bend(vec2(-NORMAL.z, NORMAL.y), a);
	NORMAL = normalize(vec3(NORMAL.x, n.y, -n.x));
}


void fragment() {
	ALBEDO = albedo;
	ROUGHNESS = roughness;
	if (!FRONT_FACING) {
		NORMAL = -NORMAL;
	}
}
