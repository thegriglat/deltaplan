class_name TowSession
extends Node3D
## Буксировка со статической лебёдки в игре (TW-10, docs/contracts/tow.md → TW-К5/К6/К7/К8): трос TowLine,
## лебёдка в конце полосы, отцеп на пилоте, трос с куполом после отцепа. Шаг — раз в шаг физики до glider.step.
## Старт по W (start_pressed): до этого трос лежит, натяжения нет. Отцеп — release_pressed или обрыв слабого звена.
## Модель границ: воздух для троса неподвижен, лебёдка не двигается (TowLine); визуал отцепа — на положении
## пилота (pilot_position модели), а не на кости подвески.

const WINCH := "res://assets/models/world/tow_winch.glb"
const RELEASE := "res://assets/models/world/tow_release.glb"
const DROGUE := "res://assets/models/world/tow_drogue.glb"
## Высота отцепа над лебёдкой — доля длины троса: ≈35 % при безветрии (docs/research/tow/kinds.md#Параметры, [10]).
const RELEASE_FRACTION := 0.35

var glider: Glider
var line: TowLine
var kind := "winch_static"
var rope_view := TowRopeView.new()
var winch_node: Node3D
var release_node: Node3D
var drogue_node: Node3D
## Позиция лебёдки и якорь троса (мир), курс полосы.
var winch_pos := Vector3.ZERO
var anchor_pos := Vector3.ZERO
var heading_deg := 0.0
var ended_reason := ""  ## "" | "pilot" | "broken" | …

var _ground_fn: Callable
var _start_pos := Vector3.ZERO
var _rope_len := 0.0
var _detached := false
var _rel_basis := Basis.IDENTITY
var _drogue_basis := Basis.IDENTITY
var _rope_out := Vector3(0.0, 1.5, 0.0)  ## точка выхода троса в осях модели лебёдки


## site — результат TowSite.check (start_pos, end_pos, heading_deg). Длина троса — min(rope_length_m, длина полосы).
func setup(glider_: Glider, ground_fn: Callable, site: Dictionary, kind_: String = "winch_static", models := true) -> void:
	glider = glider_
	_ground_fn = ground_fn
	kind = kind_
	_start_pos = site.start_pos
	heading_deg = float(site.heading_deg)
	var runway := Vector2(site.end_pos.x - _start_pos.x, site.end_pos.z - _start_pos.z).length()
	var cfg: Dictionary = Config.get_config("tow").get(kind_, {})
	_rope_len = minf(float(cfg.get("rope_length_m", runway)), runway)
	var h := deg_to_rad(heading_deg)
	var dir := Vector3(sin(h), 0.0, -cos(h))
	winch_pos = _start_pos + dir * _rope_len
	winch_pos.y = float(ground_fn.call(winch_pos.x, winch_pos.z))
	add_child(rope_view)
	if models:
		_build_models(dir)
	anchor_pos = winch_pos + _rope_out_world()
	reset()


func _rope_out_world() -> Vector3:
	if winch_node == null:
		return _rope_out
	return winch_node.transform.basis * _rope_out


func _build_models(dir: Vector3) -> void:
	winch_node = _load(WINCH, [60.0, 250.0])
	if winch_node != null:
		winch_node.transform = Transform3D(_look(-dir), winch_pos)
		var out := winch_node.find_child("tow_winch_rope_out", true, false) as Node3D
		if out != null:
			_rope_out = out.transform.origin
			var p := out.get_parent()
			while p != null and p != winch_node:
				if p is Node3D:
					_rope_out = (p as Node3D).transform * _rope_out
				p = p.get_parent()
		add_child(winch_node)
	release_node = _load(RELEASE, [20.0])
	if release_node != null:
		release_node.visible = false
		add_child(release_node)
	drogue_node = _load(DROGUE, [30.0, 100.0])
	if drogue_node != null:
		drogue_node.visible = false
		add_child(drogue_node)


## Модель .glb с LOD-узлами `<имя>_LOD<k>`: дальности видимости — из ranges (м, граница k → k+1).
func _load(path: String, ranges: Array) -> Node3D:
	if not ResourceLoader.exists(path):
		push_warning("TowSession: нет модели " + path)
		return null
	var ps := load(path) as PackedScene
	var n := ps.instantiate() as Node3D if ps != null else null
	if n == null:
		return null
	var base := path.get_file().get_basename()
	for k in 3:
		var lod := n.find_child("%s_LOD%d" % [base, k], true, false) as GeometryInstance3D
		if lod == null:
			continue
		lod.visibility_range_begin = 0.0 if k == 0 else float(ranges[k - 1])
		lod.visibility_range_end = float(ranges[k]) if k < ranges.size() else 0.0
	return n


## Новый трос (лежит, ждёт W): старт полёта и «Ещё раз».
func reset() -> void:
	_detached = false
	ended_reason = ""
	line = TowLine.create(kind, anchor_pos)
	line.ground_fn = _ground_fn
	if glider != null:
		glider.set_external_force(line.force_fn())
	if release_node != null:
		release_node.visible = true
	if drogue_node != null:
		drogue_node.visible = false


## Длина троса, м (min(rope_length_m, длина полосы)).
func rope_length_m() -> float:
	return _rope_len


## Высота отцепа над стартом для ботов, м (доля длины троса).
func release_height_m() -> float:
	return RELEASE_FRACTION * _rope_len


## Сила троса сейчас приложена к пилоту.
func is_attached() -> bool:
	return line != null and not _detached and line.state != "released" and line.state != "broken"


## Один шаг физики, до glider.step. start_pressed — W (на земле, один раз), release_pressed — отцеп.
func step(dt: float, start_pressed := false, release_pressed := false) -> void:
	if line == null:
		return
	if start_pressed and glider != null and glider.phase() in ["standing", "walking", "running"]:
		line.start()
	if release_pressed and is_attached():
		line.release("pilot")
	if not _detached and (line.state == "released" or line.state == "broken"):
		_detached = true
		ended_reason = "pilot" if line.state == "released" else "broken"
		if glider != null:
			glider.clear_external_force()
		if drogue_node != null:
			drogue_node.visible = true
	if _detached and not line.reeled_in:
		line.step_free(dt)


func _process(_dt: float) -> void:
	if line == null:
		return
	rope_view.update(line.points(TowRopeView.POINTS))
	_place_release()
	_place_drogue()


func _place_release() -> void:
	if release_node == null or glider == null:
		return
	var m: Variant = glider.model
	if not ("pilot_position" in m):
		return
	var p: Vector3 = m.pilot_position
	if is_attached():
		var pts := line.points(2)
		if pts.size() == 2 and pts[0].distance_to(pts[1]) > 0.1:
			_rel_basis = _look((pts[1] - pts[0]).normalized())
	release_node.transform = Transform3D(_rel_basis, p)


func _place_drogue() -> void:
	if drogue_node == null or not _detached:
		return
	drogue_node.visible = not line.reeled_in
	if line.end_vel.length() > 0.5:
		_drogue_basis = _look(line.end_vel.normalized())
	drogue_node.transform = Transform3D(_drogue_basis, line.end_pos)


## Базис, у которого −Z смотрит по dir (верх — вверх, у вертикали — иначе).
static func _look(dir: Vector3) -> Basis:
	var up := Vector3.UP if absf(dir.y) < 0.99 else Vector3.FORWARD
	return Basis.looking_at(dir, up)
