extends SceneTree
## Цена шага «Маятника» (PD-2): 1200 шагов PendulumModel против 1200 шагов FlightModel —
## то же крыло (sport), тот же старт в воздухе, шаг 1/120 с, полёт с лёгким смещением и ветром
## (воздух — Callable, как в игре: маятник спрашивает его в каждой полосе и у пилота).
## Печатает «ratio=<время маятника / время FlightModel>» (лучший из 3 прогонов каждой модели).
##
##   XDG_DATA_HOME=$(mktemp -d) godot --headless --path . --script tools/flight/pendulum_bench.gd

const STEPS := 1200
const DT := 1.0 / 120.0
const ROUNDS := 3
const WING := "sport"

var _done := false


## Модели грузятся после автозагрузок (Config): при --script статические ссылки на классы,
## которые обращаются к Config, не компилируются.
func _new(path: String) -> Object:
	return (load(path) as GDScript).new()


func _process(_delta: float) -> bool:
	if _done:
		return true
	_done = true
	var cfg_root: Node = root.get_node_or_null("Config")
	if cfg_root == null:
		push_error("pendulum_bench: нет автозагрузки Config")
		quit(1)
		return true
	var wing: Dictionary = cfg_root.get_config("wings/" + WING)
	var pilot: Dictionary = cfg_root.get_config("pilot").duplicate(true)
	pilot.mass_kg = float(wing.pilot_mass_ref_kg)
	var air := func(p: Vector3) -> Vector3: return Vector3(1.5, 0.2 * sin(0.05 * p.x), 0.0)
	var inp := ControlInput.new()
	inp.roll = 0.3
	inp.weight_shift = true
	var t_fm := INF
	var t_pd := INF
	var stretch := 0.0
	for r in ROUNDS:
		var fm: Object = _new("res://scripts/flight/flight_model.gd")
		fm.setup(wing, pilot)
		fm.reset_in_air(Vector3(0, 1000, 0), 0.0)
		var t0 := Time.get_ticks_usec()
		for i in STEPS:
			fm.step(DT, inp, air, Callable())
		t_fm = minf(t_fm, float(Time.get_ticks_usec() - t0))
		var pm: Object = _new("res://scripts/flight/pendulum/pendulum_model.gd")
		pm.setup(wing, pilot)
		pm.reset_in_air(Vector3(0, 1000, 0), 0.0)
		t0 = Time.get_ticks_usec()
		for i in STEPS:
			pm.step(DT, inp, air, Callable())
		t_pd = minf(t_pd, float(Time.get_ticks_usec() - t0))
		stretch = pm.chain.max_stretch
	print("FlightModel: %.1f мкс/шаг, PendulumModel: %.1f мкс/шаг (растяжение цепи %.3f м)" % [
		t_fm / STEPS, t_pd / STEPS, stretch])
	print("ratio=%.3f" % (t_pd / t_fm))
	quit(0)
	return true
