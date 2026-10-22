class_name TowSite
extends RefCounted
## Место с полосой для буксировки (TW-К6, docs/contracts/tow.md): полоса от точки (x, z) вперёд по
## курсу — равнина по рельефу и поверхности. Критерии — configs/game.json → tow_site.
## Курс — от севера по часовой; мир: X восток, −Z север.


## {ok, reason, slope_deg, dh_m, flat_length_m, heading_deg, start_pos, end_pos}.
## reason — "" | "tow_site_bad" | "tow_site_edge" | "tow_site_surface" | "tow_site_slope" | "tow_site_dh"
## (ключи locale/ui.csv; первая сработавшая в этом порядке). slope_deg — макс. уклон на шаге вдоль оси,
## dh_m — max(h) − min(h) вдоль оси, flat_length_m — длина от начала, на которой уклон шага ≤ flat_max_deg
## и перепад ≤ dh_max_frac·length_m (не больше length_m). Числа конечны при любых входах.
static func check(
	terrain: Terrain, x: float, z: float, heading_deg: float, length_m: float, width_m: float
) -> Dictionary:
	var cfg: Dictionary = Config.get_config("game").get("tow_site", {})
	var flat_max := float(cfg.get("flat_max_deg", 2.0))
	var dh_max := float(cfg.get("dh_max_frac", 0.02)) * maxf(length_m, 0.0)
	var step_m := maxf(float(cfg.get("sample_m", 25.0)), 1.0)
	var margin := float(cfg.get("edge_margin_m", 200.0))
	var out := {
		"ok": false,
		"reason": "tow_site_bad",
		"slope_deg": 0.0,
		"dh_m": 0.0,
		"flat_length_m": 0.0,
		"heading_deg": heading_deg if is_finite(heading_deg) else 0.0,
		"start_pos": Vector3.ZERO,
		"end_pos": Vector3.ZERO,
	}
	if not (is_finite(x) and is_finite(z) and is_finite(heading_deg)):
		return out
	if not (is_finite(length_m) and is_finite(width_m)) or length_m <= 0.0 or width_m <= 0.0:
		return out
	var h := deg_to_rad(heading_deg)
	var dir := Vector2(sin(h), -cos(h))
	var side := Vector2(-dir.y, dir.x)
	var p0 := Vector2(x, z)
	var p1 := p0 + dir * length_m
	out.start_pos = Vector3(x, terrain.height_at(x, z), z)
	out.end_pos = Vector3(p1.x, terrain.height_at(p1.x, p1.y), p1.y)
	# границы: оба конца и углы полосы внутри детального рельефа с отступом
	var b := terrain.detail_bounds().grow(-margin)
	var hw := width_m * 0.5
	var corners := [p0 + side * hw, p0 - side * hw, p1 + side * hw, p1 - side * hw]
	var inside := b.size.x > 0.0 and b.size.y > 0.0
	for c: Vector2 in corners:
		inside = inside and b.has_point(c)
	if not inside:
		out.reason = "tow_site_edge"
		return out
	# выборка вдоль оси: станции через step_m и конец; по бокам ±w/2 — поверхность и поперечный уклон
	var n := maxi(ceili(length_m / step_m), 1)
	var hs := PackedFloat32Array()
	var ds := PackedFloat32Array()
	var surface_bad := false
	var cross_deg := 0.0
	for i in n + 1:
		var d := minf(i * length_m / n, length_m)
		var c := p0 + dir * d
		var hc := terrain.height_at(c.x, c.y)
		hs.append(hc)
		ds.append(d)
		var hl := terrain.height_at(c.x + side.x * hw, c.y + side.y * hw)
		var hr := terrain.height_at(c.x - side.x * hw, c.y - side.y * hw)
		cross_deg = maxf(cross_deg, rad_to_deg(atan(absf(hl - hr) / width_m)))
		for q in [c, c + side * hw, c - side * hw]:
			var sf := terrain.surface_at(q.x, q.y)
			if sf == SurfaceLayer.WATER or sf == SurfaceLayer.FOREST:
				surface_bad = true
	# уклон шага, перепад и длина ровного участка от начала
	var slope_max := 0.0
	var hmin := hs[0]
	var hmax := hs[0]
	var flat_len := ds[n]
	var broken := false
	for i in range(1, n + 1):
		var sl := rad_to_deg(atan(absf(hs[i] - hs[i - 1]) / (ds[i] - ds[i - 1])))
		slope_max = maxf(slope_max, sl)
		hmin = minf(hmin, hs[i])
		hmax = maxf(hmax, hs[i])
		if not broken and (sl > flat_max or hmax - hmin > dh_max):
			broken = true
			flat_len = ds[i - 1]
	out.slope_deg = slope_max if is_finite(slope_max) else 0.0
	out.dh_m = hmax - hmin if is_finite(hmax - hmin) else 0.0
	out.flat_length_m = flat_len
	out.reason = ""
	if surface_bad:
		out.reason = "tow_site_surface"
	elif slope_max > flat_max or cross_deg > flat_max:
		out.reason = "tow_site_slope"
	elif hmax - hmin > dh_max:
		out.reason = "tow_site_dh"
	out.ok = out.reason == ""
	return out


## Размер поляны под полосу площадки с блоком tow: Vector2(длина, ширина), м — ширина полосы
## runway_width_m плюс запас clearing_margin_m с каждой стороны (game.json → tow_site).
static func clearing_size(tow: Dictionary) -> Vector2:
	var margin := float(Config.value("game", "tow_site.clearing_margin_m", 30.0))
	var w := float(tow.get("runway_width_m", 0.0))
	var l := float(tow.get("runway_length_m", 0.0))
	if l <= 0.0 or w <= 0.0:
		return Vector2.ZERO
	return Vector2(l, w + 2.0 * margin)
