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

## Всегда PendulumModel (RM-К1); общая поверхность с FlightModel — PD-К1.
var model = PendulumModel.new()
var control := ControlInput.new()
var air_fn: Callable = Callable()
var ground_fn: Callable = Callable()
var visual: GliderVisual = null
var _ext_fn: Callable = Callable()  ## TW-К4: внешняя сила (трос)
## TP-К6: дельталёт игрока (null у дельтаплана). Только чтение.
var trike: TrikeRig = null
var engine: TrikeEngine = null
var _trike_wheels: Dictionary = {}
## TP-К8: вид дельталёта (вместо GliderVisual, который тогда null). top_level: части ставятся в мировых координатах.
var trike_visual: TowTrikeVisual = null
var engine_sound_muted := false  ## TP-22: пауза/меню - звук двигателя игрока молчит
var _trike_engine_cfg: Dictionary = {}
var _trike_sound_cfg: Dictionary = {}
var _tv_prev: Array = []  ## [hang_pos, cart_quat, wing_quat] прошлого и текущего шага физики (интерполяция вида)
var _tv_cur: Array = []
var _link_t := 0.0  ## натяжение звена, Н (FlightModel)
var _link_warned := false

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
## Модель игрока — PendulumModel (apparatus — настройки «Аппарат», PD-К3).
func setup(wing_name: String, mass_kg: float = 0.0, apparatus: Dictionary = {}) -> void:
	if trike != null:  # снова дельтаплан: тяги тележки нет
		trike = null
		engine = null
		_ext_fn = Callable()
		_free_trike_visual()
	wing_id = wing_name
	var wing: Dictionary = Config.get_config("wings/" + wing_name)
	var pilot: Dictionary = Config.get_config("pilot").duplicate(true)
	var m := mass_kg if mass_kg > 0.0 else float(pilot.mass_kg)
	pilot.mass_kg = FlightModel.clamp_pilot_mass(wing, m)
	pilot_mass_kg = pilot.mass_kg
	model = PendulumModel.new()
	model.setup(wing, pilot, {}, apparatus)
	if _ext_fn.is_valid():
		model.set_external_force(_ext_fn)
	model.landed.connect(func(r: Dictionary) -> void: landed.emit(r))
	model.takeoff_failed.connect(func(reason: String) -> void: takeoff_failed.emit(reason))
	model.took_off.connect(func() -> void: took_off.emit())
	_configured = true
	_vis = Config.get_config("flight").visual
	if is_node_ready():
		_build_visual()


## TP-К6: дельталёт игрока. cfg - формат TT-К1 (configs/tow_tug.json), ops_cfg - TP-К1 (configs/trike_pilot.json).
## Масса тележки = пустая + пилот (pilot_mass_kg <= 0 - cart.pilot_mass_kg) + топливо на старте; расход топлива массу
## в полёте не меняет (граница модели, <= 40 кг из ~325 кг). Сбрасывает состояние: потом reset_on_wheels.
func setup_trike(cfg: Dictionary, pilot_mass_kg_: float, ops_cfg: Dictionary) -> void:
	var cart: Dictionary = cfg.cart
	engine = TrikeEngine.new()
	engine.setup(cfg.engine, cfg.thrust, ops_cfg)
	var pm := pilot_mass_kg_ if pilot_mass_kg_ > 0.0 else float(cart.pilot_mass_kg)
	pilot_mass_kg = pm
	wing_id = String(cfg.get("wing", TrikeRig.WING_DEFAULT))
	var mp := TrikeRig.model_params(cfg, float(cart.empty_mass_kg) + pm + engine.fuel_mass_kg)
	model = PendulumModel.new()
	model.setup(mp.wing, mp.pilot, {}, mp.apparatus)
	trike = TrikeRig.new()
	trike.terrain = func(x: float, z: float) -> float:
		return float(ground_fn.call(x, z)) if ground_fn.is_valid() else 0.0
	trike.setup(model, cfg)
	_trike_wheels = cfg.ground.duplicate(true)
	_trike_wheels.merge(ops_cfg.get("wheels", {}), true)
	_trike_wheels["land_on_wheels"] = true
	_trike_engine_cfg = cfg.engine
	_trike_sound_cfg = ops_cfg.get("sound", {})
	_ext_fn = trike.ext_force
	model.set_external_force(_ext_fn)
	model.landed.connect(func(r: Dictionary) -> void: landed.emit(r))
	model.takeoff_failed.connect(func(reason: String) -> void: takeoff_failed.emit(reason))
	model.took_off.connect(func() -> void: took_off.emit())
	_configured = true
	_vis = Config.get_config("flight").visual
	if is_node_ready():
		_build_visual()


