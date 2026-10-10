class_name PowerLinePlanner
extends RefCounted
## ЛЭП из OSM (VR-10, восстановлено для OT-10): опоры по узлам линии (слишком близкие сливаются,
## длинные пролёты делятся) и провода — цепные линии (парабола с провисанием sag_ratio·пролёт)
## между точками подвеса. Линии — OsmData.power: [{minor, p: PackedVector2Array}].
## Без нод: plan() → {supports: [{position, yaw, tower: bool}], wires: [PackedVector3Array]}.
## Тип опоры: решётчатая у линий power=line, столб — у minor_line.


static func plan(lines: Array, cfg: Dictionary, height_fn: Callable) -> Dictionary:
	var supports: Array[Dictionary] = []
	var wires: Array[PackedVector3Array] = []
	for line: Dictionary in lines:
		var tower := not bool(line.get("minor", false))
		var arms: Array = cfg.tower_arms_m if tower else cfg.pole_arms_m
		var n_wires := arms.size() if tower else mini(3, arms.size())
		var pts := support_points(line.p, float(cfg.min_span_m), float(cfg.max_span_m))
		if pts.size() < 2:
			continue
		var attach: Array = []
		for i in pts.size():
			var d := (pts[mini(i + 1, pts.size() - 1)] - pts[maxi(i - 1, 0)]).normalized()
			var dir := Vector3(d.x, 0.0, d.y)
			var right := dir.cross(Vector3.UP)
			var g := float(height_fn.call(pts[i].x, pts[i].y))
			var base := Vector3(pts[i].x, g, pts[i].y)
			supports.append({"position": base, "yaw": atan2(-dir.x, -dir.z), "tower": tower})
			var pa := PackedVector3Array()
			for k in n_wires:
				var arm: Array = arms[k]
				pa.append(base + right * float(arm[0]) + Vector3.UP * float(arm[1]))
			attach.append(pa)
		for i in pts.size() - 1:
			for k in n_wires:
				wires.append(
					catenary(
						attach[i][k], attach[i + 1][k], float(cfg.sag_ratio), int(cfg.wire_segments)
					)
				)
	return {"supports": supports, "wires": wires}


## Точки опор: узлы ближе min_span к предыдущей выкидываются, пролёты длиннее max_span делятся.
static func support_points(
	pts: PackedVector2Array, min_span: float, max_span: float
) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in pts.size():
		var p := pts[i]
		if out.is_empty():
			out.append(p)
			continue
		var last := out[out.size() - 1]
		var d := last.distance_to(p)
		if d < min_span and i < pts.size() - 1:
			continue
		var n := maxi(1, ceili(d / max_span))
		for k in range(1, n + 1):
			out.append(last.lerp(p, float(k) / n))
	return out


## Провод между точками подвеса: парабола, провисание в середине = sag_ratio · длина пролёта.
static func catenary(a: Vector3, b: Vector3, sag_ratio: float, segments: int) -> PackedVector3Array:
	var out := PackedVector3Array()
	var sag := sag_ratio * Vector2(b.x - a.x, b.z - a.z).length()
	for i in segments + 1:
		var t := float(i) / segments
		out.append(a.lerp(b, t) - Vector3.UP * (4.0 * sag * t * (1.0 - t)))
	return out
