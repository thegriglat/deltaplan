extends Node
## PHD-3: «надувной» отклик Маятника. Части (--part=): inertia, deriv, chain, freq, swing.
## Запуск: XDG_DATA_HOME=~/.cache/dp-xdg/$(basename "$PWD") godot --headless --path . \
##   res://tools/research/pilot-handling/feel/feel.tscn -- --part=all --out=tools/research/pilot-handling/feel/feel.json
## Штиль, ρ 1,225, эталонная масса крыла; игровой PendulumModel (tests/flight/pendulum/pendulum_sim.gd).

const S := preload("res://tests/flight/pendulum/pendulum_sim.gd")
const DT := 1.0 / 120.0
const SETTLE_S := 8.0
const DEADZONE := 0.02  ## configs/controls.json → mouse.bar_deadzone

var _a := {"out": "tools/research/pilot-handling/feel/feel.json", "part": "all",
	"wings": "training,laminar,sport,ww_u2"}


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--") and a.contains("="):
			var kv := a.substr(2).split("=", true, 1)
			_a[kv[0]] = kv[1]
	var part := String(_a.part).split(",")
	var res := {"args": _a, "dead_zone": DEADZONE}
	var wings := String(_a.wings).split(",")
	for w in wings:
		var r := {"group": Config.get_config("wings/" + w).group}
		if "all" in part or "inertia" in part:
			r["inertia"] = _inertia(w)
		if "all" in part or "deriv" in part:
			r["deriv"] = _deriv(w)
		if "all" in part or "chain" in part:
			r["chain"] = _chain(w)
		if "cmdlp" in part:
			r["cmdlp"] = _cmdlp(w)
		if "all" in part or "swing" in part:
			r["swing"] = _swing(w)
		if "all" in part or "freq" in part:
			r["freq"] = _freq(w)
		res[w] = r
		print(w, " ", JSON.stringify(r).substr(0, 400))
	var fl := FileAccess.open(String(_a.out), FileAccess.WRITE)
	fl.store_string(JSON.stringify(res, " ", false))
	fl.close()
	get_tree().quit(0)


func _settled(w: String, secs := SETTLE_S) -> PendulumModel:
	var m := S.make(w)
	S.reset(m)
	var c := S.input()
	for i in int(secs / DT):
		m.step(DT, c, Callable(), Callable())
	return m


## Положение пилота относительно ЦМ крыла в осях крыла (B), м.
func _rel(m: PendulumModel) -> Vector3:
	return m._R.transposed() * (m.chain.pilot() - m._pos)


func _inertia(w: String) -> Dictionary:
	var m := S.make(w)
	S.reset(m)
	var ine: Dictionary = m.wing.pendulum.inertia_kgm2
	var c := m.area / m.span
	var added := PI / 48.0 * m._rho_ref * c * c * pow(m.span, 3)
	var rel := _rel(m)
	var mw: float = m._m_wing
	var mp: float = m.pilot_mass
	# вокруг продольной оси системы: крыло (ЦМ) и пилот (точка) на плечах по y, z относительно общего ЦМ
	var cgz := mp * rel.z / (mp + mw)
	var cgy := mp * rel.y / (mp + mw)
	var d_w := Vector2(cgy, cgz).length()
	var d_p := Vector2(rel.y - cgy, rel.z - cgz).length()
	var ixx_sys: float = float(ine.ixx) + added + mw * d_w * d_w + mp * d_p * d_p
	var iyy_sys: float = float(ine.iyy) + mw * d_w * d_w + mp * d_p * d_p  # тангаж ≈ той же плечо (нет x)
	var izz_wing: float = float(ine.izz)
	return {"wing_mass_kg": mw, "pilot_mass_kg": mp, "span_m": m.span, "area_m2": m.area,
		"ixx_wing": ine.ixx, "iyy_wing": ine.iyy, "izz_wing": ine.izz, "ixz_wing": ine.get("ixz", 0.0),
		"ixx_added_air": added, "pilot_rel_b_m": [rel.x, rel.y, rel.z], "hang_len_m": m._hang_len,
		"ixx_system": ixx_sys, "pilot_share_ixx_system": mp * d_p * d_p / ixx_sys,
		"iyy_system_approx": iyy_sys, "izz_system_pilot_body_28": float(ine.izz) + 28.0,
		"apparent_roll": m.pendulum.apparent_roll}


