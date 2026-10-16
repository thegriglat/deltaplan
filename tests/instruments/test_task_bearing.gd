extends TestCase
## Пеленг на точку относительно путевого курса (InstrumentTask.relative_bearing_deg).

const O := Vector3.ZERO


func test_north_east_behind() -> void:
	var north := Vector3(0, 0, -1000)
	var east := Vector3(1000, 0, 0)
	var south := Vector3(0, 0, 1000)
	check(is_equal_approx(InstrumentTask.relative_bearing_deg(O, north, 0.0), 0.0), "север при курсе 0 — прямо")
	check(is_equal_approx(InstrumentTask.relative_bearing_deg(O, east, 0.0), 90.0), "восток при курсе 0 — справа")
	check(is_equal_approx(InstrumentTask.relative_bearing_deg(O, south, 0.0), 180.0), "юг при курсе 0 — сзади")
	check(is_equal_approx(InstrumentTask.relative_bearing_deg(O, Vector3(-1000, 0, 0), 0.0), -90.0), "запад — слева")


func test_courses() -> void:
	var east := Vector3(1000, 0, 0)
	check(is_equal_approx(InstrumentTask.relative_bearing_deg(O, east, 90.0), 0.0), "курс на восток, точка на востоке — прямо")
	check(is_equal_approx(InstrumentTask.relative_bearing_deg(O, east, 270.0), 180.0), "курс на запад — сзади")
	check(is_equal_approx(InstrumentTask.relative_bearing_deg(O, east, 350.0), 100.0), "переход через 360")
	check(is_equal_approx(InstrumentTask.relative_bearing_deg(O, Vector3(0, 0, -1000), 20.0), -20.0), "север при курсе 20 — слева 20")


func test_no_target() -> void:
	var t := InstrumentTask.new()
	check(is_nan(t.target_relative_bearing_deg(O, 0.0)), "цели нет — NAN")
	t.set_points([{"name": "a", "position": Vector3(0, 0, -500), "radius_m": 400.0}], 0)
	check(is_equal_approx(t.target_relative_bearing_deg(O, 0.0), 0.0), "цель впереди")
