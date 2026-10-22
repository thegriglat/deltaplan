class_name TowSession
extends Node3D
## Буксировка в игре (TW-10, TW-10b; docs/contracts/tow.md → TW-К5/К6/К7/К8/К9/К10): трос TowLine, отцеп на пилоте.
## winch_static — лебёдка в конце полосы, трос с куполом после отцепа. aerotow — пилот лежит на тележке (К10) в начале
## полосы, буксировщик-дельталёт (TowTug, TT-К4) впереди на длину троса; по W буксировщик выбирает слабину и разгоняется, крыло
## отрывается с тележки, тележка остаётся на полосе; после отцепа буксировщик уходит (через away_s модель убирается).
## Шаг — раз в шаг физики до glider.step. Старт по W (start_pressed): до этого трос лежит, натяжения нет.
## Отцеп — release_pressed или обрыв слабого звена.
## Модель границ: воздух для троса неподвижен, лебёдка не двигается (TowLine); визуал отцепа — на положении
## пилота (pilot_position модели), а не на кости подвески. Ан-2 — кинематика (честно: так медленно он не летает,
## струи винта нет); высота дельтаплана для буксировщика — высота основания перекладины над землёй, считается
## от пилота: cradle_height_m + подъём пилота над стоянкой (при смене позы на лёгкое ±0,5 м неточна).

const WINCH := "res://assets/models/world/tow_winch.glb"
const RELEASE := "res://assets/models/world/tow_release.glb"
const DROGUE := "res://assets/models/world/tow_drogue.glb"
const DOLLY := "res://assets/models/world/tow_dolly.glb"

var glider: Glider
var line: TowLine
var kind := "winch_static"
var rope_view := TowRopeView.new()
var winch_node: Node3D
var release_node: Node3D
var drogue_node: Node3D
## aerotow: буксировщик, его модель, модель тележки.
var tug: TowTug
var tug_node: Node3D
var dolly_node: Node3D
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
var _tug_sound: AudioStreamPlayer3D
var _rest_rel := 0.0  ## высота пилота над землёй на тележке в покое
var _cradle_h := 0.4
var _tail_h := 1.5
var _dolly_basis := Basis.IDENTITY


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
	if is_aerotow():
		_cradle_h = float(Config.get_config("tow_dolly").get("cradle_height_m", 0.4))
		_tail_h = 1.5  # модель Ан-2 (пасхалка) стоит хвостом на tow_hook; вид дельталёта - TT-5
		tug = TowTug.new()
		tug.setup(_start_pos, heading_deg, _rope_len, ground_fn)
		if models:
			_build_aerotow_models()
		anchor_pos = tug.pos
	else:
		if models:
			_build_models(dir)
		anchor_pos = winch_pos + _rope_out_world()
	reset()


func is_aerotow() -> bool:
	return kind == "aerotow"


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


func _build_aerotow_models() -> void:
	dolly_node = _load(DOLLY, [30.0, 100.0])
	if dolly_node != null:
		add_child(dolly_node)
	release_node = _load(RELEASE, [20.0])
	if release_node != null:
		release_node.visible = false
		add_child(release_node)
	tug_node = EggAn2.build_model(0)
	add_child(tug_node)
	_tug_sound = AudioStreamPlayer3D.new()  # мотор АШ-62ИР из пасхалки; винт не вращается, струи нет
	_tug_sound.stream = EggAn2.engine_sound()
	_tug_sound.bus = "Ambient" if AudioServer.get_bus_index("Ambient") >= 0 else "Master"
	_tug_sound.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	_tug_sound.unit_size = 30.0
	_tug_sound.max_distance = 1500.0
	_tug_sound.attenuation_filter_cutoff_hz = 5000.0
	_tug_sound.doppler_tracking = AudioStreamPlayer3D.DOPPLER_TRACKING_IDLE_STEP
	_tug_sound.autoplay = true
	tug_node.add_child(_tug_sound)


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
	if is_aerotow():
		tug.setup(_start_pos, heading_deg, _rope_len, _ground_fn)
		anchor_pos = tug.pos
		var slack := float(Config.get_config("tow").get("aerotow", {}).get("slack_m", 0.0))
		line = TowLine.create(kind, anchor_pos, {"aerotow": {"rope_length_m": _rope_len + slack}})
		if glider != null:
			glider.reset_on_dolly(_start_pos, heading_deg)
			var p: Vector3 = glider.model.pilot_position
			_rest_rel = p.y - float(_ground_fn.call(p.x, p.z))
		if tug_node != null:
			tug_node.visible = true
			if _tug_sound != null and _tug_sound.is_inside_tree():
				_tug_sound.play()
		if dolly_node != null:
			dolly_node.visible = true
	else:
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


