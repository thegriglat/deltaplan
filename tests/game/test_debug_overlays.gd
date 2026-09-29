extends Node
## Отладочные слои (DebugOverlays): F1/F5/F6 включаются и выключаются без рендера и без ошибок,
## выключенный слой не крутит _process, термики берутся из полей AtmoThermal как есть.

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


static func _hills(x: float, z: float) -> float:
	return 400.0 + 150.0 * sin(x / 700.0) * cos(z / 900.0)


static func _sun(_x: float, _z: float) -> float:
	return 1.0


func _atmo() -> Atmosphere:
	var a := Atmosphere.new()
	var w := Config._deep_merge(
		Config.get_config("weather/medium"), {"wind_speed_kmh": 20.0, "thermal_mode": "static"}
	)
	a.configure(Config.get_config("atmosphere"), w)
	a.set_ground(_hills, _sun)
	a.add_static_thermal(300.0, 200.0, 3.0, 120.0)
	a.step(0.01)
	return a


func _press(dbg: DebugOverlays, action: String) -> void:
	var ev := InputEventAction.new()
	ev.action = action
	ev.pressed = true
	dbg._unhandled_input(ev)


func test_toggle_without_render() -> void:
	var a := _atmo()
	var pilot := Node3D.new()
	add_child(pilot)
	pilot.global_position = Vector3(0, 600, 0)
	var dbg := DebugOverlays.new()
	add_child(dbg)
	dbg.setup(a, pilot, _hills)
	check(InputMap.has_action("debug_perf"), "действие F1 зарегистрировано")
	check(InputMap.has_action("debug_wind"), "действие F5 зарегистрировано")
	check(InputMap.has_action("debug_thermals"), "действие F6 зарегистрировано")
	check(not dbg.is_processing(), "всё выключено — _process не крутится")
	for act in ["debug_perf", "debug_wind", "debug_thermals"]:
		_press(dbg, act)
	check(dbg.perf_on and dbg.wind_on and dbg.thermals_on, "F1/F5/F6 включили слои")
	for i in 10:
		dbg._process(0.1)
	check(dbg.perf_text().begins_with("FPS"), "текст производительности")
	var shapes := dbg.thermal_shapes()
	check(shapes.size() == 1, "один статический термик в слое F6 (%d)" % shapes.size())
	if shapes.size() == 1:
		check(is_equal_approx(float(shapes[0].strength), 3.0), "сила — как у термика")
		check(dbg.core_radius(shapes[0], float(shapes[0].y1)) > 100.0, "радиус у верха ~ ядро")
	var v := dbg.mean_air_at(Vector3(0, 600, 0))
	check(v.length() > 1.0, "средний ветер есть (%s)" % v)
	check(a.turbulence_enabled, "турбулентность атмосферы восстановлена")
	for act in ["debug_perf", "debug_wind", "debug_thermals"]:
		_press(dbg, act)
	check(not (dbg.perf_on or dbg.wind_on or dbg.thermals_on), "повторное нажатие выключает")
	check(not dbg.is_processing(), "выключено — ноль затрат")
	dbg.free()
	pilot.free()
	a.free()


func test_w_color() -> void:
	var dbg := DebugOverlays.new()
	add_child(dbg)
	check(dbg.w_color(2.0).r > 0.9 and dbg.w_color(2.0).b < 0.3, "подъём — красный")
	check(dbg.w_color(-2.0).b > 0.9 and dbg.w_color(-2.0).r < 0.3, "опускание — синий")
	var g := dbg.w_color(0.0)
	check(absf(g.r - g.b) < 0.01, "около нуля — серый")
	dbg.free()
