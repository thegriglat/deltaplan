extends TestCase
## «Маятник» (PD-2): трим и снижение, фугоида — против прототипа (reference.json, ±15 %).

const S := preload("res://tests/flight/pendulum/pendulum_sim.gd")
const WINGS := ["training", "laminar", "sport"]
const TOL := 0.15


func _rel(actual: float, expected: float, msg: String, tol: float = TOL) -> void:
	approx(actual, expected, absf(expected) * tol, msg)


func test_reset_is_trim() -> void:
	for w: String in WINGS:
		var r := S.scenario("trim", w)
		var m := S.make(w)
		S.reset(m)
		_rel(S.airspeed(m) * 3.6, r.reset_V_kmh, "%s: скорость сразу после сброса, км/ч" % w, 0.02)
		_rel(m._vel.z, r.reset_sink_ms, "%s: снижение сразу после сброса, м/с" % w, 0.03)
		approx(rad_to_deg(m.theta), r.reset_theta_deg, 0.3, "%s: тангаж киля, °" % w)
		check(m.mode == FlightModel.Mode.AIR and m.phase() == "flying", "%s: в воздухе" % w)


func test_trim_and_sink() -> void:
	for w: String in WINGS:
		var r := S.scenario("trim", w)
		var m := S.make(w)
		S.reset(m)
		var inp := S.input()
		var n := int(round(30.0 / S.DT))
		var sv := 0.0
		var ss := 0.0
		var sa := 0.0
		var st := 0.0
		var k := 0
		for i in n:
			m.step(S.DT, inp, Callable(), Callable())
			if m.time_s > 15.0:
				sv += S.airspeed(m)
				ss += m._vel.z
				sa += m.alpha
				st += m.strap_tension
				k += 1
		check(S.finite(m), "%s: без NaN" % w)
		_rel(sv / k * 3.6, r.V_kmh, "%s: трим, км/ч" % w)
		_rel(ss / k, r.sink_ms, "%s: снижение, м/с" % w)
		approx(rad_to_deg(sa / k), r.alpha_deg, 1.5, "%s: α киля, °" % w)
		_rel(st / k, r.tension_N, "%s: натяжение стропы, Н" % w)
		print("    %s: трим %.2f км/ч (прототип %.2f), снижение %.3f м/с (%.3f)" % [
			w, sv / k * 3.6, r.V_kmh, ss / k, r.sink_ms])


func test_phugoid() -> void:
	for w: String in WINGS:
		var r := S.scenario("phugoid", w)
		var m := S.make(w)
		S.reset(m)
		# толчок +3 м/с по скорости: крылу и всем узлам цепи (как в прототипе)
		var v0: Vector3 = m._vel
		m._vel = v0 * (1.0 + float(r.dv_ms) / v0.length())
		var dv: Vector3 = m._vel - m.chain.pilot_vel()
		var vv := m.chain.v
		for i in vv.size():
			vv[i] += dv
		m.chain.v = vv
		var inp := S.input()
		var t: PackedFloat64Array = []
		var V: PackedFloat64Array = []
		for i in int(round(60.0 / S.DT)):
			m.step(S.DT, inp, Callable(), Callable())
			t.append(m.time_s)
			V.append(S.airspeed(m))
		check(S.finite(m), "%s: без NaN" % w)
		var pk: Array[int] = []
		for i in range(1, V.size() - 1):
			if V[i] > V[i - 1] and V[i] >= V[i + 1]:
				pk.append(i)
		check(pk.size() >= 3, "%s: есть колебания скорости" % w)
		if pk.size() < 3:
			continue
		var d: Array[float] = []
		for j in range(1, pk.size()):
			d.append(t[pk[j]] - t[pk[j - 1]])
		d.sort()
		var period: float = d[d.size() / 2] if d.size() % 2 == 1 else 0.5 * (d[d.size() / 2 - 1] + d[d.size() / 2])
		var tail := V.slice(V.size() - 600)
		tail.sort()
		var vm := 0.5 * (tail[299] + tail[300])
		var ratio := (V[pk[1]] - vm) / (V[pk[0]] - vm)
		_rel(period, r.period_s, "%s: период фугоиды, с" % w)
		_rel(ratio, r.amp_ratio_per_period, "%s: отношение амплитуд за период" % w)
		check(ratio < 1.0, "%s: фугоида затухает сама" % w)
		print("    %s: фугоида %.2f с / %.2f (прототип %.2f / %.2f)" % [
			w, period, ratio, r.period_s, r.amp_ratio_per_period])