func is_trike() -> bool:
	return trike != null


## TP-К6: дельталёт на колёсах в точке pos (земля под ЦМ тележки), курс heading_deg; двигатель заглушен, бак полный.
func reset_on_wheels(pos: Vector3, heading_deg: float) -> void:
	if trike == null:
		push_warning("Glider: reset_on_wheels без setup_trike - старт на ногах")
		reset_on_ground(pos, heading_deg)
		return
	if ground_fn.is_valid():
		pos.y = float(ground_fn.call(pos.x, pos.z))
	model.reset_on_wheels(pos, heading_deg, _trike_wheels)
	engine.reset()
	trike.thrust_n = 0.0
	trike.refresh(0.0)
	_tv_cur = _trike_state()
	_tv_prev = _tv_cur
	_teleport()


## Сейчас модель — PendulumModel.
func is_pendulum() -> bool:
	return model is PendulumModel


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


## TW-К10: старт с тележки (только «Маятник»): крыло в ложементе, пилот в лётном положении, связка катится
## по земле под тягой троса до отрыва (took_off), phase() "dolly". dolly — configs/tow_dolly.json (пусто —
## целиком из файла). В FlightModel тележки нет: push_warning и обычный старт на ногах.
func reset_on_dolly(pos: Vector3, heading_deg: float, dolly: Dictionary = {}) -> void:
	if not (model is PendulumModel):
		push_warning("Glider: тележка есть только в «Маятнике» (TW-К10) — старт на ногах")
		reset_on_ground(pos, heading_deg)
		return
	if ground_fn.is_valid():
		pos.y = float(ground_fn.call(pos.x, pos.z))
	model.reset_on_dolly(pos, heading_deg, dolly)
	_teleport()


## Тележка после отрыва (TW-К10): положение и скорость на земле, мир игры; пока крыло в ложементе —
## dolly_attached. FlightModel — нули.
func dolly_pos() -> Vector3:
	return model.dolly_pos if model is PendulumModel else Vector3.ZERO


func dolly_vel() -> Vector3:
	return model.dolly_vel if model is PendulumModel else Vector3.ZERO


func dolly_attached() -> bool:
	return model is PendulumModel and model.dolly_attached


## Старт в воздухе; airspeed_ms ≤ 0 — скорость трима. Ветер берётся из air_fn.
func reset_in_air(pos: Vector3, heading_deg: float, airspeed_ms: float = 0.0) -> void:
	var wind: Vector3 = air_fn.call(pos) if air_fn.is_valid() else Vector3.ZERO
	model.reset_in_air(pos, heading_deg, airspeed_ms, Vector3(wind.x, 0.0, wind.z))
	# телеметрия сразу с воздухом и рельефом: воздушная скорость и AGL верны до первого шага
	FlightTelemetry.fill(model, air_fn, ground_fn)
	_teleport()