## Производные по угловой скорости: центральная разность по моменту полос (aero_hz = 0, каждый подшаг).
func _deriv(w: String) -> Dictionary:
	var out := {}
	var sys_r := Vector3.ZERO
	var base := _settled(w)
	sys_r = -base.pilot_mass / (base.pilot_mass + base._m_wing) * _rel(base)
	var V: float = base.telemetry.airspeed
	var q := 0.5 * base.rho * V * V
	var b: float = base.span
	var Sa: float = base.area
	var cbar := Sa / b
	for ax in ["p", "q", "r"]:
		var mom := []
		var frc := []
		for sgn in [-1.0, 1.0]:
			var m := _settled(w)
			m.aero_hz = 0.0
			var p0: float = 0.05 * sgn
			var vec := Vector3(p0 if ax == "p" else 0.0, p0 if ax == "q" else 0.0, p0 if ax == "r" else 0.0)
			m._w += m._R * vec
			m.step(DT, S.input(), Callable(), Callable())
			mom.append(m.strips.moment_b)
			frc.append(m.strips.force_b)
			if ax == "p" and sgn > 0.0:
				sys_r = -m.pilot_mass / (m.pilot_mass + m._m_wing) * _rel(m)
		var dM: Vector3 = (mom[1] - mom[0]) / 0.1  # dM/dω, Н·м·с (около ЦМ крыла)
		var dF: Vector3 = (frc[1] - frc[0]) / 0.1
		var dMs: Vector3 = dM + sys_r.cross(dF)  # около ЦМ системы крыло+пилот
		var kk := q * Sa * b * b / (2.0 * V)
		out["d%sMsys_Nms" % ax] = [dMs.x, dMs.y, dMs.z]
		if ax == "p":
			out["Lp_Nms"] = dM.x
			out["Clp"] = dM.x / (q * Sa * b * b / (2.0 * V))
			out["Np_Nms"] = dM.z
			out["Clp_sys"] = dMs.x / kk
			out["Cnp_sys"] = dMs.z / kk
			out["Cnp"] = dM.z / (q * Sa * b * b / (2.0 * V))
		elif ax == "q":
			out["Mq_Nms"] = dM.y
			out["Cmq"] = dM.y / (q * Sa * cbar * cbar / (2.0 * V))
		else:
			out["Nr_Nms"] = dM.z
			out["Cnr"] = dM.z / (q * Sa * b * b / (2.0 * V))
			out["Cnr_sys"] = dMs.z / kk
			out["Clr_sys"] = dMs.x / kk
			out["Lr_Nms"] = dM.x
			out["Clr"] = dM.x / (q * Sa * b * b / (2.0 * V))
	out["V_ms"] = V
	out["q_pa"] = q
	# свободное затухание скорости крена: p0 = 0,2 рад/с, руки в нейтрали
	var m2 := _settled(w)
	m2._w += m2._R * Vector3(0.2, 0.0, 0.0)
	var c := S.input()
	var ps := []
	var bank0: float = m2.bank
	for i in int(6.0 / DT):
		m2.step(DT, c, Callable(), Callable())
		ps.append(m2.roll_rate)
	out["decay_p_t_s"] = [0.0, 0.05, 0.1, 0.2, 0.3, 0.5, 1.0, 2.0]
	var samp := []
	for t in out.decay_p_t_s:
		var k := clampi(int(t / DT) - 1, 0, ps.size() - 1)
		samp.append(ps[k] if t > 0.0 else 0.2)
	out["decay_p_rad_s"] = samp
	# постоянная времени по первым 0,3 с: p(t) = p_inf + (p0 - p_inf)·exp(-λt); берём время до 63 % спада к значению на 1 с
	var p1: float = ps[int(1.0 / DT) - 1]
	var t63 := NAN
	for i in ps.size():
		if (0.2 - ps[i]) >= 0.63 * (0.2 - p1):
			t63 = (i + 1) * DT
			break
	out["decay_t63_s"] = t63
	out["decay_p_at_1s"] = p1
	out["decay_bank_gain_deg"] = rad_to_deg(m2.bank - bank0)
	return out


