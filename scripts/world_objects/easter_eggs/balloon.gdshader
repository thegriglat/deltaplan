shader_type spatial;
// Воздушный шар (пасхалка): клинья двух цветов на оболочке, корзина. Цвета и число клиньев —
// из данных экземпляра MultiMesh: COLOR — цвет А, INSTANCE_CUSTOM.rgb — цвет Б,
// INSTANCE_CUSTOM.a — число клиньев / 32. Колыхание по высоте — от времени полёта wt.

uniform bool basket = false;
uniform vec3 basket_color : source_color = vec3(0.35, 0.22, 0.1);
uniform float wt = 0.0;
uniform float bob_amp = 0.0;
uniform float bob_period = 100.0;

varying vec3 col_a;
varying vec3 col_b;
varying float wedges;

void vertex() {
	float h = fract(sin(float(INSTANCE_ID) * 12.9898) * 43758.5453);
	VERTEX.y += sin(wt * TAU / (bob_period * (0.8 + 0.4 * h)) + h * TAU) * bob_amp;
	col_a = COLOR.rgb;
	col_b = INSTANCE_CUSTOM.rgb;
	wedges = floor(INSTANCE_CUSTOM.a * 32.0 + 0.5);
}

void fragment() {
	vec3 c = basket_color;
	if (!basket) {
		bool odd = mod(floor(UV.x * wedges), 2.0) > 0.5;
		c = odd ? col_b : col_a;
		if (UV.y < 0.07) {
			c = col_b * 0.55;
		}
		EMISSION = c * 0.15;
		BACKLIGHT = c * 0.35;
	}
	ALBEDO = c;
	ROUGHNESS = 0.85;
}