## Кинематика без физики («догнать», NET-42): крыло в pos с ориентацией basis, скорость vel
## над землёй, курс и крен, рад; режим — «в воздухе» (поза полёта). flow_speed ≥ 0 — воздушная
## скорость в телеметрии (звук потока: на буксире — с потолком). Физику зовущий не шагает;
## вернуть — reset_in_air/reset_on_ground.
func set_kinematic(
	pos: Vector3, vel: Vector3, heading: float, bank: float, basis: Basis, flow_speed := -1.0
) -> void:
	if is_pendulum():
		model.set_kinematic(pos, vel, heading, bank, 0.0)
		FlightTelemetry.fill(model, air_fn, ground_fn)
		var tp: Telemetry = model.telemetry
		tp.basis = basis
		if flow_speed >= 0.0:
			tp.airspeed = flow_speed
		_placed = true
		_prev_xform = _cur_xform
		_cur_xform = Transform3D(basis, pos)
		telemetry_updated.emit(tp)
		return
	model.mode = FlightModel.Mode.AIR
	model.position = pos
	model.velocity = vel
	model.heading = heading
	model.bank = bank
	model.theta = 0.0
	model.roll_rate = 0.0
	model.stalled = false
	FlightTelemetry.fill(model, air_fn, ground_fn)
	var t: Telemetry = model.telemetry
	t.basis = basis
	if flow_speed >= 0.0:
		t.airspeed = flow_speed
	_placed = true
	_prev_xform = _cur_xform
	_cur_xform = Transform3D(basis, pos)
	telemetry_updated.emit(t)


func get_telemetry() -> Telemetry:
	return model.telemetry


## "standing", "walking", "running", "flying", "landed", "failed".
func phase() -> String:
	return model.phase()


## Маркер визуала по имени: "InstrumentMount" — сюда крепится прибор, "PilotHead" — глаза
## пилота (кабинная камера), "HangPoint", "BaseBar", "WingTipL", "WingTipR".
func get_marker(marker_name: String) -> Node3D:
	if trike_visual != null:
		return trike_visual.get_marker(marker_name)
	return visual.get_marker(marker_name) if visual != null else null


func _teleport() -> void:
	_placed = true
	_cur_xform = Transform3D(model.telemetry.basis, model.position)
	_prev_xform = _cur_xform
	if is_inside_tree():
		global_transform = _cur_xform
	telemetry_updated.emit(model.telemetry)


## TW-К4: внешняя сила (трос). fn(s: Dictionary) -> {"pilot": Vector3, "hang": Vector3}, Н, мир игры
## (вход и выход — в docs/contracts/tow.md). «Маятник» зовёт fn на каждом подшаге; FlightModel
## (weight_shift/rate) — раз в шаг физики, с позицией и скоростью ЦМ, и кладёт pilot + hang в external_force;
## звено link в FlightModel игнорируется (push_warning), в «Маятнике» — неявное XPBD-звено модели.
func set_external_force(fn: Callable) -> void:
	_ext_fn = fn
	if model is PendulumModel:
		model.set_external_force(fn)
	elif not fn.is_valid():
		model.external_force = Vector3.ZERO
		_link_t = 0.0


func clear_external_force() -> void:
	set_external_force(Callable())


func _step_external_force(dt: float) -> void:
	var s := {
		"t": model.time_s, "h": dt, "pilot_pos": model.position, "pilot_vel": model.velocity,
		"hang_pos": model.position, "hang_vel": model.velocity,
		"on_ground": model.mode == FlightModel.Mode.GROUND,
		"wing_basis": model.telemetry.basis, "link_tension_n": _link_t,
	}
	var r = _ext_fn.call(s)
	var f := Vector3.ZERO
	_link_t = 0.0
	if r is Dictionary:
		for k: String in ["pilot", "hang"]:
			var v = r.get(k, Vector3.ZERO)
			if v is Vector3 and is_finite(v.x) and is_finite(v.y) and is_finite(v.z):
				f += v
		if r.get("link") is Dictionary and not _link_warned:
			_link_warned = true
			push_warning("Glider: звено link в FlightModel не поддержано — буксировка только в «Маятнике» (TW-К4)")
	model.external_force = f


## TW-К4: натяжение звена (Н) на последнем шаге; «Маятник» — из модели.
func link_tension_n() -> float:
	if model is PendulumModel:
		return model.link_tension_n
	return _link_t


func _physics_process(dt: float) -> void:
	step(dt)


