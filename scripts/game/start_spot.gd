class_name StartSpot
extends RefCounted
## Допустимость точки старта, выбранной пилотом (SP-К2, docs/contracts/start-pick.md): одна
## проверка для осмотра и запуска. Лес, кусты и пологий склон допустимы (поляна вырубает лес).


## {ok, reason, height_m, slope_deg, downhill_deg}; reason — "" | "outside" | "water" | "built" |
## "steep" (в этом порядке, первая сработавшая). Все числа конечны при любых x, z.
static func check(terrain: Terrain, x: float, z: float) -> Dictionary:
	var cfg: Dictionary = Config.get_config("game").get("start_pick", {})
	var ss: Dictionary = Config.get_config("game").start_search
	var ev := StartPlacement.evaluate(terrain.height_at, x, z, ss)
	var h := _finite(terrain.height_at(x, z))
	var slope := _finite(float(ev.slope_deg))
	var down := _finite(float(ev.heading_deg))
	var reason := ""
	var margin := float(cfg.get("edge_margin_m", 200.0))
	var b := terrain.detail_bounds().grow(-margin)
	if not is_finite(x) or not is_finite(z) or b.size.x <= 0.0 or b.size.y <= 0.0 or not b.has_point(Vector2(x, z)):
		reason = "outside"
	else:
		var surf := terrain.surface_at(x, z)
		if surf == SurfaceLayer.WATER:
			reason = "water"
		elif surf == SurfaceLayer.BUILT:
			reason = "built"
		elif slope > float(cfg.get("max_slope_deg", 40.0)):
			reason = "steep"
	return {
		"ok": reason == "",
		"reason": reason,
		"height_m": h,
		"slope_deg": slope,
		"downhill_deg": down,
	}


static func _finite(v: float) -> float:
	return v if is_finite(v) else 0.0
