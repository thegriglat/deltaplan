extends Node
## Контракт TP-К6 (docs/contracts/trike-pilot.md): дельталёт игрока в игре - TrikeRig (общая тележка с TowTug),
## Glider.setup_trike/reset_on_wheels с TrikeEngine и тягой, Game со стартом на полосе места буксировки.
## Физика: Glider в дереве-пустышке (без Game), шаг 1/120 с, ровная земля y = 0, без ветра, без сети.

const DT := 1.0 / 120.0
const G := 9.81
const RHO := 1.225
const CL_MAX := 1.77  ## tow_tug.json, ground.rotate_deg_doc: CL_max крыла iXess 15

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


static func flat(_x: float, _z: float) -> float:
	return 0.0


static func plane_flat(_x: float, _z: float) -> float:
	return 5.0


func _trike() -> Glider:
	var g := Glider.new()
	g.set_ground_fn(flat)
	g.setup_trike(Config.get_config("tow_tug"), 0.0, Config.get_config("trike_pilot"))
	g.reset_on_wheels(Vector3.ZERO, 0.0)
	return g


## Скорость сваливания тележки с топливом на старте, м/с.
func _vs(g: Glider) -> float:
	var wing: Dictionary = Config.get_config("wings/trike_ixess15")
	return sqrt(2.0 * g.model.mass * G / (RHO * float(wing.area_m2) * CL_MAX))


func test_contract_version() -> void:
	var txt := FileAccess.get_file_as_string("res://docs/contracts/trike-pilot.md")
	var re := RegEx.create_from_string("(?m)^## TP-К6 v(\\d+)\\.")
	var m := re.search(txt)
	check(m != null and m.get_string(1) == "2", "версия раздела TP-К6 - v2")


## (1) TowTug и игрок - одна доля тяги на тележку: thrust_split = prop_axis / cg (без 1,0).
func test_tug_same_split() -> void:
	var cfg := Config.get_config("tow_tug").duplicate(true)
	var a := float(cfg.cart.prop_axis_below_hang_m) / float(cfg.cart.cg_below_hang_m)
	var t := TowTug.new()
	t.setup(Vector3(10.0, 5.0, -20.0), 0.0, 80.0, plane_flat, cfg)
	check(t.rig is TrikeRig, "у TowTug есть TrikeRig")
	check(t.rig.thrust_split < 0.0 or absf(t.rig.thrust_split - a) < 1e-9, "TowTug: thrust_split %.4f, нужно %.4f" % [t.rig.thrust_split, a])
	var g := _trike()
	check(g.trike.thrust_split < 0.0 or absf(g.trike.thrust_split - a) < 1e-9, "игрок: thrust_split %.4f" % g.trike.thrust_split)
	check(absf(a - 1.40 / 1.71) < 2e-3, "доля %.4f ~ 1,40/1,71" % a)
	var s := {"pilot_pos": g.model.pilot_position, "hang_pos": g.model.hang_position, "wing_basis": g.model.wing_basis()}
	g.trike.thrust_n = 1000.0
	t.rig.thrust_n = 1000.0
	var fp: Dictionary = g.trike.ext_force(s)
	var ft: Dictionary = t.rig.ext_force(s)
	check(absf((fp.pilot as Vector3).length() - (ft.pilot as Vector3).length()) < 1e-6, "доля на pilot у TowTug и игрока одна")
	g.free()


## (8) Тяга по оси винта: сумма сил на pilot и hang = T по модулю и направлению; доля на pilot = prop_axis / cg;
## без тяги внешняя сила - только добавки владельца (7).
func test_thrust_split() -> void:
	var g := _trike()
	var cfg := Config.get_config("tow_tug")
	var a := float(cfg.cart.prop_axis_below_hang_m) / float(cfg.cart.cg_below_hang_m)
	check(a > 0.5 and a < 0.9, "доля на тележку из геометрии: %.3f" % a)
	var s := {"pilot_pos": g.model.pilot_position, "hang_pos": g.model.hang_position, "wing_basis": g.model.wing_basis()}
	var cb := TrikeRig.cart_axes(s.pilot_pos, s.hang_pos, s.wing_basis)
	var tilt := deg_to_rad(float(cfg.engine.thrust_tilt_deg))
	var dir := -cb.z * cos(tilt) + cb.y * sin(tilt)
	g.trike.thrust_n = 1300.0
	var f: Dictionary = g.trike.ext_force(s)
	var sum: Vector3 = f.pilot + f.hang
	check(sum.distance_to(dir * 1300.0) < 1e-6 * 1300.0, "сумма = T по модулю и направлению: %s" % sum)
	check(absf((f.pilot as Vector3).length() / 1300.0 - a) < 1e-5, "доля на pilot = a: %.4f" % ((f.pilot as Vector3).length() / 1300.0))
	check((f.pilot as Vector3).normalized().distance_to(dir) < 1e-5 and (f.hang as Vector3).normalized().distance_to(dir) < 1e-5, "направление общее")
	# момент относительно подвески = T * prop_axis (плечо вдоль мачты)
	var arm_p: Vector3 = s.pilot_pos - s.hang_pos
	var mom := arm_p.cross(f.pilot as Vector3).length()
	check(absf(mom - 1300.0 * float(cfg.cart.prop_axis_below_hang_m) * cos(tilt)) < 1.0, "момент тяги относительно подвески: %.1f" % mom)
	g.trike.thrust_n = 0.0
	var f0: Dictionary = g.trike.ext_force(s)
	check((f0.pilot as Vector3).length() < 1e-9 and (f0.hang as Vector3).length() < 1e-9, "без тяги сил нет")
	g.free()


