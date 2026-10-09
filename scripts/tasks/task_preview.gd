extends Node2D
## Превью задания: цилиндры, линия гоула и оптимизированный маршрут в плане (север вверху).
## godot --path . res://scenes/tasks/task_preview.tscn -- [--task=<id>|--file=<путь .xctsk>]
## [--shot=file.png]. Центр локации — из configs/locations/<task.location>.json.

const COLORS := {
	"cylinder": Color(0.2, 0.5, 0.9),
	"route": Color(0.9, 0.3, 0.1),
	"text": Color(0.1, 0.1, 0.1),
	"bg": Color(0.96, 0.95, 0.9),
}
const MARGIN_PX := 40.0
const FONT_PX := 14

var task: Task
var route := PackedVector2Array()
var origin := Vector2.ZERO
var _scale := 1.0
var _offset := Vector2.ZERO


func _ready() -> void:
	var args := _args()
	var loc_center := Callable()
	var task_id := String(args.get("task", "ongudai_demo"))
	var raw: Dictionary = {}
	if args.has("file"):
		task = Task.load_file(String(args.file))
		if task != null:
			loc_center = _latlon_for(task.location)
			task = Task.load_file(String(args.file), loc_center)
	else:
		raw = Config.get_config("tasks/" + task_id)
		loc_center = _latlon_for(String(raw.get("location", "")))
		if not loc_center.is_valid() and not raw.get("turnpoints", []).is_empty():
			var first: Dictionary = raw.turnpoints[0]  # нет локации — центр на первом пункте
			loc_center = _centered(float(first.get("lat", 0.0)), float(first.get("lon", 0.0)))
		task = Task.load_config(task_id, loc_center)
	if task == null or task.points.is_empty():
		push_error("TaskPreview: задание не загружено")
		return
	var from_i := maxi(task.takeoff_index, 0)
	origin = task.points[from_i].center_2d()
	var r := RouteOptimizer.from_settings().solve(origin, task.route_targets(from_i + 1))
	route = r.points
	print("%s: %.2f км, ошибки: %s" % [task.name, float(r.distance_m) / 1000.0, task.errors])
	_fit()
	queue_redraw()
	if args.has("shot"):
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(String(args.shot))
		get_tree().quit()


func _draw() -> void:
	draw_rect(get_viewport_rect(), COLORS.bg)
	if task == null:
		return
	var font := ThemeDB.fallback_font
	for i in task.points.size():
		var p := task.points[i]
		var c := _to_px(p.center_2d())
		if p.kind == TaskPoint.Kind.GOAL and p.is_line:
			var e := p.line_ends(task.leg_direction(i))
			draw_line(_to_px(e[0]), _to_px(e[1]), COLORS.cylinder, 3.0)
		else:
			draw_arc(c, p.radius_m * _scale, 0.0, TAU, 96, COLORS.cylinder, 2.0)
		var label := "%d %s" % [i, p.name]
		draw_string(
			font, c + Vector2(6, -6), label, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_PX, COLORS.text
		)
	var prev := _to_px(origin)
	for q in route:
		draw_line(prev, _to_px(q), COLORS.route, 2.0)
		prev = _to_px(q)


func _to_px(p: Vector2) -> Vector2:
	return p * _scale + _offset


func _fit() -> void:
	var box := Rect2(origin, Vector2.ZERO)
	for p in task.points:
		box = box.expand(p.center_2d() - Vector2.ONE * p.radius_m)
		box = box.expand(p.center_2d() + Vector2.ONE * p.radius_m)
	var view := get_viewport_rect().size - Vector2.ONE * MARGIN_PX * 2.0
	_scale = minf(view.x / maxf(box.size.x, 1.0), view.y / maxf(box.size.y, 1.0))
	_offset = Vector2.ONE * MARGIN_PX - box.position * _scale


static func _latlon_for(location: String) -> Callable:
	if location == "" or not Locations.exists(location):
		return Callable()
	var loc: Dictionary = Locations.config(location)
	return _centered(float(loc.center_lat), float(loc.center_lon))


static func _centered(lat0: float, lon0: float) -> Callable:
	return func(lat: float, lon: float) -> Vector2:
		return TerrainGeo.latlon_to_local(lat, lon, lat0, lon0)


static func _args() -> Dictionary:
	var out := {}
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--") and a.contains("="):
			out[a.substr(2, a.find("=") - 2)] = a.substr(a.find("=") + 1)
	return out
