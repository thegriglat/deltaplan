extends TestCase
## Контракт TP-К2 (docs/contracts/trike-pilot.md): TrikeEngine.

const DT := 0.02
const ENGINE := {"gear_ratio": 3.47, "prop_rpm_idle": 576.0}
const THRUST := {
	"v_ms": [0.0, 10.0, 20.0],
	"full_n": [1500.0, 1400.0, 1200.0],
	"idle_n": [200.0, 100.0, 0.0],
	"rpm_full": [1600.0, 1700.0, 1750.0],
}
const OPS := {
	"fuel": {
		"tank_l": 53.0, "start_l": 40.0, "density_kg_l": 0.74,
		"burn": {"rpm_engine": [2000.0, 4000.0, 6800.0], "lph": [3.0, 10.0, 25.0]},
	},
	"starter": {"start_s": 1.0, "stop_s": 2.0},
	"throttle": {"rate_per_s": 0.5},
}


func _make(fuel: float = -1.0) -> TrikeEngine:
	var e := TrikeEngine.new()
	e.setup(ENGINE, THRUST, OPS)
	e.reset(fuel)
	return e


func _run(e: TrikeEngine, t: float, v: float, axis: float, toggle_first: bool = false) -> void:
	var n := int(round(t / DT))
	for i in n:
		e.step(DT, v, axis, toggle_first and i == 0)


func _start(e: TrikeEngine, v: float = 0.0) -> void:
	_run(e, 1.0 + DT, v, 0.0, true)


func test_reset_and_off() -> void:
	var e := _make()
	check(e.state == "off" and e.prop_rpm == 0.0 and e.thrust_n == 0.0, "после reset off")
	var f0 := e.fuel_l
	_run(e, 10.0, 0.0, 0.0)
	check(e.fuel_l == f0, "расход 0 за 10 с")
	approx(e.fuel_frac, 40.0 / 53.0, 1e-6, "fuel_frac")
	approx(e.fuel_mass_kg, 40.0 * 0.74, 1e-6, "fuel_mass_kg")


func test_start_idle() -> void:
	var e := _make()
	_start(e)
	check(e.state == "running" and e.running, "running")
	approx(e.prop_rpm, 576.0, 576.0 * 0.01, "холостые")
	approx(e.thrust_n, 200.0, 2.0, "idle_n(0)")
	approx(e.engine_rpm, 576.0 * 3.47, 20.0, "engine_rpm")


func test_throttle_full_and_back() -> void:
	for v in [0.0, 10.0, 15.0]:
		var e := _make()
		_start(e, v)
		_run(e, 2.0 + DT, v, 1.0)
		approx(e.throttle, 1.0, 1e-6, "газ 1")
		var rf := (1700.0 + 0.5 * 50.0) if v == 15.0 else (1600.0 if v == 0.0 else 1700.0)
		var tf := (1400.0 - 0.5 * 200.0) if v == 15.0 else (1500.0 if v == 0.0 else 1400.0)
		approx(e.prop_rpm, rf, rf * 0.01, "rpm_full V=%s" % v)
		approx(e.thrust_n, tf, tf * 0.01, "full_n V=%s" % v)
		_run(e, 3.0, v, -1.0)
		approx(e.throttle, 0.0, 1e-6, "газ не ниже 0")


func test_stop() -> void:
	var e := _make()
	_start(e)
	var prev := e.prop_rpm
	var t := 0.0
	var mono := true
	e.step(DT, 0.0, 0.0, true)
	t += DT
	check(e.state == "stopping", "stopping")
	while e.state == "stopping" and t < 5.0:
		if e.prop_rpm > prev + 1e-9:
			mono = false
		prev = e.prop_rpm
		e.step(DT, 0.0, 0.0, false)
		t += DT
	check(mono, "монотонно")
	check(e.state == "off", "off")
	approx(t, 2.0, 2.0 * DT + 0.05, "за stop_s")
	check(e.thrust_n == 0.0, "тяга 0")


func test_burn_idle() -> void:
	var e := _make()
	_start(e)
	var f0 := e.fuel_l
	_run(e, 60.0, 0.0, 0.0)
	var exp := 3.0 / 60.0  # idle*gear = 1998.7 -> крайнее значение 3 л/ч
	approx(f0 - e.fuel_l, exp, exp * 0.01, "расход за 60 с")


func test_out_of_fuel() -> void:
	var e := _make(0.01)
	_start(e)
	_run(e, 20.0, 0.0, 0.0)
	check(e.out_of_fuel and e.fuel_l == 0.0, "кончилось")
	check(e.state == "off", "остановился")
	e.step(DT, 0.0, 0.0, true)
	check(e.state == "off", "toggle не запускает")
	var e2 := _make(0.01)
	_run(e2, 1.0, 0.0, 0.0, true)
	_run(e2, 30.0, 0.0, 0.0)
	check(e2.out_of_fuel, "out_of_fuel")
	var z := _make(0.0)
	check(z.out_of_fuel, "reset(0) -> out_of_fuel")


func test_continuity() -> void:
	var e := _make()
	var slope := maxf(576.0 / 1.0, maxf(576.0 / 2.0, 0.5 * (1750.0 - 576.0)))
	var prev_rpm := 0.0
	var worst := 0.0
	for i in 1500:
		var toggle := i == 0 or i == 700
		var axis := 1.0 if (i > 200 and i < 500) else (-1.0 if i >= 500 and i < 650 else 0.0)
		e.step(DT, 12.0, axis, toggle)
		worst = maxf(worst, absf(e.prop_rpm - prev_rpm) - (slope * DT + 1.0))
		prev_rpm = e.prop_rpm
	check(worst <= 0.0, "непрерывность prop_rpm (превышение %.3f)" % worst)