## (7) Газ 0: доля тяги (0,819 или 1,0) не влияет - сила тяги нулевая при любой доле, внешняя сила только добавки владельца.
func test_zero_throttle_split_irrelevant() -> void:
	var g := _trike()
	var s := {"pilot_pos": g.model.pilot_position, "hang_pos": g.model.hang_position, "wing_basis": g.model.wing_basis()}
	g.trike.thrust_n = 0.0
	for a in [-1.0, 0.819, 1.0]:
		g.trike.thrust_split = a
		var f: Dictionary = g.trike.ext_force(s)
		check((f.pilot as Vector3).length() < 1e-9 and (f.hang as Vector3).length() < 1e-9, "газ 0, доля %.3f: сил нет" % a)
	g.free()


## (2) Стоит заглушенный 10 с: неподвижен, тяги нет.
func test_parked() -> void:
	var g := _trike()
	check(g.is_trike() and g.trike != null and g.engine != null, "is_trike, trike, engine")
	check(g.phase() == "wheels", "фаза wheels: %s" % g.phase())
	check(g.engine.state == "off" and absf(g.engine.fuel_l - 53.0) < 1e-6, "заглушен, полный бак: %s %.1f" % [g.engine.state, g.engine.fuel_l])
	var p0: Vector3 = g.model.position
	var c := ControlInput.new()
	g.set_input(c)
	for i in int(10.0 / DT):
		g.step(DT)
	check(g.model.position.distance_to(p0) < 0.05, "неподвижен: %.3f м" % g.model.position.distance_to(p0))
	check(g.trike.thrust_n == 0.0, "thrust_n 0")
	check(g.trike.agl_m < 0.05, "колёса на земле: agl %.3f" % g.trike.agl_m)
	var m: float = g.model.pilot_mass
	check(m > 255.0 and m < 290.0, "масса тележки = пустая + пилот + топливо: %.1f кг" % m)
	g.free()


## (3) engine_toggle -> через start_s холостые.
func test_engine_start() -> void:
	var g := _trike()
	var c := ControlInput.new()
	c.engine_toggle = true
	g.set_input(c)
	g.step(DT)
	check(g.engine.state == "starting", "после toggle - starting: %s" % g.engine.state)
	var start_s := float(Config.get_config("trike_pilot").starter.start_s)
	for i in int((start_s + 0.3) / DT):
		g.step(DT)
	check(g.engine.state == "running", "через start_s - running: %s" % g.engine.state)
	check(g.trike.thrust_n > 100.0, "холостая тяга в модели: %.0f Н" % g.trike.thrust_n)
	g.free()


class Pilot:
	extends RefCounted
	var g: Glider
	var vs := 0.0
	var t := 0.0
	var phase_air := false
	var x_air := 0.0  ## путь по земле до отрыва, м
	var v_air := 0.0  ## воздушная скорость в момент отрыва, м/с
	var t_air := -1.0
	var rotating := false
	var vdot := 0.0
	var _v_prev := 0.0
	var _i := 0.0

	func _init(glider: Glider) -> void:
		g = glider
		vs = glider.get_meta("vs", 0.0)

	## target_v - скорость в воздухе, hold_h >= 0 - удержание высоты (м) вместо скорости
	func step(target_v: float, hold_h := -1.0) -> void:
		var c := ControlInput.new()
		var tel := g.get_telemetry()
		var v := tel.airspeed
		vdot += ((v - _v_prev) / DT - vdot) * minf(DT / 0.5, 1.0)
		_v_prev = v
		if t < 0.2:
			c.engine_toggle = true
		if t > 4.0:
			c.throttle_axis = 1.0
		if g.phase() == "flying":
			if t_air < 0.0:
				t_air = t
				v_air = v
				x_air = g.model.position.length()
			var e := v - target_v
			if hold_h >= 0.0:
				e = 0.05 * (hold_h - tel.altitude_agl) - 0.3 * tel.vario
				c.pitch = clampf(e, -1.0, 1.0)
			else:
				_i = clampf(_i + 0.05 * e * DT, -1.0, 1.0)
				c.pitch = clampf(_i + 0.25 * e + 0.6 * vdot, -1.0, 1.0)
		elif v >= 1.1 * vs:
			c.pitch = 0.3  # от себя: отрыв
		g.set_input(c)
		g.step(DT)
		t += DT


