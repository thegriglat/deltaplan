class_name Glider
extends Node3D
## Дельтаплан в сцене: держит FlightModel, шагает в _physics_process, двигает себя
## (с интерполяцией между шагами физики) и держит визуал GliderVisual (крыло + пилот).
##
## Интегратор: setup() → set_air_fn()/set_ground_fn() → reset_on_ground()/reset_in_air(),
## каждый шаг физики — set_input(ControlInput) (или менять поле control).
## Начало координат ноды — ноги пилота (точка касания земли); крыло выше.

signal telemetry_updated(t: Telemetry)
signal landed(result: Dictionary)
signal takeoff_failed(reason: String)
signal took_off

enum AutoStart { NONE, IN_AIR, ON_GROUND }

## Крыло по умолчанию: configs/wings/<wing_id>.json
@export var wing_id: String = "sport"
## Масса пилота, кг; 0 — из configs/pilot.json. Ограничивается диапазоном крыла.
@export var pilot_mass_kg: float = 0.0
## Что делать в _ready, если setup/reset не вызывали (для запуска сцены отдельно).
@export var auto_start: AutoStart = AutoStart.IN_AIR

var model := FlightModel.new()
var control := ControlInput.new()
var air_fn: Callable = Callable()
var ground_fn: Callable = Callable()
var visual: GliderVisual = null

var _configured := false
var _placed := false
var _prev_xform := Transform3D.IDENTITY
var _cur_xform := Transform3D.IDENTITY
var _vis: Dictionary = {}


func _ready() -> void:
	if not _configured:
		setup(wing_id, pilot_mass_kg)
	else:
		_build_visual()
	if not _placed:
		match auto_start:
			AutoStart.IN_AIR:
				reset_in_air(global_position, 0.0)
			AutoStart.ON_GROUND:
				reset_on_ground(global_position, 0.0)


## Выбрать крыло и массу пилота (≤0 — по умолчанию). Сбрасывает состояние: потом reset_*.
func setup(wing_name: String, mass_kg: float = 0.0) -> void:
	wing_id = wing_name
	var wing: Dictionary = Config.get_config("wings/" + wing_name)
	var pilot: Dictionary = Config.get_config("pilot").duplicate(true)
	var m := mass_kg if mass_kg > 0.0 else float(pilot.mass_kg)
	pilot.mass_kg = FlightModel.clamp_pilot_mass(wing, m)
	pilot_mass_kg = pilot.mass_kg
	model = FlightModel.new()
	model.setup(wing, pilot)
	model.landed.connect(func(r: Dictionary) -> void: landed.emit(r))
	model.takeoff_failed.connect(func(reason: String) -> void: takeoff_failed.emit(reason))
	model.took_off.connect(func() -> void: took_off.emit())
	_configured = true
	_vis = Config.get_config("flight").visual
	if is_node_ready():
		_build_visual()


func set_input(c: ControlInput) -> void:
	control = c


## f(pos: Vector3) -> Vector3 — скорость воздуха (ветер + вертикальные потоки), м/с.
func set_air_fn(f: Callable) -> void:
	air_fn = f


## f(x: float, z: float) -> float — высота земли над уровнем моря, м.
func set_ground_fn(f: Callable) -> void:
	ground_fn = f


## Пилот стоит на земле в точке pos лицом по курсу heading_deg (0 — север).
func reset_on_ground(pos: Vector3, heading_deg: float) -> void:
	if ground_fn.is_valid():
		pos.y = float(ground_fn.call(pos.x, pos.z))
	model.reset_on_ground(pos, heading_deg)
	_teleport()


## Старт в воздухе; airspeed_ms ≤ 0 — скорость трима. Ветер берётся из air_fn.
func reset_in_air(pos: Vector3, heading_deg: float, airspeed_ms: float = 0.0) -> void:
	var wind: Vector3 = air_fn.call(pos) if air_fn.is_valid() else Vector3.ZERO
	model.reset_in_air(pos, heading_deg, airspeed_ms, Vector3(wind.x, 0.0, wind.z))
	# телеметрия сразу с воздухом и рельефом: воздушная скорость и AGL верны до первого шага
	FlightTelemetry.fill(model, air_fn, ground_fn)
	_teleport()


func get_telemetry() -> Telemetry:
	return model.telemetry


## "standing", "walking", "running", "flying", "landed", "failed".
func phase() -> String:
	return model.phase()


## Маркер визуала по имени: "InstrumentMount" — сюда крепится прибор, "PilotHead" — глаза
## пилота (кабинная камера), "HangPoint", "BaseBar", "WingTipL", "WingTipR".
func get_marker(marker_name: String) -> Node3D:
	return visual.get_marker(marker_name) if visual != null else null


func _teleport() -> void:
	_placed = true
	_cur_xform = Transform3D(model.telemetry.basis, model.position)
	_prev_xform = _cur_xform
	if is_inside_tree():
		global_transform = _cur_xform
	telemetry_updated.emit(model.telemetry)


func _physics_process(dt: float) -> void:
	step(dt)


## Один шаг физики. Зовётся из _physics_process; если интегратор выключил его
## (set_physics_process(false)), он может шагать планер сам.
func step(dt: float) -> void:
	if not _configured:
		return
	model.step(dt, control, air_fn, ground_fn)
	_prev_xform = _cur_xform
	_cur_xform = Transform3D(model.telemetry.basis, model.position)
	if visual != null:
		visual.step_telltales(dt, _prev_xform.basis, _cur_xform, model.velocity, air_fn)
	telemetry_updated.emit(model.telemetry)


func _process(dt: float) -> void:
	var f := Engine.get_physics_interpolation_fraction()
	global_transform = _prev_xform.interpolate_with(_cur_xform, f)
	_update_pilot(dt)


func _build_visual() -> void:
	if visual != null:
		remove_child(visual)
		visual.queue_free()
		visual = null
	var path := String(_vis.get("scene", ""))
	var ps: PackedScene = load(path) if path != "" and ResourceLoader.exists(path) else null
	if ps != null:
		visual = ps.instantiate() as GliderVisual
	if visual == null:
		push_warning("Glider: нет сцены визуала %s — собираю заглушку" % path)
		visual = GliderVisual.new()
	visual.name = "Visual"
	add_child(visual)
	visual.build(model.wing, model.pilot, _vis)


func _update_pilot(dt: float) -> void:
	if visual != null:
		var flying := model.mode == FlightModel.Mode.AIR
		visual.set_pose(control.roll, control.pitch, flying, dt)
		# парус: болтанка — средний разброс перегрузки относительно configs/sail.json
		var full_g := float(Config.value("sail", "turbulence_full_g"))
		var turb := model.load.jitter / full_g
		visual.set_flight(model.telemetry.airspeed, model.stall_amount(), turb)