## Цепочка: ступень roll = f хода; положение пилота (y), p, φ; время до 63 % значения.
func _chain(w: String) -> Dictionary:
	var out := {}
	for f in [0.1, 0.3]:
		var m := _settled(w)
		var rel0 := _rel(m).y
		var c := S.input(0.0, f)
		var ys := []
		var ps := []
		var bs := []
		var fs := []
		for i in int(6.0 / DT):
			m.step(DT, c, Callable(), Callable())
			ys.append(_rel(m).y - rel0)
			ps.append(rad_to_deg(m.roll_rate))
			bs.append(rad_to_deg(m.bank))
			fs.append(m.arms.force_b.y)
		var target: float = f * m.arms.shift_y_max
		var yfin: float = ys[int(2.0 / DT)]  # установившееся смещение через 2 с
		var pk := 0.0
		var pk_t := 0.0
		for i in int(3.0 / DT):
			if absf(ps[i]) > absf(pk):
				pk = ps[i]
				pk_t = (i + 1) * DT
		var d := {"target_shift_m": target, "shift_at_2s_m": yfin, "p_peak_dps": pk, "p_peak_t_s": pk_t,
			"force_peak_N": _absmax(fs), "bank_2s_deg": bs[int(2.0 / DT) - 1]}
		d["t63_shift_s"] = _t_frac(ys, yfin, 0.63)
		d["t10_shift_s"] = _t_frac(ys, yfin, 0.10)
		d["t63_p_s"] = _t_frac(ps, pk, 0.63)
		d["t10_p_s"] = _t_frac(ps, pk, 0.10)
		d["t_bank_1deg_s"] = _t_abs(bs, 1.0)
		d["t_bank_5deg_s"] = _t_abs(bs, 5.0)
		out["step_%d" % int(f * 100)] = d
	return out


func _t_frac(a: Array, fin: float, frac: float) -> float:
	for i in a.size():
		if absf(a[i]) >= frac * absf(fin):
			return (i + 1) * DT
	return NAN


func _t_abs(a: Array, lim: float) -> float:
	for i in a.size():
		if absf(a[i]) >= lim:
			return (i + 1) * DT
	return NAN


func _absmax(a: Array) -> float:
	var mx := 0.0
	for v in a:
		mx = maxf(mx, absf(v))
	return mx


## Качание пилота поперёк с отпущенными руками: сдвиг ходом 0,5 за 3 с, затем руки отпущены (arms_relaxed).
func _swing(w: String) -> Dictionary:
	var m := _settled(w)
	var c := S.input(0.0, 0.5)
	for i in int(3.0 / DT):
		m.step(DT, c, Callable(), Callable())
	m.arms_relaxed = true
	c = S.input()
	var ys := []
	var rel0 := _rel(m).y
	for i in int(20.0 / DT):
		m.step(DT, c, Callable(), Callable())
		ys.append(_rel(m).y - rel0)
	# пики |y - среднее скользящее|: ищем локальные максимумы и минимумы
	var ext := []  # [t, y]
	for i in range(1, ys.size() - 1):
		if (ys[i] > ys[i - 1] and ys[i] >= ys[i + 1]) or (ys[i] < ys[i - 1] and ys[i] <= ys[i + 1]):
			ext.append([(i + 1) * DT, ys[i]])
	return {"extrema_t_y": ext.slice(0, 14), "y_t0": ys[0]}


func _dz(x: float) -> float:
	var a := absf(x)
	if a <= DEADZONE:
		return 0.0
	return signf(x) * (a - DEADZONE) / (1.0 - DEADZONE)


const CASES := {
	"a_170_x4_3200": [625.0, 3200.0],
	"b_now_x4_3200": [1000.0, 3200.0],
	"c_now_x1_800": [4000.0, 800.0],
	"c_now_x1_3200": [4000.0, 3200.0],
}