## Один шаг физики. Зовётся из _physics_process; если интегратор выключил его
## (set_physics_process(false)), он может шагать планер сам.
func step(dt: float) -> void:
	if not _configured:
		return
	if _ext_fn.is_valid() and not (model is PendulumModel):
		_step_external_force(dt)
	if trike != null:
		engine.step(dt, model.telemetry.airspeed, control.throttle_axis, control.engine_toggle)
		control.engine_toggle = false  # нажатие - на один шаг
		trike.thrust_n = engine.thrust_n
	model.step(dt, control, air_fn, ground_fn)
	if trike != null:
		trike.refresh(dt)
		_tv_prev = _tv_cur
		_tv_cur = _trike_state()
	_prev_xform = _cur_xform
	_cur_xform = Transform3D(model.telemetry.basis, model.position)
	if visual != null:
		visual.step_telltales(dt, _prev_xform.basis, _cur_xform, model.velocity, air_fn)
	telemetry_updated.emit(model.telemetry)


func _process(dt: float) -> void:
	var f := Engine.get_physics_interpolation_fraction()
	global_transform = _prev_xform.interpolate_with(_cur_xform, f)
	_update_pilot(dt)
	_update_trike_visual(f)


## Пауза и меню (TP-22): звук двигателя игрока молчит; после снятия - снова по состоянию двигателя.
func set_engine_sound_muted(on: bool) -> void:
	engine_sound_muted = on
	if on and trike_visual != null and trike_visual.sound != null and trike_visual.sound.playing:
		trike_visual.sound.stop()


func _trike_state() -> Array:
	return [trike.hang_pos, trike.cart_basis.get_rotation_quaternion(), trike.wing_basis.get_rotation_quaternion()]


func _free_trike_visual() -> void:
	if trike_visual != null:
		remove_child(trike_visual)
		trike_visual.queue_free()
		trike_visual = null


## TP-К8: части вида - по интерполированному состоянию TrikeRig; звук - по состоянию двигателя (TP-К9).
func _update_trike_visual(f: float) -> void:
	if trike_visual == null or trike == null or _tv_cur.is_empty():
		return
	var hp: Vector3 = (_tv_prev[0] as Vector3).lerp(_tv_cur[0], f)
	var cq: Quaternion = (_tv_prev[1] as Quaternion).slerp(_tv_cur[1], f)
	var wq: Quaternion = (_tv_prev[2] as Quaternion).slerp(_tv_cur[2], f)
	trike_visual.update_parts(hp, Basis(cq), Basis(wq), engine.prop_rpm, engine.throttle)
	if trike_visual.sound != null and not engine_sound_muted:
		trike_visual.sound.update_engine(engine.state, engine.prop_rpm, engine.throttle)


func _build_visual() -> void:
	if visual != null:
		remove_child(visual)
		visual.queue_free()
		visual = null
	_free_trike_visual()
	if trike != null:
		trike_visual = TowTrikeVisual.new()
		trike_visual.name = "TrikeVisual"
		trike_visual.top_level = true
		add_child(trike_visual)
		trike_visual.setup(_trike_engine_cfg, false)
		trike_visual.setup_player_sound(_trike_engine_cfg, _trike_sound_cfg)
		if not _tv_cur.is_empty():
			_update_trike_visual(1.0)
		return
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
		# "wheels" - наземная фаза (у дельталёта visual == null, ветка до него не доходит)
		var flying: bool = model.mode == FlightModel.Mode.AIR or model.phase() == "dolly"
		if is_pendulum():
			visual.set_hang_pose(model.pilot_rel, not flying, dt)  # PD-К5: тело по цепи маятника
		else:
			visual.set_pose(control.roll, control.pitch, flying, dt)
		# парус: болтанка — средний разброс перегрузки относительно configs/sail.json
		var full_g := float(Config.value("sail", "turbulence_full_g"))
		var turb: float = model.load.jitter / full_g
		visual.set_flight(model.telemetry.airspeed, model.stall_amount(), turb)
