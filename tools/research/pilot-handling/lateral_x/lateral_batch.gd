extends Node
## PHD-2: боковой отклик после X. Состояния: T30/T45 (установившийся вираж регулятором), S1 (короткий боковой ввод),
## T30P (вираж 30° + тяга на себя), S0 (прямой, нейтраль). Сценарии с t0: H (держать), A (X как в игре: ступень в 0),
## A2 (экспонента τ 0,2 — как в документации), B05/B1/B2 (линейный возврат), C (руки отпущены), K*/KC (толчок по рысканию/крену).
## godot --headless --path . res://tools/research/pilot-handling/lateral_x/lateral_batch.tscn -- \
##   --wings=training,laminar,sport,icaro_mastr --out=tools/research/pilot-handling/lateral_x/out/game.json
const DT := 1.0 / 120.0
var _a := {"wings": "training", "out": "", "states": "T30,T45,S1,T30P,S0", "scen": "", "t0": "40", "post": "30", "every": "6",
	"mass": "ref", "kick_r": "0.15", "kick_p": "0.3"}
const SCEN_TURN := ["H", "A", "A2", "B05", "B1", "B2", "C"]
const SCEN_S0 := ["KR", "KRC", "KP", "KPC"]


func _ready() -> void:
	for s in OS.get_cmdline_user_args():
		if s.begins_with("--") and s.contains("="):
			var kv := s.substr(2).split("=", true, 1)
			_a[kv[0]] = kv[1]
	var res := {"args": _a, "dt": DT, "cols": ["t", "phi", "beta", "p", "r", "psidot", "relx", "rely", "relz", "shx", "u_roll", "u_pitch", "V", "theta"], "runs": {}}
	for w in String(_a.wings).split(","):
		for st in String(_a.states).split(","):
			var sc: Array = SCEN_S0 if st == "S0" else (SCEN_TURN if st != "S1" else ["H", "A", "A2", "B05", "B1", "B2", "C"])
			if _a.scen != "":
				sc = String(_a.scen).split(",")
			for sn in sc:
				var key := "%s|%s|%s" % [w, st, sn]
				res.runs[key] = _run(w, st, sn)
	var f := FileAccess.open(String(_a.out), FileAccess.WRITE)
	f.store_string(JSON.stringify(res, "", false))
	f.close()
	get_tree().quit(0)


func _model(w: String) -> PendulumModel:
	var wing: Dictionary = Config.get_config("wings/" + w).duplicate(true)
	var pilot: Dictionary = Config.get_config("pilot").duplicate(true)
	var mass := float(pilot.mass_kg)
	if _a.mass == "ref":
		mass = float(wing.pilot_mass_ref_kg)
	pilot.mass_kg = clampf(mass, float(wing.pilot_mass_min_kg), float(wing.pilot_mass_max_kg))
	var m := PendulumModel.new()
	m.setup(wing, pilot, {"air_density": {"altitude_dependent": false}}, {})
	m.reset_in_air(Vector3(0.0, 1000.0, 0.0), 0.0)
	return m


func _row(m: PendulumModel, t: float, ur: float, up: float) -> Array:
	var Rt := m._R.transposed()
	var wb := Rt * m._w
	var vb := Rt * m._vel
	var V := vb.length()
	var beta := atan2(vb.y, vb.x)
	var rel := m.pilot_rel
	return [snappedf(t, 0.0001), snappedf(rad_to_deg(m.bank), 0.0001), snappedf(rad_to_deg(beta), 0.0001),
		snappedf(rad_to_deg(wb.x), 0.0001), snappedf(rad_to_deg(wb.z), 0.0001), snappedf(rad_to_deg(m._w.z), 0.0001),
		snappedf(rel.x, 0.00001), snappedf(rel.y, 0.00001), snappedf(rel.z, 0.00001), snappedf(m.pilot_shift.x, 0.0001),
		snappedf(ur, 0.0001), snappedf(up, 0.0001), snappedf(V, 0.001), snappedf(rad_to_deg(m.theta), 0.0001)]


func _run(w: String, st: String, sn: String) -> Dictionary:
	var m := _model(w)
	var inp := ControlInput.new()
	var t0 := float(_a.t0)
	var post := float(_a.post)
	var every := int(_a.every)
	var bank_t: float = {"T30": 30.0, "T45": 45.0, "T30P": 30.0}.get(st, 0.0)
	var p_hold := -0.4 if st == "T30P" else 0.0
	var ik := 0.0
	var u_hist: Array = []
	var u0 := 0.0
	var ser: Array = []
	var n := 0
	var T := t0 + post
	if st == "S1" or st == "S0":
		t0 = 6.0 if st == "S1" else 8.0
		T = t0 + post
	var t_rel := 0.0
	var nan := false
	var kicked := false
	for i in int(T / DT):
		var t: float = m.time_s
		var ur := 0.0
		var up := 0.0
		if t < t0:
			up = p_hold
			if bank_t > 0.0:
				var ramp := clampf(t / 8.0, 0.0, 1.0)  # плавный набор заданного крена
				var e := deg_to_rad(bank_t) * ramp - m.bank
				ik = clampf(ik + 0.3 * e * DT, -1.0, 1.0)
				ur = clampf(1.0 * e - 0.4 * m.roll_rate + ik, -1.0, 1.0)
				u_hist.append(ur)
				if u_hist.size() > int(5.0 / DT):
					u_hist.pop_front()
			elif st == "S1":
				ur = 0.0 if t < 4.0 else 0.0
				ur = 0.6 if (t >= 4.5 and t < t0) else 0.0
			m.arms_relaxed = false
		else:
			if not u_hist.is_empty() and u0 == 0.0:
				var s := 0.0
				for v in u_hist:
					s += v
				u0 = s / u_hist.size()
			if st == "S1":
				u0 = 0.6
			t_rel = t - t0
			if not kicked and (sn.begins_with("K")):
				kicked = true
				if sn.begins_with("KR"):
					m._w += m._R * Vector3(0.0, 0.0, float(_a.kick_r))
				else:
					m._w += m._R * Vector3(float(_a.kick_p), 0.0, 0.0)
				m.arms_relaxed = sn.ends_with("C")
			var k := 1.0
			match sn:
				"H": k = 1.0
				"A": k = 0.0
				"A2": k = exp(-t_rel / 0.2)
				"B05": k = clampf(1.0 - t_rel / 0.5, 0.0, 1.0)
				"B1": k = clampf(1.0 - t_rel / 1.0, 0.0, 1.0)
				"B2": k = clampf(1.0 - t_rel / 2.0, 0.0, 1.0)
				"C": k = 0.0
				_: k = 0.0
			if sn == "C":
				m.arms_relaxed = true
			ur = u0 * k
			up = p_hold * k
			if sn.begins_with("K"):
				ur = 0.0
				up = 0.0
		inp.roll = ur
		inp.pitch = up
		m.step(DT, inp, Callable(), Callable())
		if not is_finite(m.bank):
			nan = true
			break
		if n % every == 0 and (t >= t0 - 3.0):
			ser.append(_row(m, t - t0, ur, up))
		n += 1
	return {"u0": u0, "t0": t0, "nan": nan, "phase": m.phase(), "series": ser}