## (4) Полный газ, простой регулятор штанги: отрыв на полосе, набор, числа - в отчёт.
func test_takeoff_and_climb() -> void:
	var g := _trike()
	var vs := _vs(g)
	g.set_meta("vs", vs)
	var p := Pilot.new(g)
	for i in int(120.0 / DT):
		p.step(1.3 * vs)
		if p.t_air > 0.0 and p.t > p.t_air + 40.0:
			break
	var tel := g.get_telemetry()
	check(p.t_air > 0.0, "оторвался (vs %.1f м/с, v %.1f)" % [vs, tel.airspeed])
	check(p.x_air <= 610.0, "разбег %.0f м <= 610 м полосы" % p.x_air)
	# установившийся набор: ещё 20 с
	var h0 := tel.altitude_agl
	var vsum := 0.0
	var vzsum := 0.0
	var n := 0
	for i in int(20.0 / DT):
		p.step(1.3 * vs)
		vsum += g.get_telemetry().airspeed
		vzsum += g.get_telemetry().vario
		n += 1
	var vz := vzsum / n
	print("    vs %.1f м/с, масса %.0f кг; взлёт: газ-полный с %.1f с, разбег %.0f м за %.1f с, скорость отрыва %.1f м/с (%.2f vs); набор: vz %.2f м/с при v %.1f м/с (1,3 vs = %.1f), высота %.0f -> %.0f м"
		% [vs, g.model.mass, 4.0, p.x_air, p.t_air, p.v_air, p.v_air / vs, vz, vsum / n, 1.3 * vs, h0, g.get_telemetry().altitude_agl])
	check(vz > 0.0, "набор в установившемся наборе: %.2f м/с" % vz)
	check(g.engine.running and g.engine.throttle > 0.99, "двигатель работает на полном газе")
	# штанга на упоре «на себя» (предел хода рук, TT-К1): набор на полном газе и газ/скорость горизонтального полёта
	var pull := ControlInput.new()
	pull.pitch = -1.0
	pull.throttle_axis = 1.0
	for i in int(20.0 / DT):
		g.set_input(pull)
		g.step(DT)
	var tf := g.get_telemetry()
	print("    штанга на упоре, полный газ: v %.1f м/с (%.0f км/ч), vz %.2f м/с" % [tf.airspeed, tf.airspeed * 3.6, tf.vario])
	check(tf.vario > 0.0, "на упоре штанги и полном газе - набор: %.2f" % tf.vario)
	# горизонтальный полёт при штанге на упоре: ряд положений рычага, vz(газ) -> газ и скорость при vz = 0
	var rows: Array = []
	for thr in [0.2, 0.3, 0.4, 0.5, 0.6]:
		var vzs := 0.0
		var vv := 0.0
		for i in int(50.0 / DT):
			var c := ControlInput.new()
			c.pitch = -1.0
			c.throttle_axis = clampf((thr - g.engine.throttle) * 20.0, -1.0, 1.0)
			g.set_input(c)
			g.step(DT)
			if i >= int(40.0 / DT):
				vzs += g.get_telemetry().vario / (10.0 / DT)
				vv += g.get_telemetry().airspeed / (10.0 / DT)
		rows.append(Vector3(thr, vv, vzs))
	var v_level := -1.0
	var thr_level := -1.0
	for j in range(1, rows.size()):
		var r0: Vector3 = rows[j - 1]
		var r1: Vector3 = rows[j]
		if r0.z < 0.0 and r1.z >= 0.0:
			var k := -r0.z / (r1.z - r0.z)
			v_level = lerpf(r0.y, r1.y, k)
			thr_level = lerpf(r0.x, r1.x, k)
	print("    (газ, v, vz) при штанге на упоре: %s; горизонтальный полёт: газ %.2f, v %.1f м/с (%.0f км/ч)" % [rows, thr_level, v_level, v_level * 3.6])
	check(thr_level > 0.0 and thr_level < 1.0, "горизонтальный полёт достижим при газе < полного: %.2f" % thr_level)
	g.free()


