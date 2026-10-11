extends Node
## Диагностика MR-6: появление на земле и разбег глазами SRS. Поднимает сцену полёта (как test_motion_gate),
## шагает Game.tick() вручную и каждый шаг физики считает MotionSource (те же величины, что шли в пакет),
## пакеты — каждые 2 шага (60 Гц). Печатает сводку по первым SPAWN_S секундам и по разбегу, пишет csv.
## godot --headless --path . res://tools/motion_rig/diag_spawn.tscn -- [csv_путь] [секунд_разбега] [место]

const DT := 1.0 / 120.0
const MAIN_SCENE := preload("res://scenes/main.tscn")
const SPAWN_S := 3.0
const EVERY := 2

var _rows: Array = []


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var csv_path := args[0] if args.size() > 0 else ""
	var run_s := float(args[1]) if args.size() > 1 else 25.0
	var main: Node = MAIN_SCENE.instantiate()
	add_child(main)
	var game: Game = main.get_node("Game")
	await main.call("load_menu_world")
	game.process_mode = Node.PROCESS_MODE_DISABLED
	(main.get("opts") as LaunchOptions).autostart = true
	var t_load := Time.get_ticks_msec()
	await main.call("_fly", FlightSettings.defaults())
	print("diag: загрузка сцены %d мс; flying=%s phase=%s" % [Time.get_ticks_msec() - t_load, game.flying_enabled, game.glider.phase()])
	var src := MotionSource.new()
	src.reset()
	var tel := game.glider.get_telemetry()
	print("diag: старт pos=%s heading=%.1f pilot_v=%s" % [tel.pilot_position, tel.heading_deg, tel.pilot_velocity])
	var n := int(run_s / DT)
	var k := 0
	var prev: MotionSample = null
	var take_t := -1.0
	for i in n:
		if game.autopilot == null and i * DT >= SPAWN_S:
			game.autopilot = Autopilot.new()  # первые SPAWN_S стоим без управления, потом разбег
		game.tick(DT)
		tel = game.glider.get_telemetry()
		src.push(tel, DT)
		k += 1
		if k < EVERY:
			continue
		k = 0
		var s := src.sample()
		var t := (i + 1) * DT
		var ph := game.glider.phase()
		if ph == "flying" and take_t < 0.0:
			take_t = t
		var row := {
			"t": t, "phase": ph, "valid": s.valid, "on_ground": s.on_ground, "surge": s.surge, "sway": s.sway,
			"heave": s.heave, "roll": s.roll, "pitch": s.pitch, "yaw": s.yaw, "airspeed": s.airspeed,
			"d_heave_g": 0.0 if prev == null else (s.heave - prev.heave) / Units.G,
			"d_surge_g": 0.0 if prev == null else (s.surge - prev.surge) / Units.G,
			"d_pitch": 0.0 if prev == null else s.pitch - prev.pitch,
			"d_roll": 0.0 if prev == null else s.roll - prev.roll,
			"d_yaw": 0.0 if prev == null else wrapf(s.yaw - prev.yaw, -180.0, 180.0),
			"vert_srs": s.heave - Units.G,
		}
		_rows.append(row)
		prev = s
		if take_t > 0.0 and t > take_t + 1.0:
			break
	_report(csv_path, take_t)
	main.queue_free()
	get_tree().quit(0)


func _peak(rows: Array, key: String) -> float:
	var p := 0.0
	for r: Dictionary in rows:
		p = maxf(p, absf(float(r[key])))
	return p


func _report(csv_path: String, take_t: float) -> void:
	var spawn: Array = _rows.filter(func(r: Dictionary) -> bool: return float(r.t) <= SPAWN_S)
	print("diag: ПЕРВЫЕ %.0f с (пакетов %d, фазы: %s)" % [SPAWN_S, spawn.size(), _phases(spawn)])
	print("diag:   invalid в потоке: %d (первый пакет valid=%s)" % [
		spawn.filter(func(r: Dictionary) -> bool: return not r.valid).size(), spawn[0].valid])
	print("diag:   пики |surge| %.3f |sway| %.3f |heave-G| %.3f м/с²" % [
		_peak(spawn, "surge"), _peak(spawn, "sway"), _peak(spawn.map(func(r: Dictionary) -> Dictionary: return {"x": r.vert_srs}), "x")])
	print("diag:   скачок за пакет: d_heave %.3f g d_surge %.3f g d_pitch %.2f d_roll %.2f d_yaw %.2f град" % [
		_peak(spawn, "d_heave_g"), _peak(spawn, "d_surge_g"), _peak(spawn, "d_pitch"), _peak(spawn, "d_roll"), _peak(spawn, "d_yaw")])
	var first: Dictionary = spawn[0]
	var second: Dictionary = spawn[mini(1, spawn.size() - 1)]
	print("diag:   первый пакет: heave %.2f surge %.2f pitch %.2f roll %.2f yaw %.2f; второй: heave %.2f surge %.2f" % [
		first.heave, first.surge, first.pitch, first.roll, first.yaw, second.heave, second.surge])
	var run: Array = _rows.filter(func(r: Dictionary) -> bool: return float(r.t) > SPAWN_S and r.phase != "flying")
	print("diag: РАЗБЕГ (пакетов %d, отрыв t=%.1f с)" % [run.size(), take_t])
	if not run.is_empty():
		print("diag:   пик |d_heave| за пакет %.3f g, |heave-G| %.3f м/с² (%.3f g), |surge| %.3f м/с², d_pitch %.2f град" % [
			_peak(run, "d_heave_g"), _peak(run.map(func(r: Dictionary) -> Dictionary: return {"x": r.vert_srs}), "x"),
			_peak(run.map(func(r: Dictionary) -> Dictionary: return {"x": r.vert_srs}), "x") / Units.G,
			_peak(run, "surge"), _peak(run, "d_pitch")])
		var big := run.filter(func(r: Dictionary) -> bool: return absf(float(r.d_heave_g)) > 0.2)
		print("diag:   пакетов со скачком heave > 0.2 g: %d из %d" % [big.size(), run.size()])
	if csv_path != "":
		var f := FileAccess.open(csv_path, FileAccess.WRITE)
		if f != null:
			var keys: Array = _rows[0].keys()
			f.store_line(",".join(keys))
			for r: Dictionary in _rows:
				f.store_line(",".join(keys.map(func(kk: String) -> String: return String(str(r[kk])))))
			print("diag: csv %s (%d строк)" % [csv_path, _rows.size()])


func _phases(rows: Array) -> String:
	var seen := {}
	for r: Dictionary in rows:
		seen[r.phase] = int(seen.get(r.phase, 0)) + 1
	return str(seen)
