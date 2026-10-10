extends TestCase
## Сдвиг подвески через apparatus (PD-К3 → Glider → PendulumModel): +1 см вперёд меняет трим
## на ref.kmh_per_cm_hang крыла (блок pendulum в configs/wings, PD-К2), ±20 %.

const M := preload("res://tests/flight/pendulum/test_pendulum_mode.gd")
const WINGS := ["training", "laminar", "sport"]


func _trim_kmh(wing: String, shift_cm: float) -> float:
	var g := M.make_glider("pendulum", wing, {"hang_shift_cm": shift_cm})
	var m: PendulumModel = g.model
	m.reset_in_air(Vector3(0.0, 1000.0, 0.0), 0.0)
	var v := Units.to_kmh(float(m.solve_trim().V))
	g.free()
	return v


## Установившаяся воздушная скорость после 20 с полёта на триме (динамика, не только solve_trim).
func _settled_kmh(wing: String, shift_cm: float) -> float:
	var g := M.make_glider("pendulum", wing, {"hang_shift_cm": shift_cm})
	g.reset_in_air(Vector3(0.0, 1000.0, 0.0), 0.0)
	var vs := 0.0
	var n := 0
	for i in 120 * 30:
		g.step(1.0 / 120.0)
		if i >= 120 * 20:
			vs += g.get_telemetry().airspeed
			n += 1
	g.free()
	return Units.to_kmh(vs / n)


func test_hang_shift_changes_trim() -> void:
	for w: String in WINGS:
		var ref: float = float(Config.get_config("wings/" + w).pendulum.ref.kmh_per_cm_hang)
		var d := _trim_kmh(w, 1.0) - _trim_kmh(w, 0.0)
		print("    %s: +1 см → %+.3f км/ч (таблица %+.3f)" % [w, d, ref])
		approx(d, ref, absf(ref) * 0.2, "%s: сдвиг подвески +1 см → трим (solve_trim)" % w)
		var ds := _settled_kmh(w, 1.0) - _settled_kmh(w, 0.0)
		print("    %s: динамика %+.3f км/ч" % [w, ds])
		approx(ds, ref, absf(ref) * 0.2 + 0.1, "%s: то же в динамике (допуск 20%% + 0,1 км/ч)" % w)
