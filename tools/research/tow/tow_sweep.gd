extends Node
## TW-16: управляемость «Маятника» на тросе без TowLine. Развёртка постоянной силы T на пилоте (или на подвеске)
## под углом eps вверх по курсу; пилот держит тангаж киля PI-регулятором. Пределы рук можно снять (free=1):
## тогда получаем потребное положение/усилие, а не упор. Вывод — CSV на stdout (строки "CSV,...").
## Запуск: см. README.md.

const Sim := preload("res://tests/flight/pendulum/pendulum_sim.gd")
const DT := 1.0 / 120.0

var wing := "sport"
var mode_link := true
var pfix := 99.0  ## < 90 — постоянный ввод тангажа (без регулятора)
var vhold := 0.0  ## > 0 — пилот держит воздушную скорость (м/с), иначе тангаж киля
var mass := 0.0


func _arg(name: String, def: float) -> float:
	var v := OS.get_environment(name)
	return float(v) if v != "" else def


func run_case(T: float, eps_deg: float, at: String, free: bool, secs: float, h_off: float = 0.0) -> Dictionary:
	var m := Sim.make(wing, mass)
	Sim.reset(m)
	if free:
		m.arms.shift_x_pull = 2.0
		m.arms.shift_x_pull_full = 2.0
		m.arms.pull_limit = 2.0
		m.arms.shift_x_push = 2.0
		m.arms.force_max = 1.0e5
	var ramp := 10.0
	var rope := 300.0
	var st := {"va": -m.velocity.z, "x": 0.0, "tc": 0.0}  # скорость и ход якоря; текущая заданная T
	var p0: Vector3 = m.pilot_position if at == "pilot" else Sim.cg(m)
	var x0 := p0.z
	if mode_link:
		var fnl := func(s: Dictionary) -> Dictionary:
			var tc: float = T * minf(s.t / ramp, 1.0)
			var err: float = tc - float(s.link_tension_n)
			st.va = clampf(st.va + 0.002 * err * s.h, 5.0, 45.0)
			st.x += st.va * s.h
			var base: Vector3 = s.pilot_pos if at == "pilot" else s.hang_pos
			# якорь впереди по курсу (−Z), высота — над ЦМ на rope·sin(eps)
			var anchor := Vector3(0.0, base.y + rope * sin(deg_to_rad(eps_deg)), 0.0)
			anchor.z = x0 - rope * cos(deg_to_rad(eps_deg)) - st.x
			return {"link": {"anchor": anchor, "anchor_vel": Vector3(0, 0, -st.va), "length_m": rope,
				"compliance_m_per_n": rope / 3.0e5, "damping_s": 0.02, "at": at}}
		m.set_external_force(fnl)
	else:
		var dir := Vector3(0.0, sin(deg_to_rad(eps_deg)), -cos(deg_to_rad(eps_deg)))
		if at == "split":  # 50/50: половина на пилота, половина на подвеску (киль у подвеса)
			m.set_external_force(func(s: Dictionary) -> Dictionary:
				var f: Vector3 = dir * T * 0.5 * minf(s.t / ramp, 1.0)
				return {"pilot": f, "hang": f})
		else:
			m.set_external_force(func(s: Dictionary) -> Dictionary: return {at: dir * T * minf(s.t / ramp, 1.0)})
	var th0 := m.theta
	var pint := 0.0
	var n := 0
	var acc := {"shift": 0.0, "fx": 0.0, "fy": 0.0, "v": 0.0, "vz": 0.0, "tens": 0.0, "theta": 0.0, "pitch": 0.0, "alpha": 0.0}
	var ok := true
	var v_start := 0.0
	for i in int(secs / DT):
		var p := 0.0
		if pfix < 90.0:
			p = pfix
		elif vhold > 0.0:
			var ev: float = m.telemetry.airspeed - vhold  # быстрее цели — «от себя» (+)
			pint = clampf(pint + 0.01 * ev * DT * 10.0, -1.0, 1.0)
			p = clampf(pint + 0.05 * ev, -1.0, 1.0)
		else:
			var e := rad_to_deg(m.theta - th0)
			pint = clampf(pint - 0.004 * e, -1.0, 1.0)  # накопление (на себя < 0)
			p = clampf(pint - 0.15 * e, -1.0, 1.0)
		m.step(DT, Sim.input(p, 0.0), Callable(), Callable())
		if not Sim.finite(m):
			ok = false
			break
		if i == int((secs - 5.0) / DT):
			v_start = m.telemetry.airspeed
		if i >= int((secs - 5.0) / DT):
			var rel := Sim.rel_b(m)
			acc.shift += rel.x - m.arms.neutral_rel.x
			acc.fx += m.arms.force_b.x
			acc.fy += m.arms.force_b.y
			acc.v += m.telemetry.airspeed
			acc.vz += m.velocity.y
			acc.theta += rad_to_deg(m.theta - th0)
			acc.alpha += rad_to_deg(m.alpha)
			acc.pitch += p
			acc.tens += m.link_tension_n
			n += 1
	var r := {"T": T, "eps": eps_deg, "at": at, "free": free, "ok": ok}
	if n > 0:
		for k in acc:
			r[k] = acc[k] / float(n)
	r["tension"] = m.external_force_n.length()
	# состояние для проверки баланса пилота (NED: x север, y восток, z вниз)
	var hp: Vector3 = m._pos + m._R * m._r_hang_b
	var pp: Vector3 = m.chain.pilot()
	var pv: Vector3 = m.chain.v[m.chain.v.size() - 1] if m.chain.v.size() > 0 else Vector3.ZERO
	r["dbg"] = {"hang": [hp.x, hp.y, hp.z], "pilot": [pp.x, pp.y, pp.z], "strap_T": m.strap_tension,
		"ext": [m.external_force_n.x, m.external_force_n.y, m.external_force_n.z],
		"hands_ned": [m._hands_p.x, m._hands_p.y, m._hands_p.z], "vel": [m._vel.x, m._vel.y, m._vel.z],
		"R_x": [m._R.x.x, m._R.y.x, m._R.z.x], "theta": m.theta, "alpha": m.alpha, "mass_p": m.pilot_mass, "mass": m.mass}
	r["dv_dt"] = (m.telemetry.airspeed - v_start) / 5.0
	return r


