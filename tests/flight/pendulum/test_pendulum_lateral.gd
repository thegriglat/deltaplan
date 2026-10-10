extends TestCase
## «Маятник» (PD-2): крен и рыскание — переложение 45→45, опыт Ochi, руки отпущены (качание
## пилота поперёк) — против прототипа (reference.json, ±15 %).

const S := preload("res://tests/flight/pendulum/pendulum_sim.gd")
const WINGS := ["training", "laminar", "sport"]
const TOL := 0.15


func _rel(actual: float, expected: float, msg: String, tol: float = TOL) -> void:
	approx(actual, expected, absf(expected) * tol, msg)


func _first_below(t: PackedFloat64Array, x: PackedFloat64Array, thr: float) -> float:
	for i in x.size():
		if x[i] <= thr:
			return t[i]
	return NAN


func test_reversal_45() -> void:
	for w: String in WINGS:
		var r := S.scenario("reversal", w)
		var m := S.make(w)
		S.reset(m)
		var bh := S.BankHold.new(deg_to_rad(float(r.bank_deg)), 6.0, 2.5, 1.0)
		var inp := S.input()
		for i in int(round(float(r.hold_s) / S.DT)):
			inp.roll = bh.roll(m)
			m.step(S.DT, inp, Callable(), Callable())
		var phi0 := rad_to_deg(m.bank)
		var t0 := m.time_s
		inp.roll = -1.0
		var t: PackedFloat64Array = []
		var phi: PackedFloat64Array = []
		for i in int(round(12.0 / S.DT)):
			m.step(S.DT, inp, Callable(), Callable())
			t.append(m.time_s - t0)
			phi.append(m.bank)
		check(S.finite(m), "%s: без NaN" % w)
		approx(phi0, r.phi_start, 3.0, "%s: вираж перед переложением, °" % w)
		var t_rev := _first_below(t, phi, deg_to_rad(-float(r.bank_deg)))
		_rel(t_rev, r.t_to_minus, "%s: переложение 45→45, с" % w)
		_rel(_first_below(t, phi, 0.0), r.t_to_zero, "%s: до горизонта, с" % w)
		print("    %s: переложение %.2f с (прототип %.2f), до 0° %.2f с (%.2f)" % [
			w, t_rev, r.t_to_minus, _first_below(t, phi, 0.0), r.t_to_zero])


func test_ochi_side_force() -> void:
	# Takamatsu & Ochi 2022: Sport 2 155 ≈ laminar, пилот 72,6 кг, ~30 Н вбок → крен ≈ 30° за 7 с
	var r := S.scenario("ochi", "laminar")
	var m := S.make("laminar", float(r.m_pilot))
	S.reset(m)
	var inp := S.input()
	for i in int(round(float(r.settle_s) / S.DT)):
		m.step(S.DT, inp, Callable(), Callable())
	var t0 := m.time_s
	var phi7 := NAN
	var phi_max := -INF
	for i in int(round(12.0 / S.DT)):
		var t := m.time_s - t0
		m.hands_force_y = float(r.force_n) if t < float(r.t_on_s) - 1.0e-9 else NAN
		m.step(S.DT, inp, Callable(), Callable())
		if is_nan(phi7) and m.time_s - t0 >= 7.0 - 1.0e-6:
			phi7 = rad_to_deg(m.bank)
		phi_max = maxf(phi_max, rad_to_deg(m.bank))
	m.hands_force_y = NAN
	check(S.finite(m), "без NaN")
	_rel(phi7, r.phi_7s, "крен через 7 с, °")
	_rel(phi_max, r.phi_max, "наибольший крен, °")
	check(phi7 > 25.0 and phi7 < 40.0, "крен через 7 с ≈ 30° (лётный опыт): %.1f°" % phi7)
	print("    Ochi: крен через 7 с %.1f° (прототип %.1f°), макс. %.1f° (%.1f°)" % [
		phi7, r.phi_7s, phi_max, r.phi_max])


func test_relaxed_pendulum() -> void:
	for w: String in WINGS:
		var r := S.scenario("pendulum", w)
		for ax: int in [1, 0]:
			var key := "lat" if ax == 1 else "lon"
			var m := S.make(w)
			S.reset(m)
			var inp := S.input()
			for i in int(round(3.0 / S.DT)):
				m.step(S.DT, inp, Callable(), Callable())
			# толчок пилоту 0,5 м/с поперёк (вдоль) крыла, руки отпущены
			var dv := Vector3.ZERO
			dv[ax] = 0.5
			var vv := m.chain.v
			vv[vv.size() - 1] += m._R * dv
			m.chain.v = vv
			m.arms_relaxed = true
			var t: PackedFloat64Array = []
			var x: PackedFloat64Array = []
			var t0 := m.time_s
			for i in int(round(20.0 / S.DT)):
				m.step(S.DT, inp, Callable(), Callable())
				t.append(m.time_s - t0)
				x.append(S.rel_b(m)[ax])
			check(S.finite(m), "%s %s: без NaN" % [w, key])
			var tail := x.slice(x.size() - 240)
			tail.sort()
			var med := 0.5 * (tail[119] + tail[120])
			var zc: PackedFloat64Array = []
			var pk: PackedFloat64Array = []
			for i in range(1, x.size()):
				if x[i - 1] - med < 0.0 and x[i] - med >= 0.0:
					zc.append(t[i])
			for i in range(1, x.size() - 1):
				var a := absf(x[i] - med)
				if a >= absf(x[i - 1] - med) and a > absf(x[i + 1] - med):
					pk.append(a)
			var d: Array[float] = []
			for j in range(1, zc.size()):
				d.append(zc[j] - zc[j - 1])
			d.sort()
			check(d.size() >= 2 and pk.size() >= 3, "%s %s: есть качание" % [w, key])
			if d.size() < 2 or pk.size() < 3:
				continue
			var per: float = d[d.size() / 2] if d.size() % 2 == 1 else 0.5 * (d[d.size() / 2 - 1] + d[d.size() / 2])
			var ratio := pk[2] / pk[0]
			_rel(per, r[key + "_period_s"], "%s: период качания %s, с" % [w, key])
			_rel(ratio, r[key + "_ratio_per_period"], "%s: затухание за период %s" % [w, key], 0.25)
			if key == "lat":
				check(per > 1.1 and per < 1.4, "%s: период поперёк 1,1–1,4 с: %.2f" % [w, per])
				check(ratio < 0.5, "%s: качание поперёк затухает: %.2f" % [w, ratio])
			print("    %s %s: период %.2f с (прототип %.2f), затухание %.2f (%.2f)" % [
				w, key, per, r[key + "_period_s"], ratio, r[key + "_ratio_per_period"]])