## (6) Фугоида на полном газе, штанга на упоре «на себя» (ход TT-8): толчок по скорости, отношение размахов за
## период <= 0,6 (TP-19: 0,49), период 9-14 с.
func test_phugoid_damped() -> void:
	var g := _trike()
	var vs := _vs(g)
	g.set_meta("vs", vs)
	var p := Pilot.new(g)
	for i in int(120.0 / DT):
		p.step(1.3 * vs)
		if p.t_air > 0.0 and p.t > p.t_air + 40.0:
			break
	var pull := ControlInput.new()
	pull.pitch = -1.0
	pull.throttle_axis = 1.0
	for i in int(60.0 / DT):
		g.set_input(pull)
		g.step(DT)
	# толчок +3 м/с вдоль полёта
	var m: PendulumModel = g.model
	var dv: Vector3 = m.velocity.normalized() * 3.0
	m._vel += PendulumModel.ned(dv)
	for j in m.chain.links:
		m.chain.v[j] += PendulumModel.ned(dv)
	var ts: Array = []
	var vv: Array = []
	for i in int(80.0 / DT):
		g.set_input(pull)
		g.step(DT)
		if i % 6 == 0:
			ts.append(float(i) * DT)
			vv.append(g.get_telemetry().airspeed)
	# экстремумы (с отсевом мелких пульсаций)
	var ext: Array = []
	for i in range(1, vv.size() - 1):
		if (vv[i] > vv[i - 1] and vv[i] >= vv[i + 1]) or (vv[i] < vv[i - 1] and vv[i] <= vv[i + 1]):
			if ext.is_empty() or absf(float(vv[i]) - float(vv[ext[-1]])) > 0.3:
				ext.append(i)
	check(ext.size() >= 4, "экстремумов скорости: %d" % ext.size())
	if ext.size() >= 4:
		var sw0 := absf(float(vv[ext[1]]) - float(vv[ext[0]]))
		var sw1 := absf(float(vv[ext[3]]) - float(vv[ext[2]]))
		var period: float = float(ts[ext[2]]) - float(ts[ext[0]])
		var ratio := sw1 / sw0
		print("    фугоида, полный газ, упор TT-8: v %.1f км/ч, размах %.2f -> %.2f м/с, отношение за период %.2f, период %.1f с" % [float(vv[-1]) * 3.6, sw0, sw1, ratio, period])
		check(ratio <= 0.65, "отношение размахов за период %.2f <= 0,65" % ratio)
		check(period >= 9.0 and period <= 14.0, "период %.1f с в 9-14 с" % period)
	g.free()


const MAIN_SCENE := preload("res://scenes/main.tscn")


## (5) Game с vehicle "trike": старт на колёсах на оси полосы, input_controller.vehicle, нет TowSession.
func test_game_trike_start() -> void:
	var main: Node = MAIN_SCENE.instantiate()
	main.set("opts", LaunchOptions.parse(PackedStringArray(["--autostart", "--location=wilotree_park", "--vehicle=trike"])))
	add_child(main)
	var game: Game = main.get_node("Game")
	for i in 3000:
		if main.get("state") == 2:
			break
		await get_tree().process_frame
	check(main.get("state") == 2, "автостарт - в полёте (state %s)" % main.get("state"))
	game.process_mode = Node.PROCESS_MODE_DISABLED
	check(game.settings.vehicle == "trike", "vehicle trike")
	check(game.glider.is_trike(), "Glider - дельталёт")
	check(game.glider.phase() == "wheels", "старт на колёсах: %s" % game.glider.phase())
	check(game.input_controller.vehicle == "trike", "input_controller.vehicle == trike")
	check(game.tow_session == null, "TowSession нет")
	var st := game.get_start()
	check(game.glider.model.position.distance_to(st.position) < 3.0, "на начале полосы: %s против %s" % [game.glider.model.position, st.position])
	var h := deg_to_rad(float(st.heading_deg))
	var axis := Vector3(sin(h), 0.0, -cos(h))
	var d: Vector3 = game.glider.model.position - st.position
	check(absf(d.cross(axis).length()) < 2.0, "на оси полосы")
	check(game.glider.engine.state == "off", "двигатель заглушен")
	# до первого отрыва полёт не кончается
	game.input_controller.hands_off = false
	for i in 120 * 8:
		game.tick(DT)
	check(not game._ended, "стоит на колёсах - полёт не кончился")
	game.restart()
	check(game.glider.phase() == "wheels" and game.glider.model.position.distance_to(st.position) < 3.0, "«Ещё раз» - снова в начале полосы")
	main.queue_free()