func _ready() -> void:
	var m := Sim.make(wing, mass)
	Sim.reset(m)
	print("GEOM neutral_rel=", m.arms.neutral_rel, " r_hang_b=", m._r_hang_b, " hang_len=", m._hang_len, " m_wing=", m._m_wing, " m_pilot=", m.arms.force_max)
	var st = m.strips
	print("GEOM2 ", JSON.stringify({"chord_mean": st.chord_mean, "area": st.area, "nl_soft": st.nl_soft, "nl_luff": st.nl_luff, "a_trim": st.nl_alpha_trim, "a_luff": st.nl_alpha_luff, "w": st.nl_w, "dcm0": st.dcm0, "m_wing": m._m_wing, "r_bar_b": [m._r_bar_b.x, m._r_bar_b.y, m._r_bar_b.z], "pilot_cda": m.pilot_cda if "pilot_cda" in m else -1}))
	vhold = _arg("VHOLD", 0.0)
	pfix = _arg("PFIX", 99.0)
	var mode := OS.get_environment("SWEEP")
	var rows := []
	var at := OS.get_environment("AT") if OS.get_environment("AT") != "" else "pilot"
	if mode == "T":
		for T in [0.0, 100.0, 200.0, 300.0, 400.0, 500.0, 600.0, 700.0, 800.0]:
			for free in [true, false]:
				rows.append(run_case(T, _arg("EPS", 20.0), at, free, 50.0))
	elif mode == "TRIM":
		# свободный полёт без троса: постоянный ввод тангажа -> установившаяся скорость и положение пилота
		for p in [0.0, -0.1, -0.2, -0.3, -0.4, -0.5, -0.6, -0.8, -1.0]:
			var mm := Sim.make(wing, mass)
			Sim.reset(mm)
			for i in int(60.0 / DT):
				mm.step(DT, Sim.input(p, 0.0), Callable(), Callable())
			var rel := Sim.rel_b(mm)
			print("CSV,", JSON.stringify({"p": p, "v": mm.telemetry.airspeed, "vy": mm.velocity.y, "shift": rel.x - mm.arms.neutral_rel.x,
				"fx": mm.arms.force_b.x, "alpha": rad_to_deg(mm.alpha), "theta": rad_to_deg(mm.theta)}))
	elif mode == "FORCE":
		# постоянная сила (без звена): at=pilot|hang|split, пилот держит тангаж; T = полная сила
		mode_link = false
		for T in [100.0, 200.0, 300.0, 400.0, 500.0]:
			rows.append(run_case(T, _arg("EPS", 20.0), at, true, 50.0))
	elif mode == "PFIX":
		for T in [200.0, 400.0, 600.0]:
			rows.append(run_case(T, _arg("EPS", 45.0), at, false, 60.0))
	elif mode == "T2":
		for T in [100.0, 200.0, 300.0]:
			rows.append(run_case(T, _arg("EPS", 20.0), at, true, _arg("SECS", 90.0)))
	elif mode == "TV":
		for T in [100.0, 200.0, 300.0, 400.0, 500.0, 600.0, 800.0]:
			rows.append(run_case(T, _arg("EPS", 20.0), at, true, 70.0))
	elif mode == "EPS":
		for eps in [0.0, 10.0, 20.0, 30.0, 45.0, 60.0]:
			for T in [300.0, 600.0]:
				rows.append(run_case(T, eps, at, true, 50.0))
	for r in rows:
		print("CSV,", JSON.stringify(r))
	get_tree().quit()
