extends TestCase
## Тесты формул GrassField (без GPU — статические функции повторяют grass.gdshader,
## см. комментарии рядом с каждой функцией в scripts/terrain/grass_field.gd).

const AREA_RADIUS := 30.0
const FAR_DENSITY_MIN := 0.12
const THIN_START_K := 0.1
const THIN_END_K := 0.85
const FULL_M := 0.4
const ZERO_M := 1.2
const PRESS_RADIUS := 1.5


## Вершин травы в кольце 20–30 м в 5–8 раз меньше, чем в 0–10 м на единицу площади
## (усреднение плотности по кольцу с весом на площадь, как в шейдере).
func test_far_thinning_ratio() -> void:
	var near := _ring_avg_density(0.0, 10.0)
	var far := _ring_avg_density(20.0, 30.0)
	var ratio := near / far
	check(ratio >= 5.0 and ratio <= 8.0, "ratio 0-10 / 20-30 = %.2f (ждали 5..8)" % ratio)


func _ring_avg_density(r0: float, r1: float, n: int = 400) -> float:
	var num := 0.0
	var den := 0.0
	for i in n:
		var r := r0 + (r1 - r0) * (float(i) + 0.5) / n
		var w := r  # весом на площадь кольца (2*pi*r*dr, множитель сокращается)
		num += (
			GrassField
			. far_density(r, AREA_RADIUS, FAR_DENSITY_MIN, THIN_START_K, THIN_END_K)
			* w
		)
		den += w
	return num / den


func test_press_full_at_low_agl() -> void:
	var f := GrassField.press_factor(0.0, PRESS_RADIUS, 0.2, FULL_M, ZERO_M)
	check(f > 0.99, "приминание у ног пилота на земле должно быть полным: %.3f" % f)


func test_press_zero_above_1_2m() -> void:
	var f := GrassField.press_factor(0.0, PRESS_RADIUS, 1.5, FULL_M, ZERO_M)
	check(f < 0.01, "пилот в 1,5 м над землёй — приминания быть не должно: %.3f" % f)


func test_press_zero_far_from_pilot() -> void:
	var f := GrassField.press_factor(10.0, PRESS_RADIUS, 0.0, FULL_M, ZERO_M)
	check(f < 0.01, "далеко от пилота — приминания нет: %.3f" % f)


## Точка в прямоугольнике посадки — скошено, в 1 м за краем — нет.
func test_landing_rect_inside_and_outside() -> void:
	var center := Vector2(100.0, -50.0)
	var axis_deg := 30.0
	var length_m := 200.0
	var width_m := 30.0
	check(
		GrassField.in_landing_rect(center, center, axis_deg, length_m, width_m),
		"центр площадки — внутри"
	)
	var axis3 := TerrainGeo.heading_vector(axis_deg)
	var axis2 := Vector2(axis3.x, axis3.z)
	var right3 := axis3.cross(Vector3.UP)
	var right2 := Vector2(right3.x, right3.z)
	var edge_in := center + axis2 * (length_m * 0.5 - 1.0)
	check(
		GrassField.in_landing_rect(edge_in, center, axis_deg, length_m, width_m), "1 м до края — внутри"
	)
	var edge_out := center + axis2 * (length_m * 0.5 + 1.0)
	check(
		not GrassField.in_landing_rect(edge_out, center, axis_deg, length_m, width_m),
		"1 м за краем по длине — снаружи"
	)
	var side_out := center + right2 * (width_m * 0.5 + 1.0)
	check(
		not GrassField.in_landing_rect(side_out, center, axis_deg, length_m, width_m),
		"1 м за краем по ширине — снаружи"
	)
