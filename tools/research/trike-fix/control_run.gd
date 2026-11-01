extends Node
## TKF-2 (TKF-К2): отклик на штангу — дельталёт игрока и дельтапланы в «Маятнике». Запуск (из корня копии):
##   godot --headless --path . res://tools/research/trike-fix/control_run.tscn -- <spec.json> <out.jsonl>
## spec.json — массив прогонов: {name, kind: "trike"|"wing", wing, g (газ 0..1), tests: [...], + переопределения}.
## tests: "settle" (трим), "roll" (скорость крена на 0,25/0,5/1), "t3030", "t4545", "pitch" (тангаж и сила), "bar" (сила штанги).
## Переопределения (диагностика причин): force (предел рук, Н), shift_y (ход поперёк, м), tau (рук, с), mass (кг тележки/пилота),
## thrust_scale, tilt_deg, thrust_split (доля тяги на тележку), cg (cg_below_hang_m), cda, push/pull (ход вдоль, м),
## bank_kp/kd/ki (регулятор крена). Выход: строка JSON на прогон.
## Допущения: плотность 1,225 (как tests/flight/pendulum/pendulum_sim.gd), штиль, воздух/земля — пустые Callable;
## дельталёт: PendulumModel + TrikeRig.ext_force с тягой из configs/tow_tug.json (thrust: idle + g·(full − idle) на воздушной
## скорости, как TrikeEngine._target_thrust) — то же, что делает Glider.setup_trike без визуала и звука.
const S := preload("res://tests/flight/pendulum/pendulum_sim.gd")
const DT := 1.0 / 120.0

var _spec: Dictionary
var _m: PendulumModel
var _rig: TrikeRig
var _tug: Dictionary
var _g := 0.0
var _trike := false


func _interp(xs: Array, ys: Array, x: float) -> float:
	if x <= float(xs[0]):
		return float(ys[0])
	for i in range(1, xs.size()):
		if x <= float(xs[i]):
			var f: float = (x - float(xs[i - 1])) / (float(xs[i]) - float(xs[i - 1]))
			return float(ys[i - 1]) + f * (float(ys[i]) - float(ys[i - 1]))
	return float(ys[xs.size() - 1])


func _make(spec: Dictionary) -> void:
	_spec = spec
	_trike = String(spec.get("kind", "wing")) == "trike"
	_g = float(spec.get("g", 0.0))
	_tug = Config.get_config("tow_tug")
	var env := {"air_density": {"altitude_dependent": false}}
	if _trike:
		var cfg: Dictionary = _tug.duplicate(true)
		var cart: Dictionary = cfg.cart
		if spec.has("cg"):
			cart.cg_below_hang_m = float(spec.cg)
		if spec.has("cda"):
			cart.cda_m2 = float(spec.cda)
		if spec.has("force"):
			cart.arms_force_max_n = float(spec.force)
		if spec.has("push"):
			cart.arms_shift_push_m = float(spec.push)
		if spec.has("pull"):
			cart.arms_shift_pull_m = float(spec.pull)
		if spec.has("tilt_deg"):
			cfg.engine.thrust_tilt_deg = float(spec.tilt_deg)
		var mass := float(spec.get("mass", float(cart.mass_kg)))
		var mp := TrikeRig.model_params(cfg, mass)
		_m = PendulumModel.new()
		_m.setup(mp.wing, mp.pilot, env, mp.apparatus)
		_rig = TrikeRig.new()
		_rig.setup(_m, cfg)
		if spec.has("thrust_split"):
			_rig.thrust_split = float(spec.thrust_split)
		_m.set_external_force(_rig.ext_force)
	else:
		var app := {}
		if spec.has("force"):
			app["arms_force_max_n"] = float(spec.force)
		_m = S.make(String(spec.wing), float(spec.get("mass", 0.0)), app)
		_rig = null
	if spec.has("shift_y"):
		_m.arms.shift_y_max = float(spec.shift_y)
	if spec.has("tau"):
		_m.arms.tau = float(spec.tau)
	S.reset(_m)
	if _trike:
		_rig.refresh(0.0)


func _thrust() -> float:
	var th: Dictionary = _tug.thrust
	var v := S.airspeed(_m)
	var ti := _interp(th.v_ms, th.idle_n, v)
	return (ti + _g * (_interp(th.v_ms, th.full_n, v) - ti)) * float(_spec.get("thrust_scale", 1.0))


func _step(inp: ControlInput) -> void:
	if _trike:
		_rig.thrust_n = _thrust()
	_m.step(DT, inp, Callable(), Callable())
	if _trike:
		_rig.refresh(DT)


func _theta_deg() -> float:
	return rad_to_deg(asin(clampf((-_m.wing_basis().z).normalized().y, -1.0, 1.0)))


func _fd() -> float:
	return Vector2(_m.arms.force_b.x, _m.arms.force_b.y).length()