## Синус мыши ±A мм на f Гц: отсчёты округляются (целые), мёртвая зона как в игре. Захват: lock-in.
func _freq(w: String) -> Dictionary:
	var out := {}
	var m0_trim := _settled(w)
	for cs in CASES:
		var travel: float = CASES[cs][0]
		var dpi: float = CASES[cs][1]
		var cd := {}
		for amp_mm in [1.0, 3.0]:
			for f in [0.5, 1.0, 2.0, 4.0]:
				var counts: float = amp_mm / 25.4 * dpi
				var n_per := maxi(3, ceili(6.0 * f))
				var win: float = n_per / f
				var t_tr := 4.0
				var m := _settled(w)
				var n_tr := int(t_tr / DT)
				var n_w := int(win / DT)
				var sp := 0.0
				var cp := 0.0
				var sb := 0.0
				var cb := 0.0
				var sx := 0.0
				var cx := 0.0
				var bmax := 0.0
				for i in n_tr + n_w:
					var t := i * DT
					var cnt := roundf(counts * sin(TAU * f * t))
					var x := _dz(cnt / travel)
					m.step(DT, S.input(0.0, x), Callable(), Callable())
					if i >= n_tr:
						var tw := (i - n_tr) * DT
						var s := sin(TAU * f * t)
						var co := cos(TAU * f * t)
						sp += m.roll_rate * s
						cp += m.roll_rate * co
						sb += m.bank * s
						cb += m.bank * co
						sx += x * s
						cx += x * co
						bmax = maxf(bmax, absf(rad_to_deg(m.bank)))
				var k := 2.0 / n_w
				var P := Vector2(sp, cp) * k  # p = P.x·sin + P.y·cos
				var B := Vector2(sb, cb) * k
				var X := Vector2(sx, cx) * k
				var ph_p := atan2(P.y, P.x) - atan2(X.y, X.x)  # опережение p относительно ввода (рад)
				var ph_b := atan2(B.y, B.x) - atan2(X.y, X.x)
				cd["%s_%dmm_%.1fHz" % [cs, int(amp_mm), f]] = {
					"counts": counts, "frac_amp": counts / travel,
					"input_amp": X.length(), "p_amp_dps": rad_to_deg(P.length()),
					"bank_amp_deg": rad_to_deg(B.length()), "p_phase_lead_deg": rad_to_deg(wrapf(ph_p, -PI, PI)),
					"bank_phase_lead_deg": rad_to_deg(wrapf(ph_b, -PI, PI)), "bank_abs_max_deg": bmax}
		out[cs] = cd
	return out


## Предложение: фильтр первого порядка (τ_cmd) на команду руки (roll) перед моделью. Только прототип в скрипте — игра не меняется.
func _cmdlp(w: String) -> Dictionary:
	var out := {}
	for tau in [0.0, 0.15, 0.3]:
		var d := {}
		# частотный отклик: случай b (1000 отсч., 3200 DPI) ±3 мм и случай a ±1 мм, 0,5/2/4 Гц
		for cs in ["a_170_x4_3200", "b_now_x4_3200"]:
			var travel: float = CASES[cs][0]
			var dpi: float = CASES[cs][1]
			for f in [0.5, 2.0, 4.0]:
				var counts: float = 1.0 / 25.4 * dpi
				var n_per := maxi(3, ceili(6.0 * f))
				var win: float = n_per / f
				var m := _settled(w)
				var n_tr := int(4.0 / DT)
				var n_w := int(win / DT)
				var y := 0.0
				var sp := 0.0
				var cp := 0.0
				for i in n_tr + n_w:
					var t := i * DT
					var x := _dz(roundf(counts * sin(TAU * f * t)) / travel)
					y = x if tau <= 0.0 else y + (x - y) * (1.0 - exp(-DT / tau))
					m.step(DT, S.input(0.0, y), Callable(), Callable())
					if i >= n_tr:
						sp += m.roll_rate * sin(TAU * f * t)
						cp += m.roll_rate * cos(TAU * f * t)
				d["%s_1mm_%.1fHz_p_amp_dps" % [cs, f]] = rad_to_deg(Vector2(sp, cp).length() * 2.0 / n_w)
		# перекладка 45→45 и ступень 0,3: с фильтром
		for A in [30.0, 45.0]:
			var m := _settled(w)
			var hold := S.BankHold.new(deg_to_rad(A), 1.5, 0.8, 0.15)
			var c := S.input()
			var y := 0.0
			for i in int(25.0 / DT):
				var x := hold.roll(m)
				y = x if tau <= 0.0 else y + (x - y) * (1.0 - exp(-DT / tau))
				c.roll = y
				m.step(DT, c, Callable(), Callable())
			var tr := NAN
			for i in int(15.0 / DT):
				y = -1.0 if tau <= 0.0 else y + (-1.0 - y) * (1.0 - exp(-DT / tau))
				c.roll = y
				m.step(DT, c, Callable(), Callable())
				if rad_to_deg(m.bank) <= -A:
					tr = (i + 1) * DT
					break
			d["reversal_%d_s" % int(A)] = tr
		out["tau_%.2f" % tau] = d
	return out
