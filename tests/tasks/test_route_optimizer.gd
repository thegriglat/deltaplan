extends TestCase
## Оптимизированная дистанция по касательным к цилиндрам — сравнение с ручным расчётом.


func _opt() -> RouteOptimizer:
	return RouteOptimizer.from_settings()


func _c(x: float, z: float, r: float) -> Dictionary:
	return RouteOptimizer.circle(Vector2(x, z), r)


## Все цилиндры на одной прямой: маршрут идёт по прямой, до ближнего края гоула.
func test_collinear() -> void:
	var targets: Array[Dictionary] = [_c(10000, 0, 1000), _c(20000, 0, 400)]
	var r := _opt().solve(Vector2.ZERO, targets)
	approx(r.distance_m, 19600.0, 0.5, "0 → (через круг) → край гоула: 20000 − 400")


## Симметричный «угол»: из (0,0) через круг (10000, −10000) r 1000 в точку (20000, 0).
## Ручной расчёт: касание в (10000, −9000), 2·√(10000² + 9000²) = 26907.25 м.
func test_symmetric_dogleg() -> void:
	var targets: Array[Dictionary] = [_c(10000, -10000, 1000), _c(20000, 0, 0)]
	var r := _opt().solve(Vector2.ZERO, targets)
	approx(r.distance_m, 2.0 * sqrt(1.0e8 + 8.1e7), 1.0, "угол через цилиндр")
	var p: Vector2 = r.points[0]
	approx(p.x, 10000.0, 5.0, "точка касания x")
	approx(p.y, -9000.0, 5.0, "точка касания z")


## Несимметричный случай: сравнение с перебором точки по окружности с шагом 0.01°.
func test_asymmetric_brute_force() -> void:
	var c := Vector2(6000, -8000)
	var rad := 1500.0
	var b := Vector2(15000, 3000)
	var best := INF
	for i in 36000:
		var x := c + Vector2.from_angle(deg_to_rad(i * 0.01)) * rad
		best = minf(best, x.length() + x.distance_to(b))
	var targets: Array[Dictionary] = [_c(c.x, c.y, rad), _c(b.x, b.y, 0)]
	approx(_opt().solve(Vector2.ZERO, targets).distance_m, best, 1.0, "перебор")


## Три цилиндра «зигзагом», гоул-цилиндр: перебор двух углов (шаг 1°).
func test_two_turnpoints_brute_force() -> void:
	var c1 := Vector2(5000, -6000)
	var c2 := Vector2(11000, 1000)
	var g := Vector2(16000, -5000)
	var r1 := 800.0
	var r2 := 1200.0
	var rg := 400.0
	var best := INF
	for i in 360:
		var p1 := c1 + Vector2.from_angle(deg_to_rad(i * 1.0)) * r1
		for j in 360:
			var p2 := c2 + Vector2.from_angle(deg_to_rad(j * 1.0)) * r2
			var d := p1.length() + p1.distance_to(p2) + maxf(p2.distance_to(g) - rg, 0.0)
			best = minf(best, d)
	var targets: Array[Dictionary] = [_c(c1.x, c1.y, r1), _c(c2.x, c2.y, r2), _c(g.x, g.y, rg)]
	var got: float = _opt().solve(Vector2.ZERO, targets).distance_m
	check(got <= best + 0.5, "не длиннее перебора: %.1f vs %.1f" % [got, best])
	approx(got, best, 5.0, "совпадает с перебором (шаг перебора 1°)")


## Линия гоула: расстояние до ближайшей точки отрезка.
func test_goal_line() -> void:
	var targets: Array[Dictionary] = [
		RouteOptimizer.line(Vector2(10000, -200), Vector2(10000, 200))
	]
	approx(_opt().solve(Vector2.ZERO, targets).distance_m, 10000.0, 0.1, "прямо на линию")
	var off: Array[Dictionary] = [RouteOptimizer.line(Vector2(10000, 1000), Vector2(10000, 1400))]
	approx(_opt().solve(Vector2.ZERO, off).distance_m, sqrt(1.0e8 + 1.0e6), 0.1, "до края линии")


## Дистанция задания из взлёта: старт-цилиндр на выход вокруг взлёта (не удлиняет),
## пункт (0, −10000) r 1000, гоул (0, −20000) r 400 → 20000 − 400.
func test_task_distance() -> void:
	var H := preload("res://tests/tasks/task_helpers.gd")
	var t: Task = (
		H
		. make_task(
			[
				["takeoff", 0, 0, 400],
				["sss", 0, 0, 2000, "exit"],
				["turnpoint", 0, -10000, 1000],
				["goal", 0, -20000, 400],
			]
		)
	)
	approx(t.task_distance_m(), 19600.0, 0.5, "дистанция задания")