func _settle(secs: float) -> Dictionary:
	var inp := S.input(0.0, 0.0)
	for i in int(secs / DT):
		_step(inp)
	return {"v_kmh": S.airspeed(_m) * 3.6, "theta_deg": _theta_deg(), "vy": _m.velocity.y, "bank_deg": rad_to_deg(_m.bank),
		"thrust_n": _rig.thrust_n if _trike else 0.0, "alpha_hint_fx": _m.arms.force_b.x}


func _roll_test(r: float) -> Dictionary:
	_make(_spec)
	var st := _settle(float(_spec.get("settle_s", 15.0)))
	var b0 := rad_to_deg(_m.bank)
	var inp := S.input(0.0, r)
	var t := 0.0
	var tb: Dictionary = {}  # время достижения крена 10,20,30,40 (от начала ввода)
	var rate_peak := 0.0
	var sum := 0.0
	var n := 0
	var fy_max := 0.0
	var ser_t: Array = []
	var ser_b: Array = []
	var ser_p: Array = []
	var ser_y: Array = []
	var win_lo := 8.0
	var win_hi := 35.0
	for i in int(float(_spec.get("roll_s", 8.0)) / DT):
		_step(inp)
		t += DT
		var b := rad_to_deg(_m.bank) - b0
		var p := rad_to_deg(_m.roll_rate)
		rate_peak = maxf(rate_peak, p)
		fy_max = maxf(fy_max, absf(_m.arms.force_b.y))
		for k in [10, 20, 30, 40]:
			if not tb.has(str(k)) and b >= k:
				tb[str(k)] = snappedf(t, 0.001)
		if b >= win_lo and b <= win_hi:
			sum += p
			n += 1
		if i % 12 == 0:
			ser_t.append(snappedf(t, 0.01))
			ser_b.append(snappedf(b, 0.01))
			ser_p.append(snappedf(p, 0.01))
			ser_y.append(snappedf(_m.arms.target_b.y - _m.arms.neutral_rel.y, 0.001))
		if b > 60.0 or not S.finite(_m):
			break
	# скорость крена в окне 8–35° по ходу; если окна не прошли — по крену за последние 2 с
	var rate := sum / float(n) if n > 0 else 0.0
	var bank_end := rad_to_deg(_m.bank) - b0
	return {"rate_dps": rate, "rate_peak_dps": rate_peak, "t_to": tb, "bank_end_deg": bank_end, "t_end": t, "fy_max_n": fy_max,
		"rel_y_end_m": _m.pilot_rel.x, "settle": st, "series": {"t": ser_t, "bank": ser_b, "p": ser_p, "ty": ser_y}}


## Ставит устойчивый крен ±deg регулятором, затем полный ход в обратную сторону до -deg. → время, с.
func _reversal(deg: float) -> Dictionary:
	var best: Dictionary = {}
	for gains in [[6.0, 2.5, 1.0], [10.0, 4.0, 2.0], [16.0, 5.0, 3.0], [25.0, 8.0, 5.0], [12.0, 6.0, 3.0], [40.0, 10.0, 8.0], [8.0, 5.0, 0.5], [4.0, 3.0, 0.5]]:
		var r := _reversal_try(deg, gains)
		if best.is_empty() or float(r.get("hold_err_deg", 99.0)) < float(best.get("hold_err_deg", 99.0)):
			best = r
		if float(r.get("hold_err_deg", 99.0)) < 1.5:
			break
	return best


func _reversal_try(deg: float, gains: Array) -> Dictionary:
	_make(_spec)
	_settle(float(_spec.get("settle_s", 15.0)))
	var bh := S.BankHold.new(deg_to_rad(deg), float(gains[0]), float(gains[1]), float(gains[2]))
	var hold_err := 99.0
	var hold_s := float(_spec.get("hold_s", 20.0))
	var n_hold := int(hold_s / DT)
	var errs: Array = []
	for i in n_hold:
		var inp := S.input(0.0, bh.roll(_m))
		_step(inp)
		if i >= n_hold - 120:
			errs.append(absf(rad_to_deg(_m.bank) - deg))
		if not S.finite(_m):
			return {"t_s": null, "note": "не конечно"}
	hold_err = 0.0
	for e: float in errs:
		hold_err = maxf(hold_err, e)
	var bank0 := rad_to_deg(_m.bank)
	var v0 := S.airspeed(_m) * 3.6
	var inp2 := S.input(0.0, -1.0)
	var t := 0.0
	var reached := false
	var ser: Array = []
	var cap := float(_spec.get("rev_cap_s", 30.0))
	var minb := 99.0
	while t < cap:
		_step(inp2)
		t += DT
		var b := rad_to_deg(_m.bank)
		minb = minf(minb, b)
		if int(t / DT) % 12 == 0:
			ser.append([snappedf(t, 0.01), snappedf(b, 0.01)])
		if b <= -deg:
			reached = true
			break
		if not S.finite(_m):
			break
	return {"gains": gains, "t_s": snappedf(t, 0.001) if reached else null, "reached": reached, "hold_err_deg": hold_err, "bank_start_deg": bank0,
		"v0_kmh": v0, "min_bank_deg": minb, "series": ser}


