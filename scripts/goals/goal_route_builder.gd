class_name GoalRouteBuilder
extends RefCounted
## Построение маршрутов целей «возврат» и «треугольник» от точки взлёта (GL-К3).
## Результат — словарь задания для Task.from_dict (пункты в метрах мира). Вся фигура
## поворачивается вокруг взлёта с шагом route.rotate_step_deg, пока не поместится в bounds
## (с отступом route.bounds_margin_m). Не помещается ни при каком повороте — {} (цель недоступна).


## Единичный вектор XZ по курсу heading_deg (0 — север = −Z, по часовой).
static func dir_xz(heading_deg: float) -> Vector2:
	var r := deg_to_rad(heading_deg)
	return Vector2(sin(r), -cos(r))


## Курс первого плеча: откуда дует ветер (если он достаточно силён), иначе курс старта.
static func first_heading_deg(ctx: Dictionary, cfg: Dictionary) -> float:
	var wind_ms := float(ctx.get("wind_ms", 0.0))
	if wind_ms >= float(cfg.get("min_wind_ms", 2.0)):
		return float(ctx.get("wind_from_deg", 0.0))
	return float(ctx.get("start_heading_deg", 0.0))


## Возврат: точка поворота на distance_m от взлёта и гоул у взлёта.
static func build_return(distance_m: float, ctx: Dictionary, cfg: Dictionary) -> Dictionary:
	var home := _home(ctx)
	var base := first_heading_deg(ctx, cfg)
	for off in _offsets(cfg):
		var tp := home + dir_xz(base + off) * distance_m
		if _fits([tp], ctx, cfg):
			return _task("goal_return", home, [tp], cfg)
	return {}


## Треугольник: равносторонний, периметр perimeter_m, вершины — взлёт и два пункта.
static func build_triangle(perimeter_m: float, ctx: Dictionary, cfg: Dictionary) -> Dictionary:
	var home := _home(ctx)
	var base := first_heading_deg(ctx, cfg)
	var side := perimeter_m / 3.0
	for off in _offsets(cfg):
		for turn in [60.0, -60.0]:  # второе плечо вправо / влево
			var a := home + dir_xz(base + off) * side
			var b := home + dir_xz(base + off + turn) * side
			if _fits([a, b], ctx, cfg):
				return _task("goal_triangle", home, [a, b], cfg)
	return {}


## Смещения поворота: 0, +s, −s, +2s, −2s … до 180°.
static func _offsets(cfg: Dictionary) -> Array[float]:
	var step := maxf(float(cfg.get("rotate_step_deg", 15.0)), 1.0)
	var out: Array[float] = [0.0]
	var k := 1
	while step * k <= 180.0:
		out.append(step * k)
		if step * k < 180.0:
			out.append(-step * k)
		k += 1
	return out


static func _home(ctx: Dictionary) -> Vector2:
	var p: Vector3 = ctx.get("start_pos", Vector3.ZERO)
	return Vector2(p.x, p.z)


static func _fits(points: Array[Vector2], ctx: Dictionary, cfg: Dictionary) -> bool:
	var bounds: Rect2 = ctx.get("bounds", Rect2())
	if not bounds.has_area():
		return true  # границ нет — ограничений нет
	var inner := bounds.grow(-float(cfg.get("bounds_margin_m", 0.0)))
	if not inner.has_area():
		return false
	for p in points:
		if not inner.has_point(p):
			return false
	return true


static func _task(id: String, home: Vector2, tps: Array[Vector2], cfg: Dictionary) -> Dictionary:
	var tp_r := float(cfg.get("turnpoint_radius_m", 400.0))
	var home_r := float(cfg.get("home_radius_m", 400.0))
	var list := [
		{
			"name": "takeoff",
			"type": "takeoff",
			"x_m": home.x,
			"z_m": home.y,
			"radius_m": home_r
		}
	]
	for i in tps.size():
		list.append(
			{
				"name": "TP%d" % (i + 1),
				"type": "turnpoint",
				"x_m": tps[i].x,
				"z_m": tps[i].y,
				"radius_m": tp_r
			}
		)
	list.append(
		{"name": "goal", "type": "goal", "x_m": home.x, "z_m": home.y, "radius_m": home_r}
	)
	return {"id": id, "name": id, "type": "race", "turnpoints": list}