## Высота отцепа над стартом для ботов, м: winch_static — доля длины троса, aerotow — высота первого буксира.
func release_height_m() -> float:
	var cfg: Dictionary = Config.get_config("tow").get(kind, {})
	if is_aerotow():
		return float(cfg.get("release_height_m", 300.0))
	return float(cfg.get("release_height_frac", 0.35)) * _rope_len


## Высота основания перекладины над землёй, м (для буксировщика): на тележке — cradle_height_m, дальше + подъём пилота.
func glider_agl_m() -> float:
	if glider == null:
		return 0.0
	var p: Vector3 = glider.model.pilot_position
	return maxf(_cradle_h + (p.y - float(_ground_fn.call(p.x, p.z))) - _rest_rel, 0.0)


## Сила троса сейчас приложена к пилоту.
func is_attached() -> bool:
	return line != null and not _detached and line.state != "released" and line.state != "broken"


## Один шаг физики, до glider.step. start_pressed — W (на земле, один раз), release_pressed — отцеп.
func step(dt: float, start_pressed := false, release_pressed := false) -> void:
	if line == null:
		return
	if start_pressed and glider != null and glider.phase() in ["standing", "walking", "running", "dolly"]:
		line.start()
		if tug != null:
			tug.start()
	if release_pressed and is_attached():
		line.release("pilot")
	if not _detached and (line.state == "released" or line.state == "broken"):
		_detached = true
		ended_reason = "pilot" if line.state == "released" else "broken"
		if glider != null:
			glider.clear_external_force()
		if tug != null:
			tug.release()
		elif drogue_node != null:
			drogue_node.visible = true
	if tug != null:
		tug.set_air(glider.air_fn if glider != null else Callable())
		var pull := Vector3.ZERO
		if not _detached and glider != null and line.tension_n > 0.0:
			# сила троса на буксировщик: натяжение к точке крепления на дельтаплане (пилот, TowLine attach)
			pull = line.tension_n * (glider.model.pilot_position - tug.pos).normalized()
		tug.set_rope_force(pull)
		tug.step(dt, glider_agl_m())
		line.anchor_pos = tug.pos
		line.anchor_vel = tug.vel
		if tug.gone and tug_node != null and tug_node.visible:
			tug_node.visible = false
			if _tug_sound != null:
				_tug_sound.stop()
	if _detached and not line.reeled_in and not (tug != null and tug.gone):
		line.step_free(dt)


func _process(_dt: float) -> void:
	if line == null:
		return
	var gone := tug != null and tug.gone
	rope_view.update(PackedVector3Array() if gone else line.points(TowRopeView.POINTS))
	_place_release()
	_place_drogue()
	if tug != null:
		_place_aerotow()


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


## Ан-2: хвост модели — в точке троса tug.pos, колёса — на tail_height_m ниже её; тележка — на земле под перекладиной.
func _place_aerotow() -> void:
	if tug_node != null:
		var b := tug.basis
		var tail := Vector3(0.0, EggAn2.GEAR_BOTTOM_Y + _tail_h, EggAn2.TAIL_Z)
		tug_node.transform = Transform3D(b, tug.pos - b * tail)
	if dolly_node != null and glider != null:
		var p := glider.dolly_pos()
		var f := Vector3(sin(deg_to_rad(heading_deg)), 0.0, -cos(deg_to_rad(heading_deg)))
		var ahead := float(_ground_fn.call(p.x + f.x, p.z + f.z)) - float(_ground_fn.call(p.x - f.x, p.z - f.z))
		_dolly_basis = _look((f * 2.0 + Vector3(0.0, ahead, 0.0)).normalized())
		dolly_node.transform = Transform3D(_dolly_basis, p)


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