func _pitch_test(sign: float) -> Dictionary:
	_make(_spec)
	var st := _settle(float(_spec.get("settle_s", 15.0)))
	var inp := S.input(sign, 0.0)
	var th: Array = [_theta_deg()]
	var fx: Array = []
	var fmag: Array = []
	var ang: Array = [0.0]
	for i in int(3.0 / DT):
		_step(inp)
		th.append(_theta_deg())
		fx.append(_m.arms.force_b.x)
		fmag.append(_fd())
		var tn := (-_m.wing_basis().z).normalized()
		ang.append(0.0)
	var h := 12  # окно 0,1 с
	var peak := 0.0
	for i in range(h, int(2.0 / DT) + 1):
		peak = maxf(peak, absf(th[i] - th[i - h]) / (h * DT))
	var f_end: float = 0.0
	var cnt := 0
	for i in range(int(2.0 / DT), fx.size()):
		f_end += absf(fx[i])
		cnt += 1
	var fpk := 0.0
	for x: float in fmag:
		fpk = maxf(fpk, x)
	# изменение тангажа к 2 с, 3 с и изменение скорости
	return {"pitch_rate_dps": peak, "dtheta_2s": th[int(2.0 / DT)] - th[0], "dtheta_3s": th[th.size() - 1] - th[0],
		"bar_fx_steady_n": f_end / maxf(cnt, 1), "bar_f_peak_n": fpk, "v_end_kmh": S.airspeed(_m) * 3.6, "settle": st,
		"stick_x_m": _m.arms.target_b.x - _m.arms.neutral_rel.x, "rel_x_end_m": -_m.pilot_rel.z}


## Ручка удержана r: крен через 5/10/15 с (положение ручки → крен?).
func _hold_test(r: float) -> Dictionary:
	_make(_spec)
	_settle(float(_spec.get("settle_s", 15.0)))
	var inp := S.input(0.0, r)
	var out := {}
	for i in int(15.0 / DT):
		_step(inp)
		var t := float(i + 1) * DT
		for k in [2, 5, 10, 15]:
			if absf(t - k) < DT * 0.5:
				out[str(k)] = snappedf(rad_to_deg(_m.bank), 0.1)
		if not S.finite(_m) or absf(_m.bank) > deg_to_rad(85.0):
			out["diverged_s"] = snappedf(t, 0.01)
			break
	return out


## Спираль: ручка в нуле, крен 20° выведен регулятором; через 5/10 с — крен.
func _spiral_test() -> Dictionary:
	_make(_spec)
	_settle(float(_spec.get("settle_s", 15.0)))
	var bh := S.BankHold.new(deg_to_rad(20.0), 10.0, 4.0, 2.0)
	for i in int(12.0 / DT):
		_step(S.input(0.0, bh.roll(_m)))
	var b0 := rad_to_deg(_m.bank)
	var inp := S.input(0.0, 0.0)
	var out := {"b0": snappedf(b0, 0.1)}
	for i in int(15.0 / DT):
		_step(inp)
		var t := float(i + 1) * DT
		for k in [5, 10, 15]:
			if absf(t - k) < DT * 0.5:
				out[str(k)] = snappedf(rad_to_deg(_m.bank), 0.1)
		if not S.finite(_m) or absf(_m.bank) > deg_to_rad(85.0):
			out["diverged_s"] = snappedf(t, 0.01)
			break
	return out


func _run(spec: Dictionary) -> Dictionary:
	_make(spec)
	var res := {"name": spec.name, "spec": spec}
	var tests: Array = spec.get("tests", ["settle", "roll", "t3030", "t4545", "pitch"])
	if "settle" in tests:
		_make(spec)
		res["settle"] = _settle(float(spec.get("settle_s", 15.0)))
		res["mass_kg"] = _m.pilot_mass if "pilot_mass" in _m else 0.0
	if "roll" in tests:
		var rr := {}
		for r in [0.25, 0.5, 1.0]:
			rr[str(r)] = _roll_test(r)
		res["roll"] = rr
	if "t3030" in tests:
		res["t3030"] = _reversal(30.0)
	if "t4545" in tests:
		res["t4545"] = _reversal(45.0)
	if "hold" in tests:
		var hh := {}
		for r in [0.1, 0.25, 0.5]:
			hh[str(r)] = _hold_test(r)
		res["hold"] = hh
	if "spiral" in tests:
		res["spiral"] = _spiral_test()
	if "pitch" in tests:
		res["push"] = _pitch_test(1.0)
		res["pull"] = _pitch_test(-1.0)
	return res


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var specs: Array = JSON.parse_string(FileAccess.get_file_as_string(args[0]))
	var f := FileAccess.open(args[1], FileAccess.WRITE)
	for sp: Dictionary in specs:
		var r := _run(sp)
		f.store_line(JSON.stringify(r))
		f.flush()
		print("TKF2 done ", sp.get("name", ""))
	f.close()
	get_tree().quit()
