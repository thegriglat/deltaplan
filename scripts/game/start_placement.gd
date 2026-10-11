class_name StartPlacement
extends RefCounted
## Старт в произвольной точке (FR-17): найти рядом склон, пригодный для разбега,
## и курс — вниз по склону. Чистая функция рельефа, тестируется headless.
## Параметры — configs/game.json → start_search.


## height_fn(x, z) -> высота; (x, z) — выбранная точка; cfg — game.json → start_search.
## Возвращает {ok, position: Vector3, heading_deg, slope_deg}. ok = false — склона нет,
## тогда старт в самой точке с курсом вниз по уклону (или на север на ровном).
static func find_launch(height_fn: Callable, x: float, z: float, cfg: Dictionary) -> Dictionary:
	var radius := float(cfg.radius_m)
	var step := maxf(float(cfg.step_m), 1.0)
	var best: Dictionary = {}
	var best_score := INF
	var n := int(ceil(radius / step))
	for i in range(-n, n + 1):
		for j in range(-n, n + 1):
			var p := Vector2(x + i * step, z + j * step)
			var d := p.distance_to(Vector2(x, z))
			if d > radius:
				continue
			var c := evaluate(height_fn, p.x, p.y, cfg)
			if not c.ok:
				continue
			var score := (
				absf(float(c.slope_deg) - float(cfg.best_slope_deg)) / float(cfg.best_slope_deg)
				+ d / maxf(radius, 1.0)
			)
			if score < best_score:
				best_score = score
				best = c
	if not best.is_empty():
		return best
	var here := evaluate(height_fn, x, z, cfg)
	here.ok = false
	return here


## Оценить точку: уклон, курс вниз по склону и пригодность для разбега.
static func evaluate(height_fn: Callable, x: float, z: float, cfg: Dictionary) -> Dictionary:
	var e := float(cfg.probe_m)
	var hx := float(height_fn.call(x + e, z)) - float(height_fn.call(x - e, z))
	var hz := float(height_fn.call(x, z + e)) - float(height_fn.call(x, z - e))
	var grad := Vector2(hx, hz) / (2.0 * e)
	var slope := rad_to_deg(atan(grad.length()))
	var down := -grad.normalized() if grad.length() > 1e-6 else Vector2(0, -1)
	var heading := heading_of(down)
	var h0 := float(height_fn.call(x, z))
	var ok := slope >= float(cfg.min_slope_deg) and slope <= float(cfg.max_slope_deg)
	if ok:
		# По курсу разбега склон не должен выполаживаться или идти вверх.
		var run := float(cfg.runway_m)
		var p := Vector2(x, z) + down * run
		var drop := h0 - float(height_fn.call(p.x, p.y))
		ok = drop >= run * tan(deg_to_rad(float(cfg.min_slope_deg))) * 0.7
	return {
		"ok": ok,
		"position": Vector3(x, h0, z),
		"heading_deg": heading,
		"slope_deg": slope,
	}


## Курс (0 — север, по часовой) направления d в плоскости (x — восток, y — юг).
static func heading_of(d: Vector2) -> float:
	return fposmod(rad_to_deg(atan2(d.x, -d.y)), 360.0)
