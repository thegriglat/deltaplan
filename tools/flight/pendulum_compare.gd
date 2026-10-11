extends Node
## Сверка игры с прототипом (PD-8): пачка сценариев на PendulumModel при умолчаниях класса крыла.
## Каждая строка jsonl — {sc, wing, dt, ...числа}. Протокол сценариев тот же, что у
## tools/research/pendulum/pd8_proto.py (прототип) — таблицы строит pd8_summary.py.
##
## XDG_DATA_HOME=$(mktemp -d) godot --headless --path . res://tools/flight/pendulum_compare.tscn -- \
##     --plan=tools/research/pendulum/out/pd8_plan.json --out=tools/research/pendulum/out/pd8_game.jsonl
## plan.json (pd8_summary.py plan): {"turbulence": {"<зерно>": моды}}; без --plan болтанка пропускается.

const S := preload("res://tests/flight/pendulum/pendulum_sim.gd")
const WINGS := ["training", "laminar", "sport"]
const DT := 1.0 / 120.0
const G := 9.81
## (pitch, секунд) — варианты «на себя» помимо основного (-1, 3)
const DIVE_VARIANTS := [[-1.0, 1.0], [-1.0, 2.0], [-0.5, 3.0], [-0.5, 6.0], [-0.25, 6.0]]

var _out: FileAccess
var _plan: Dictionary = {}
var _cp_shift := true  ## --no-cp-shift: без сдвига ЦД срыва (до PD-18), для сравнения


func _ready() -> void:
	var out_path := "tools/research/pendulum/out/pd8_game.jsonl"
	var plan_path := ""
	var bench := false
	var dive_all := false
	var pd19 := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--pd19="):
			pd19 = a.substr(7)
		if a.begins_with("--out="):
			out_path = a.substr(6)
		elif a == "--no-cp-shift":
			_cp_shift = false
		elif a == "--dive-all":
			dive_all = true
		elif a == "--bench":
			bench = true
		elif a.begins_with("--plan="):
			plan_path = a.substr(7)
	if plan_path != "":
		_plan = JSON.parse_string(FileAccess.get_file_as_string(plan_path))
	_out = FileAccess.open(out_path, FileAccess.WRITE)
	var t0 := Time.get_ticks_msec()
	if bench:
		_bench()
		_out.close()
		get_tree().quit(0)
		return
	if pd19 != "":
		_pd19(JSON.parse_string(FileAccess.get_file_as_string(pd19)))
		_out.close()
		get_tree().quit(0)
		return
	if dive_all:
		_dive_all()
		_out.close()
		get_tree().quit(0)
		return
	for w in WINGS:
		_emit("trim", w, DT, _trim(w, DT))
		_emit("phugoid", w, DT, _phugoid(w, DT))
		_emit("reversal45", w, DT, _reversal(w, 45.0, DT))
		_emit("reversal30", w, DT, _reversal(w, 30.0, DT))
		_emit("fullshift", w, DT, _fullshift(w, DT))
		_emit("center30", w, DT, _center30(w, DT))
		_emit("pendulum", w, DT, _pendulum(w, DT))
		for wind: float in [0.0, 3.0, 6.0]:
			_emit("ground_run_w%d" % int(wind), w, DT, _run_up(w, wind, DT))
		_emit("hold_neutral", w, DT, _hold(w, DT, false))
		_emit("hold_relaxed", w, DT, _hold(w, DT, true))
		_emit("dive", w, DT, _dive(w, DT))
		for v: Array in DIVE_VARIANTS:
			_emit("dive_a%d_t%d" % [roundi(-100.0 * v[0]), roundi(v[1])], w, DT, _dive(w, DT, v[0], v[1]))
		# сходимость по шагу игры
		for dt: float in [1.0 / 60.0, 1.0 / 240.0]:
			_emit("trim", w, dt, _trim(w, dt))
			_emit("reversal45", w, dt, _reversal(w, 45.0, dt))
			_emit("ground_run_w0", w, dt, _run_up(w, 0.0, dt))
			_emit("fullshift", w, dt, _fullshift(w, dt))
			_emit("dive", w, dt, _dive(w, dt))
	_emit("ochi", "laminar", DT, _ochi(DT))
	if _plan.has("turbulence"):
		for seed_key: String in _plan.turbulence:
			for w: String in (WINGS if _plan.get("all_wings", false) else ["laminar"]):
				for dt: float in [DT, 1.0 / 60.0]:
					var r := _turbulence(w, _plan.turbulence[seed_key], dt, 60.0)
					r["seed"] = int(seed_key)
					_emit("turb", w, dt, r)
	_out.close()
	print("pendulum_compare: готово за %.1f с" % ((Time.get_ticks_msec() - t0) / 1000.0))
	get_tree().quit(0)


## PD-18: выход из пикирования («на себя» до упора 3 с, потом нейтраль) на всех крыльях configs/wings;
## 60 с после отпускания. Строка dive_all: время первого входа скорости в 10 % трима при α ниже
## срывного, самый долгий срыв подряд, α и V в конце.
##   --dive-all  (--out=… для jsonl; --no-cp-shift — без сдвига ЦД срыва, для сравнения «до»)
func _dive_all() -> void:
	var names: Array = []
	for f in DirAccess.get_files_at("res://configs/wings"):
		if f.ends_with(".json"):
			names.append(f.get_basename())
	names.sort()
	for w: String in names:
		for v: Array in [[-1.0, 3.0], [-0.5, 3.0]]:
			var m := _model(w)
			var v_trim := S.airspeed(m) * 3.6
			var a_stall: float = m.strips.alpha0_root + m.strips.cl_max / m.strips.lift_slope
			var inp := S.input(v[0])
			var t_trim := NAN
			var streak := 0.0
			var streak_max := 0.0
			var a_max := 0.0
			var v_min := INF
			var v_max := 0.0
			var hold: float = v[1]
			for i in _steps(hold + 60.0, DT):
				if m.time_s >= hold - 1.0e-9:
					inp.pitch = 0.0
				m.step(DT, inp, Callable(), Callable())
				a_max = maxf(a_max, m.alpha)
				if m.time_s < hold:
					continue
				var vk := S.airspeed(m) * 3.6
				v_min = minf(v_min, vk)
				v_max = maxf(v_max, vk)
				if m.alpha > a_stall:
					streak += DT
					streak_max = maxf(streak_max, streak)
				else:
					streak = 0.0
					if is_nan(t_trim) and absf(vk - v_trim) <= 0.10 * v_trim:
						t_trim = m.time_s - hold
			_emit("dive_all_p%d" % roundi(-100.0 * v[0]), w, DT, {
				"V_trim_kmh": v_trim, "alpha_stall_deg": rad_to_deg(a_stall), "t_to_trim_s": t_trim,
				"stall_streak_max_s": streak_max, "alpha_max_deg": rad_to_deg(a_max), "V_min_kmh": v_min,
				"V_max_kmh": v_max, "alpha_end_deg": rad_to_deg(m.alpha), "V_end_kmh": S.airspeed(m) * 3.6,
				"finite": S.finite(m)})


# ----------------------------------------------------------------------------- PD-19
## Пачка PD-19: варианты модели срыва полос × сценарии. plan.json:
## {"variants": [{"name": …, "strips": {свойство PendulumWingStrips: значение}}],
##  "scenarios": ["dive", "turb", "dive_all"], "turbulence": {"ref": моды, "<зерно>": моды},
##  "dts": [120, 60, 30], "trace": false}
## dive — training/laminar/sport, 100 % и 50 % «на себя» 3 с, 60 с после: самый долгий срыв подряд,
## число новых срывов, время, с которого V навсегда в 10 % трима; turb — болтанка 40 с (как
## test_pendulum_robust), блок прототипа и игры; dive_all — 48 крыльев.
func _pd19(plan: Dictionary) -> void:
	var sc: Array = plan.get("scenarios", ["dive", "turb"])
	for vr: Dictionary in plan.variants:
		var vname: String = vr.name
		var props: Dictionary = vr.get("strips", {})
		if "dive" in sc:
			for w: String in WINGS:
				for pull: float in [1.0, 0.5]:
					var r := _pd19_dive(_pd19_model(w, props, false), pull, plan.get("trace", false))
					r["variant"] = vname
					_emit("pd19_dive_p%d" % roundi(pull * 100.0), w, DT, r)
		if "dive_all" in sc:
			var names: Array = []
			for f in DirAccess.get_files_at("res://configs/wings"):
				if f.ends_with(".json"):
					names.append(f.get_basename())
			names.sort()
			for w: String in names:
				for pull: float in [1.0, 0.5]:
					var r := _pd19_dive(_pd19_model(w, props, false), pull, false)
					r["variant"] = vname
					r.erase("series")
					_emit("pd19_diveall_p%d" % roundi(pull * 100.0), w, DT, r)
		if "turnstall" in sc:
			for w: String in ["training", "sport"]:
				var r := _pd19_turnstall(_pd19_model(w, props, false))
				r["variant"] = vname
				_emit("pd19_turnstall", w, DT, r)
		if "spin" in sc:
			for w: String in plan.get("spin_wings", ["training", "laminar", "sport"]):
				for ramp: float in plan.get("spin_ramps", [10.0]):
					for after: String in plan.get("spin_after", ["push"]):
						var r := _pd22_spin(_pd19_model(w, props, false), ramp, after, plan.get("trace", false),
							float(plan.get("spin_rec_pull", -0.5)), float(plan.get("spin_rec_hold", 2.0)),
							float(plan.get("spin_ease_hold", 2.0)), float(plan.get("spin_ease", 2.0)))
						r["variant"] = vname
						r["ramp_s"] = ramp
						r["after"] = after
						_emit("pd22_spin", w, DT, r)
		if "phug" in sc:
			for w: String in WINGS:
				for dv: float in [1.0, 2.0, 3.0, 4.0, 6.0]:
					var m := _pd19_model(w, props, false)
					var r := _pd19_phug(m, dv)
					r["variant"] = vname
					r["dv"] = dv
					_emit("pd19_phug", w, DT, r)
		if "landing" in sc:
			for w: String in WINGS:
				for wind: float in [0.0, 3.0]:
					var best := 99.0
					var best_r := {}
					var best_h := 0.0
					for fh: float in [1.0, 1.25, 1.5, 1.75, 2.0, 2.25, 2.5, 2.75, 3.0, 3.5, 6.0]:
						var r := _pd19_landing(w, props, wind, fh)
						var q := maxf(float(r.get("vertical_speed_ms", 99.0)) / 5.0, float(r.get("horizontal_speed_ms", 99.0)) / 3.0)
						if plan.get("landing_all", false):
							_emit("pd22_flare", w, DT, {"variant": vname, "wind": wind, "flare_h": fh, "score": q,
								"grade": r.get("grade", "?"), "v": r.get("vertical_speed_ms", NAN),
								"h": r.get("horizontal_speed_ms", NAN)})
						if fh == 6.0:
							_emit("pd19_flare6", w, DT, {"variant": vname, "wind": wind, "grade": r.get("grade", "?"),
								"v": r.get("vertical_speed_ms", NAN), "h": r.get("horizontal_speed_ms", NAN)})
						elif q < best:
							best = q
							best_r = r
							best_h = fh
					_emit("pd19_landing", w, DT, {"variant": vname, "wind": wind, "score": best, "flare_h": best_h,
						"grade": best_r.get("grade", "?"), "v": best_r.get("vertical_speed_ms", NAN),
						"h": best_r.get("horizontal_speed_ms", NAN)})
		if "turb" in sc:
			for w: String in WINGS:
				for proto: bool in plan.get("blocks", [true, false]):
					for hz: int in plan.get("dts", [120, 60, 30]):
						for fk: String in plan.turbulence:
							var m := _pd19_model(w, props, proto)
							var r := _pd19_turb(m, plan.turbulence[fk], 1.0 / hz, plan.get("trace", false))
							r["variant"] = vname
							r["field"] = fk
							r["proto_block"] = proto
							r["hz"] = hz
							_emit("pd19_turb", w, 1.0 / hz, r)


## Заход с 12 м на триме, выравнивание «от себя» до упора со ступней на flare_h (как
## test_pendulum_ground_landing.approach). → landing_result.
func _pd19_landing(w: String, props: Dictionary, wind: float, flare_h: float) -> Dictionary:
	var m := _pd19_model(w, props, false)
	var flat := func(_x: float, _z: float) -> float: return 0.0
	var wv := Vector3(0.0, 0.0, wind)
	var air := func(_p: Vector3) -> Vector3: return wv
	m.reset_in_air(Vector3(0.0, 12.0, 0.0), 0.0, 0.0, wv)
	var inp := S.input()
	var t := 0.0
	while m.mode == FlightModel.Mode.AIR and t < 60.0:
		if m.pilot_position.y - 1.0 < flare_h:
			inp.pitch = 1.0
		m.step(DT, inp, air, flat)
		t += DT
	return m.landing_result


## Вираж 30° вправо (пилот держит крен), «от себя» плавно 0 → 1 за 10 с до первого срыва полосы;
## 3 с после срыва — руки как были; потом выход: «на себя» 0,5 на 2 с, затем нейтраль и крен к 0.
## → какая консоль сорвалась первой, крен/курс за 3 с, время выхода и потеря высоты.
func _pd19_turnstall(m: PendulumModel) -> Dictionary:
	var v_trim := S.airspeed(m) * 3.6
	var a_stall: float = m.strips.alpha0_root + m.strips.cl_max / m.strips.lift_slope
	var hb := Hold.new(deg_to_rad(30.0), 6.0, 2.5, 1.0)
	var inp := S.input()
	for i in _steps(14.0, DT):
		inp.roll = hb.roll(m, DT)
		m.step(DT, inp, Callable(), Callable())
	var t0 := m.time_s
	var h := m.strips.n / 2
	var t_st := NAN
	var first := ""
	var bank0 := 0.0
	var hd0 := 0.0
	var h0 := 0.0
	var rec_t := NAN
	var h_min := INF
	var out := {}
	var phase := 0
	var t_rec0 := 0.0
	for i in _steps(60.0, DT):
		var t := m.time_s - t0
		if phase == 0:
			inp.pitch = clampf(t / 10.0, 0.0, 1.0)
			inp.roll = hb.roll(m, DT)
		elif phase == 1:
			inp.roll = hb.roll(m, DT)
		else:
			inp.pitch = -0.5 if m.time_s - t_rec0 < 2.0 else 0.0
			hb.target = 0.0
			inp.roll = hb.roll(m, DT)
		m.step(DT, inp, Callable(), Callable())
		if phase == 0:
			var r_st := false
			var l_st := false
			var r_list := ""
			var l_list := ""
			for j in h:
				if m.strips.blend[j] > 0.01:
					r_st = true
					r_list += str(j)
				if m.strips.blend[j + h] > 0.01:
					l_st = true
					l_list += str(j)
			if r_st or l_st:
				t_st = t
				first = "обе" if r_st and l_st else ("правая (внутренняя)" if r_st else "левая (внешняя)")
				out["strips_right"] = r_list
				out["strips_left"] = l_list
				out["pitch_at_stall"] = inp.pitch
				out["V_at_stall_kmh"] = S.airspeed(m) * 3.6
				bank0 = rad_to_deg(m.bank)
				hd0 = rad_to_deg(m.heading)
				h0 = m.position.y
				phase = 1
		elif phase == 1:
			if t - t_st >= 3.0:
				out["bank_after3_deg"] = rad_to_deg(m.bank)
				out["bank_change3_deg"] = rad_to_deg(m.bank) - bank0
				out["heading_change3_deg"] = wrapf(rad_to_deg(m.heading) - hd0, -180.0, 180.0)
				out["stall_frac_3s"] = m.stall_amount()
				out["V_3s_kmh"] = S.airspeed(m) * 3.6
				out["h_loss_3s_m"] = h0 - m.position.y
				phase = 2
				t_rec0 = m.time_s
		else:
			h_min = minf(h_min, m.position.y)
			var vk := S.airspeed(m) * 3.6
			if is_nan(rec_t) and m.time_s - t_rec0 > 2.0 and m.alpha < a_stall and absf(rad_to_deg(m.bank)) < 10.0 and absf(vk - v_trim) < 0.1 * v_trim and m.stall_amount() == 0.0:
				rec_t = m.time_s - t_rec0
				out["h_loss_total_m"] = h0 - h_min
				break
	out["V_trim_kmh"] = v_trim
	out["t_stall_s"] = t_st
	out["first"] = first
	out["recover_s"] = rec_t
	out["bank_max_deg"] = 0.0
	return out


## Фугоида: сброс на триме с V + dv, руки в нейтрали, 60 с. Пики V → отношение амплитуд за период.
func _pd19_phug(m: PendulumModel, dv: float) -> Dictionary:
	var v_trim := S.airspeed(m)
	m.reset_in_air(m.position, 0.0, v_trim + dv)
	var inp := S.input()
	var vs: PackedFloat64Array = []
	var stall_t := 0.0
	var a_max := -INF
	var a_min := INF
	for i in _steps(60.0, DT):
		m.step(DT, inp, Callable(), Callable())
		vs.append(S.airspeed(m))
		if m.stall_amount() > 0.0:
			stall_t += DT
		a_max = maxf(a_max, rad_to_deg(m.alpha))
		a_min = minf(a_min, rad_to_deg(m.alpha))
	var pk: Array = []
	for i in range(1, vs.size() - 1):
		if vs[i] > vs[i - 1] and vs[i] >= vs[i + 1]:
			pk.append([i * DT, vs[i]])
	var amps: Array = []
	for q: Array in pk:
		amps.append(snappedf((q[1] - v_trim) * 3.6, 0.01))
	return {"V_trim_kmh": v_trim * 3.6, "peak_amps_kmh": amps.slice(0, 10),
		"t_first_peaks": pk.slice(0, 3).map(func(q: Array) -> float: return snappedf(q[0], 0.01)),
		"stall_s": stall_t, "alpha_max_deg": a_max, "alpha_min_deg": a_min}


func _pd19_model(w: String, props: Dictionary, proto: bool) -> PendulumModel:
	var m := S.make(w, 0.0, {}, proto)
	var strip_props := 0
	for k: String in props:
		if k not in ["model", "arms", "cl_max_mult"]:
			strip_props += 1
		if k == "cd90_sweep_norm":
			# PD-35: false — C_N 90° без поправки cos²Λ (как до PD-35)
			if not bool(props[k]):
				m.strips.cd90 /= m.strips.cos_sweep * m.strips.cos_sweep
		elif k == "model":
			for q: String in props.model:
				m.set(q, props.model[q])
		elif k == "arms":
			for q: String in props.arms:
				m.arms.set(q, props.arms[q])
		elif k != "cl_max_mult":
			m.strips.set(k, props[k])
	if strip_props > 0 and bool(m.pendulum.get("strip_cl_max_match_polar", true)):
		m.strips.match_polar_cl_max()
	if props.has("cl_max_mult"):
		m.strips.cl_max *= float(props.cl_max_mult)
	S.reset(m)
	return m


func _pd19_dive(m: PendulumModel, pull: float, trace: bool) -> Dictionary:
	var hold := 3.0
	var v_trim := S.airspeed(m) * 3.6
	var a_stall: float = m.strips.alpha0_root + m.strips.cl_max / m.strips.lift_slope
	var inp := S.input(-pull)
	var streak := 0.0
	var streak_max := 0.0
	var entries := 0
	var was := false
	var t_out10 := 0.0
	var v_min20 := INF
	var v_max20 := 0.0
	var a_max20 := -INF
	var ph_max := 0.0
	var ser: Array = []
	for i in _steps(hold + 60.0, DT):
		if m.time_s >= hold - 1.0e-9:
			inp.pitch = 0.0
		m.step(DT, inp, Callable(), Callable())
		if m.time_s < hold:
			continue
		var t := m.time_s - hold
		var vk := S.airspeed(m) * 3.6
		var st := m.alpha > a_stall
		if st:
			streak += DT
			streak_max = maxf(streak_max, streak)
			if not was:
				entries += 1
		else:
			streak = 0.0
		was = st
		if absf(vk - v_trim) > 0.10 * v_trim:
			t_out10 = t
		ph_max = maxf(ph_max, absf(rad_to_deg(m.bank)))
		if t >= 20.0:
			v_min20 = minf(v_min20, vk)
			v_max20 = maxf(v_max20, vk)
			a_max20 = maxf(a_max20, rad_to_deg(m.alpha))
		if trace and i % 30 == 0:
			ser.append([snappedf(t, 0.01), snappedf(rad_to_deg(m.alpha), 0.1), snappedf(rad_to_deg(m.theta), 0.1),
				snappedf(vk, 0.1), snappedf(m.stall_amount(), 0.01), snappedf(rad_to_deg(m.bank), 0.1)])
	return {"V_trim_kmh": v_trim, "alpha_stall_deg": rad_to_deg(a_stall), "stall_streak_max_s": streak_max,
		"stall_entries": entries, "t_out10_s": t_out10, "V_min20_kmh": v_min20, "V_max20_kmh": v_max20,
		"alpha_max20_deg": a_max20, "bank_max_deg": ph_max, "finite": S.finite(m), "series": ser}


func _pd19_turb(m: PendulumModel, modes: Dictionary, dt: float, trace := false) -> Dictionary:
	var off := S.cg(m) - S.START_CG
	var tb := S.Turbulence.new(modes, off)
	var air := tb.air
	var bh := Hold.new(0.0, 1.5, 0.8, 0.3)
	var inp := S.input()
	var phi: PackedFloat64Array = []
	var blow := false
	var t_stall := 0.0
	var t_stall25 := 0.0
	var t_full := 0.0
	var a_max := -INF
	var ser: Array = []
	var every := maxi(1, roundi(0.1 / dt))
	for i in _steps(40.0, dt):
		inp.roll = bh.roll(m, dt)
		m.step(dt, inp, air, Callable())
		if trace and i % every == 0:
			var bl := ""
			for j in m.strips.n:
				bl += str(mini(9, int(m.strips.blend[j] * 9.99)))
			ser.append([snappedf(m.time_s, 0.01), snappedf(rad_to_deg(m.alpha), 0.1), snappedf(rad_to_deg(m.theta), 0.1),
				snappedf(S.airspeed(m) * 3.6, 0.1), bl, snappedf(rad_to_deg(m.bank), 0.1), snappedf(inp.roll, 0.01),
				snappedf(rad_to_deg(m.roll_rate), 0.1)])
		if not S.finite(m) or S.airspeed(m) > 80.0:
			blow = true
			break
		if m.time_s > 10.0:
			phi.append(rad_to_deg(m.bank))
			if m.stall_amount() > 0.0:
				t_stall += dt
			if m.stall_amount() >= 0.25:
				t_stall25 += dt
			for j in m.strips.n:
				if m.strips.blend[j] >= 1.0:
					t_full += dt
					break
			a_max = maxf(a_max, rad_to_deg(m.alpha))
	var mx := 0.0
	for v in phi:
		mx = maxf(mx, absf(v))
	return {"blowup": blow, "std_phi_deg": _std(phi), "max_abs_phi_deg": mx, "max_stretch_m": m.chain.max_stretch,
		"t_stall_s": t_stall, "t_stall25_s": t_stall25, "t_stall_full_s": t_full, "alpha_max_deg": a_max, "series": ser}


## PD-22: сваливание на крыло в вираже. Вираж 30° вправо 14 с (пилот держит крен), «от себя» 0 → 1
## за ramp с до первого срыва полосы; дальше руки по крену замирают, «от себя» — after: "push" —
## дожимать к упору, "keep" — держать; 6 с; потом выход по Жеглову (с. 112, 122): «на себя» 0,5 на
## 2 с, затем нейтраль, крен к 0. Выход — |крен| < 10°, V в 10 % трима, срыва нет, 2 с подряд.
func _pd22_spin(m: PendulumModel, ramp: float, after: String, trace: bool, rec_pull := -0.5, rec_hold := 2.0,
		rec_ease_hold := 2.0, rec_ease := 2.0) -> Dictionary:
	var v_trim := S.airspeed(m) * 3.6
	var hb := Hold.new(deg_to_rad(30.0), 6.0, 2.5, 1.0)
	var inp := S.input()
	for i in _steps(14.0, DT):
		inp.roll = hb.roll(m, DT)
		m.step(DT, inp, Callable(), Callable())
	var h := m.strips.n / 2
	var t0 := m.time_s
	var out := {"V_trim_kmh": v_trim}
	var phase := 0
	var t_st := NAN
	var roll_frz := 0.0
	var p_st := 0.0
	var h0 := 0.0
	var hd_prev := m.heading
	var bank0 := 0.0
	var ser: Array = []
	var bank_max := 0.0
	var bank_min := 999.0
	var yaw_sum := 0.0
	var yaw_n := 0
	var sink_max := 0.0
	var v_min := INF
	var v_max := 0.0
	var a_max := -INF
	var stall_max := 0.0
	var t_rec0 := 0.0
	var rec_since := NAN
	var rec_t := NAN
	var h_rec := NAN
	var first_r := -1.0
	var first_l := -1.0
	var pulling := true
	var bank_rec_max := 0.0
	var v_rec_max := 0.0
	var t_rel := 0.0
	var stalled_n := 0
	var yaw_prev := 0.0
	for i in _steps(90.0, DT):
		var t := m.time_s - t0
		if phase == 0:
			inp.pitch = clampf(t / ramp, 0.0, 1.0)
			inp.roll = hb.roll(m, DT)
		elif phase == 1:
			inp.roll = roll_frz
			if after == "push":
				inp.pitch = clampf(t / ramp, 0.0, 1.0)
		else:
			# rec_hold < 0: «на себя», пока не кончится вращение и срыв (не меньше 1 с, не больше 10 с)
			var tr := m.time_s - t_rec0
			if rec_hold >= 0.0:
				inp.pitch = rec_pull if tr < rec_hold else 0.0
			else:
				# вращение кончилось — rec_ease > 0: ещё rec_ease_hold с «на себя», потом к нейтрали за rec_ease с;
				# rec_ease ≤ 0 — отдача по скорости
				if pulling and tr >= 1.0 and (tr >= 10.0 or (stalled_n == 0 and absf(yaw_prev) < deg_to_rad(45.0))):
					pulling = false
					out["pull_s"] = tr
					t_rel = tr
				if pulling:
					inp.pitch = rec_pull
					# против вращения (Жеглов: смещение против крена — в сторону, противоположную
					# свалившейся консоли; угол крена Эйлера на крутом пикировании штопора не годится)
					inp.roll = -signf(yaw_prev)
				elif rec_ease <= 0.0:
					# отдача по скорости: «на себя», пока V выше трима (−1 при V ≥ трим·(1 + 1/k)), без свечи
					inp.pitch = clampf(rec_ease * (S.airspeed(m) * 3.6 - v_trim) / v_trim, -1.0, 0.0)
				else:
					inp.pitch = rec_pull * clampf(1.0 - (tr - t_rel - rec_ease_hold) / rec_ease, 0.0, 1.0)
			hb.target = 0.0
			var hr := hb.roll(m, DT)
			if not (rec_hold < 0.0 and pulling):
				inp.roll = hr
		m.step(DT, inp, Callable(), Callable())
		var yaw_rate := wrapf(m.heading - hd_prev, -PI, PI) / DT
		hd_prev = m.heading
		var nr := 0
		var nl := 0
		for j in h:
			if m.strips.blend[j] > 0.01:
				nr += 1
			if m.strips.blend[j + h] > 0.01:
				nl += 1
		stalled_n = nr + nl
		yaw_prev = yaw_rate
		if phase == 0 and nr + nl > 0:
			phase = 1
			t_st = t
			roll_frz = inp.roll
			p_st = inp.pitch
			h0 = m.position.y
			bank0 = rad_to_deg(m.bank)
			out["first"] = "обе" if nr > 0 and nl > 0 else ("внутренняя" if nr > 0 else "внешняя")
			out["n_inner_at_stall"] = nr
			out["n_outer_at_stall"] = nl
			out["V_at_stall_kmh"] = S.airspeed(m) * 3.6
			out["bank_at_stall_deg"] = bank0
			var mg: Array = []
			for j in m.strips.n:
				mg.append(snappedf(rad_to_deg(m.strips.margin[j]), 0.1))
			out["margin_at_stall_deg"] = mg
			var vb: Vector3 = m.wing_basis().transposed() * m.velocity
			out["beta_at_stall_deg"] = rad_to_deg(atan2(vb.x, -vb.z))
			out["roll_in_at_stall"] = inp.roll
			out["arm_fy_at_stall_n"] = m.arms.force_b.y
		elif phase == 1:
			bank_max = maxf(bank_max, rad_to_deg(m.bank))
			bank_min = minf(bank_min, rad_to_deg(m.bank))
			yaw_sum += yaw_rate
			yaw_n += 1
			sink_max = maxf(sink_max, -m.velocity.y)
			v_min = minf(v_min, S.airspeed(m) * 3.6)
			v_max = maxf(v_max, S.airspeed(m) * 3.6)
			a_max = maxf(a_max, rad_to_deg(m.alpha))
			stall_max = maxf(stall_max, m.stall_amount())
			if first_r < 0.0 and nr >= 4:
				first_r = t - t_st
			if first_l < 0.0 and nl >= 4:
				first_l = t - t_st
			if t - t_st >= 6.0:
				phase = 2
				t_rec0 = m.time_s
				out["bank_6s_deg"] = rad_to_deg(m.bank)
				out["V_6s_kmh"] = S.airspeed(m) * 3.6
				out["h_loss_6s_m"] = h0 - m.position.y
		else:
			# выход: срыва нет, |крен| < 15°, вращения нет (|dψ/dt| < 20°/с) — 3 с подряд (фугоида после
			# пикирования — отдельно, PD-19); переворот в выходе — |крен| > 120°
			bank_rec_max = maxf(bank_rec_max, absf(rad_to_deg(m.bank)))
			v_rec_max = maxf(v_rec_max, S.airspeed(m) * 3.6)
			var ok := absf(rad_to_deg(m.bank)) < 15.0 and absf(rad_to_deg(yaw_rate)) < 20.0 and nr + nl == 0
			if ok:
				if is_nan(rec_since):
					rec_since = m.time_s
					h_rec = m.position.y
				elif m.time_s - rec_since >= 3.0:
					rec_t = rec_since - t_rec0
					break
			else:
				rec_since = NAN
		if trace and i % 30 == 0:
			ser.append([snappedf(t, 0.01), phase, snappedf(inp.pitch, 0.01), snappedf(inp.roll, 0.01),
				snappedf(rad_to_deg(m.bank), 0.1), snappedf(rad_to_deg(yaw_rate), 0.1),
				snappedf(S.airspeed(m) * 3.6, 0.1), snappedf(rad_to_deg(m.alpha), 0.1),
				snappedf(-m.velocity.y, 0.01), nr, nl, snappedf(m.position.y, 0.1)])
	out["t_stall_s"] = t_st
	out["pitch_at_stall"] = p_st
	out["bank_max_deg"] = bank_max
	out["bank_min_deg"] = bank_min
	out["yaw_rate_mean_dps"] = rad_to_deg(yaw_sum / maxf(yaw_n, 1))
	out["sink_max_ms"] = sink_max
	out["V_min_kmh"] = v_min
	out["V_max_kmh"] = v_max
	out["alpha_max_deg"] = a_max
	out["stall_frac_max"] = stall_max
	out["t_inner4_s"] = first_r
	out["t_outer4_s"] = first_l
	out["recover_s"] = rec_t
	out["bank_rec_max_deg"] = bank_rec_max
	out["V_rec_max_kmh"] = v_rec_max
	out["h_loss_total_m"] = h0 - h_rec if not is_nan(rec_t) else NAN
	out["series"] = ser
	return out


func _emit(sc: String, wing: String, dt: float, d: Dictionary) -> void:
	d["sc"] = sc
	d["wing"] = wing
	d["dt"] = dt
	_out.store_line(JSON.stringify(d))
	_out.flush()
	print(sc, " ", wing, " dt=1/", roundi(1.0 / dt))


# ----------------------------------------------------------------------------- помощники
class Hold:
	var target: float
	var kp: float
	var kd: float
	var ki: float
	var i := 0.0

	func _init(t: float, kp_: float, kd_: float, ki_: float) -> void:
		target = t
		kp = kp_
		kd = kd_
		ki = ki_

	## интегратор — ki·e/120 за 1/120 с, то есть ki·e·dt (прототип: ki·e/120 при dt 1/120)
	func roll(m: PendulumModel, dt: float) -> float:
		var e := target - m.bank
		i = clampf(i + ki * e * dt, -1.0, 1.0)
		return clampf(kp * e - kd * m.roll_rate + i, -1.0, 1.0)


func _model(w: String, mass := 0.0) -> PendulumModel:
	var m := S.make(w, mass)
	m.strips.stall_cp_shift = _cp_shift
	S.reset(m)
	return m


func _med(a: PackedFloat64Array) -> float:
	var b := a.duplicate()
	b.sort()
	var n := b.size()
	return b[n / 2] if n % 2 == 1 else 0.5 * (b[n / 2 - 1] + b[n / 2])


func _std(x: PackedFloat64Array) -> float:
	if x.is_empty():
		return NAN
	var s := 0.0
	for v in x:
		s += v
	var mean := s / x.size()
	var q := 0.0
	for v in x:
		q += (v - mean) * (v - mean)
	return sqrt(q / x.size())


func _interp(t: PackedFloat64Array, x: PackedFloat64Array, tt: float) -> float:
	if t.is_empty() or tt < t[0] or tt > t[t.size() - 1]:
		return NAN
	for i in range(1, t.size()):
		if t[i] >= tt:
			var f := (tt - t[i - 1]) / maxf(t[i] - t[i - 1], 1.0e-12)
			return lerpf(x[i - 1], x[i], f)
	return x[x.size() - 1]


func _first_below(t: PackedFloat64Array, x: PackedFloat64Array, thr: float) -> float:
	for i in x.size():
		if x[i] <= thr:
			return t[i]
	return NAN


func _steps(T: float, dt: float) -> int:
	return int(round(T / dt))


# ----------------------------------------------------------------------------- сценарии
func _trim(w: String, dt: float) -> Dictionary:
	var m := _model(w)
	var inp := S.input()
	var sv := 0.0
	var ss := 0.0
	var sa := 0.0
	var st := 0.0
	var sth := 0.0
	var k := 0
	for i in _steps(30.0, dt):
		m.step(dt, inp, Callable(), Callable())
		if m.time_s > 15.0:
			sv += S.airspeed(m)
			ss += m._vel.z
			sa += m.alpha
			sth += m.theta
			st += m.strap_tension
			k += 1
	return {"V_kmh": sv / k * 3.6, "sink_ms": ss / k, "alpha_deg": rad_to_deg(sa / k),
		"theta_deg": rad_to_deg(sth / k), "tension_N": st / k, "finite": S.finite(m)}


func _phugoid(w: String, dt: float, dv := 3.0) -> Dictionary:
	var m := _model(w)
	var v0: Vector3 = m._vel
	m._vel = v0 * (1.0 + dv / v0.length())
	var d: Vector3 = m._vel - m.chain.pilot_vel()
	var vv := m.chain.v
	for i in vv.size():
		vv[i] += d
	m.chain.v = vv
	var inp := S.input()
	var t: PackedFloat64Array = []
	var V: PackedFloat64Array = []
	for i in _steps(60.0, dt):
		m.step(dt, inp, Callable(), Callable())
		t.append(m.time_s)
		V.append(S.airspeed(m))
	var pk: Array[int] = []
	for i in range(1, V.size() - 1):
		if V[i] > V[i - 1] and V[i] >= V[i + 1]:
			pk.append(i)
	var per := NAN
	var ratio := NAN
	if pk.size() >= 3:
		var dd: PackedFloat64Array = []
		for j in range(1, pk.size()):
			dd.append(t[pk[j]] - t[pk[j - 1]])
		per = _med(dd)
		var vm := _med(V.slice(V.size() - _steps(5.0, dt)))
		ratio = (V[pk[1]] - vm) / (V[pk[0]] - vm)
	return {"period_s": per, "amp_ratio": ratio, "finite": S.finite(m)}


func _hold_bank(m: PendulumModel, target_deg: float, T: float, dt: float, kp := 6.0, kd := 2.5, ki := 1.0) -> void:
	var bh := Hold.new(deg_to_rad(target_deg), kp, kd, ki)
	var inp := S.input()
	for i in _steps(T, dt):
		inp.roll = bh.roll(m, dt)
		m.step(dt, inp, Callable(), Callable())


func _reversal(w: String, bank: float, dt: float) -> Dictionary:
	var m := _model(w)
	_hold_bank(m, bank, 14.0, dt)
	var phi0 := rad_to_deg(m.bank)
	var inp := S.input(0.0, -1.0)
	var t: PackedFloat64Array = []
	var phi: PackedFloat64Array = []
	var t0 := m.time_s
	for i in _steps(12.0, dt):
		m.step(dt, inp, Callable(), Callable())
		t.append(m.time_s - t0)
		phi.append(m.bank)
	return {"phi_start": phi0, "t_to_minus": _first_below(t, phi, deg_to_rad(-bank)),
		"t_to_zero": _first_below(t, phi, 0.0), "phi_t2": rad_to_deg(_interp(t, phi, 2.0)),
		"finite": S.finite(m)}


func _fullshift(w: String, dt: float) -> Dictionary:
	var m := _model(w)
	var inp := S.input(0.0, 1.0)
	var t: PackedFloat64Array = []
	var phi: PackedFloat64Array = []
	var t0 := m.time_s
	for i in _steps(15.0, dt):
		m.step(dt, inp, Callable(), Callable())
		t.append(m.time_s - t0)
		phi.append(m.bank)
	var out := {"finite": S.finite(m)}
	for x: float in [1.0, 2.0, 4.0, 6.0, 10.0, 15.0]:
		out["phi_%ds" % int(x)] = rad_to_deg(_interp(t, phi, x))
	return out


## Вираж 30° (регулятор 14 с), затем руки в центр: крен через 10 и 20 с.
func _center30(w: String, dt: float) -> Dictionary:
	var m := _model(w)
	_hold_bank(m, 30.0, 14.0, dt)
	var phi0 := rad_to_deg(m.bank)
	var inp := S.input()
	var t: PackedFloat64Array = []
	var phi: PackedFloat64Array = []
	var t0 := m.time_s
	for i in _steps(25.0, dt):
		m.step(dt, inp, Callable(), Callable())
		t.append(m.time_s - t0)
		phi.append(m.bank)
	return {"phi_start": phi0, "phi_10s": rad_to_deg(_interp(t, phi, 10.0)),
		"phi_20s": rad_to_deg(_interp(t, phi, 20.0)), "finite": S.finite(m)}


func _pendulum(w: String, dt: float) -> Dictionary:
	var out := {}
	for ax: int in [1, 0]:
		var key := "lat" if ax == 1 else "lon"
		var m := _model(w)
		var inp := S.input()
		for i in _steps(3.0, dt):
			m.step(dt, inp, Callable(), Callable())
		var dv := Vector3.ZERO
		dv[ax] = 0.5
		var vv := m.chain.v
		vv[vv.size() - 1] += m._R * dv
		m.chain.v = vv
		m.arms_relaxed = true
		var t: PackedFloat64Array = []
		var x: PackedFloat64Array = []
		var t0 := m.time_s
		for i in _steps(20.0, dt):
			m.step(dt, inp, Callable(), Callable())
			t.append(m.time_s - t0)
			x.append(S.rel_b(m)[ax])
		var med := _med(x.slice(x.size() - _steps(2.0, dt)))
		var zc: PackedFloat64Array = []
		var pk: PackedFloat64Array = []
		for i in range(1, x.size()):
			if x[i - 1] - med < 0.0 and x[i] - med >= 0.0:
				zc.append(t[i])
		for i in range(1, x.size() - 1):
			var a := absf(x[i] - med)
			if a >= absf(x[i - 1] - med) and a > absf(x[i + 1] - med):
				pk.append(a)
		var d: PackedFloat64Array = []
		for j in range(1, zc.size()):
			d.append(zc[j] - zc[j - 1])
		out[key + "_period_s"] = _med(d) if d.size() >= 2 else NAN
		out[key + "_ratio"] = pk[2] / pk[0] if pk.size() >= 3 and pk[0] > 0.0 else NAN
	return out


func _ochi(dt: float) -> Dictionary:
	var m := _model("laminar", 72.6)
	var inp := S.input()
	for i in _steps(2.0, dt):
		m.step(dt, inp, Callable(), Callable())
	var t0 := m.time_s
	var phi7 := NAN
	var phi_max := -INF
	for i in _steps(12.0, dt):
		var t := m.time_s - t0
		m.hands_force_y = 30.0 if t < 8.5 - 1.0e-9 else NAN
		m.step(dt, inp, Callable(), Callable())
		if is_nan(phi7) and m.time_s - t0 >= 7.0 - 1.0e-6:
			phi7 = rad_to_deg(m.bank)
		phi_max = maxf(phi_max, rad_to_deg(m.bank))
	return {"phi_7s": phi7, "phi_max": phi_max, "finite": S.finite(m)}


func _run_up(w: String, wind: float, dt: float) -> Dictionary:
	var m := S.make(w)
	var k := tan(deg_to_rad(15.0))
	var g := func(_x: float, z: float) -> float: return k * z
	var a := deg_to_rad(15.0)
	var air := func(_p: Vector3) -> Vector3: return Vector3(0.0, wind * sin(a), wind * cos(a))
	m.reset_on_ground(Vector3.ZERO, 0.0)
	var x0 := m.pilot_position
	var t := 0.0
	var inp := S.input()
	while t < 25.0:
		inp.run = t > 1.0 - 1.0e-9
		m.step(dt, inp, air, g)
		t += dt
		if m.mode == FlightModel.Mode.FAILED:
			return {"t_liftoff": NAN, "failure": m.takeoff_failure}
		if m.mode == FlightModel.Mode.AIR:
			return {"t_liftoff": t, "x_liftoff": -(m.pilot_position.z - x0.z),
				"v_liftoff_kmh": m.telemetry.airspeed * 3.6}
	return {"t_liftoff": NAN, "failure": "no_takeoff"}


## Горизонтальный полёт руками в нейтрали (или руки отпущены) в штиле: держится ли трим.
func _hold(w: String, dt: float, relaxed: bool) -> Dictionary:
	var m := _model(w)
	m.arms_relaxed = relaxed
	var inp := S.input()
	var th: PackedFloat64Array = []
	var V: PackedFloat64Array = []
	var phi: PackedFloat64Array = []
	var h10 := 0.0
	var h_set := false
	for i in _steps(60.0, dt):
		m.step(dt, inp, Callable(), Callable())
		if m.time_s > 10.0:
			if not h_set:
				h_set = true
				h10 = m.heading
			th.append(rad_to_deg(m.theta))
			V.append(S.airspeed(m) * 3.6)
			phi.append(rad_to_deg(m.bank))
	var mx := -INF
	var mn := INF
	var pmax := 0.0
	for v in th:
		mx = maxf(mx, v)
		mn = minf(mn, v)
	for v in phi:
		pmax = maxf(pmax, absf(v))
	return {"theta_deg": _med(th), "theta_range_deg": mx - mn, "V_kmh": _med(V),
		"max_abs_phi_deg": pmax, "heading_drift_deg": rad_to_deg(m.heading - h10), "finite": S.finite(m)}


## Пикирование: «на себя» (pitch < 0) hold с, затем руки в нейтраль; всего 120 с. → вывод в горизонт.
## «Вывод» — тангаж снова выше трима − 2°; «успокоение» — после этого V в пределах 5 % трима и тангаж в 3° от трима
## (последний момент, когда не так); stall_end — доля сорванных полос в конце (≈ 1 — глубокий срыв).
func _dive(w: String, dt: float, pitch := -1.0, hold := 3.0, T := 120.0) -> Dictionary:
	var m := _model(w)
	var th_trim := rad_to_deg(m.theta)
	var v_trim := S.airspeed(m) * 3.6
	var inp := S.input(pitch)
	var weight := m.pilot_mass * G
	var th_min := INF
	var th_max := -INF
	var v_max := 0.0
	var v_min := INF
	var g_pull := 0.0
	var g_out := 0.0
	var t_rec := NAN
	var t_below := false
	var t_last_out := 0.0
	var ser: Array = []
	var every := maxi(1, roundi(0.1 / dt))
	for i in _steps(T, dt):
		var t := m.time_s
		if t >= hold - 1.0e-9:
			inp.pitch = 0.0
		m.step(dt, inp, Callable(), Callable())
		var th := rad_to_deg(m.theta)
		var V := S.airspeed(m)
		var n := m.strap_tension / weight
		th_min = minf(th_min, th)
		v_max = maxf(v_max, V * 3.6)
		if m.time_s < hold:
			g_pull = maxf(g_pull, n)
		else:
			g_out = maxf(g_out, n)
			th_max = maxf(th_max, th)
			v_min = minf(v_min, V * 3.6)
			if th < th_trim - 2.0:
				t_below = true
			elif t_below and is_nan(t_rec):
				t_rec = m.time_s - hold
			if absf(th - th_trim) > 3.0 or absf(V * 3.6 - v_trim) > 0.05 * v_trim:
				t_last_out = m.time_s - hold
		if dt == DT and i % every == 0 and m.time_s <= 20.0:
			ser.append([snappedf(m.time_s, 0.001), snappedf(th, 0.01), snappedf(V * 3.6, 0.01), snappedf(n, 0.001)])
	return {"pitch": pitch, "hold_s": hold, "theta_trim_deg": th_trim, "V_trim_kmh": v_trim,
		"theta_min_deg": th_min, "V_max_kmh": v_max, "n_pull_max": g_pull, "n_out_max": g_out,
		"t_recover_s": t_rec if t_below else 0.0, "theta_max_after_deg": th_max, "V_min_after_kmh": v_min,
		"t_settle_s": t_last_out, "theta_end_deg": rad_to_deg(m.theta), "V_end_kmh": S.airspeed(m) * 3.6,
		"alpha_end_deg": rad_to_deg(m.alpha), "stall_end": m.stall_amount(), "bank_end_deg": rad_to_deg(m.bank),
		"finite": S.finite(m), "series": ser}


func _turbulence(w: String, modes: Dictionary, dt: float, T: float) -> Dictionary:
	var m := _model(w)
	var off := S.cg(m) - S.START_CG
	var tb := S.Turbulence.new(modes, off)
	var air := tb.air
	var bh := Hold.new(0.0, 1.5, 0.8, 0.3)
	var inp := S.input()
	var phi: PackedFloat64Array = []
	var ry: PackedFloat64Array = []
	var th: PackedFloat64Array = []
	var blow := false
	var h10 := 0.0
	var h_set := false
	for i in _steps(T, dt):
		inp.roll = bh.roll(m, dt)
		m.step(dt, inp, air, Callable())
		if not S.finite(m) or S.airspeed(m) > 80.0:
			blow = true
			break
		if m.time_s > 10.0:
			if not h_set:
				h_set = true
				h10 = m.heading
			phi.append(rad_to_deg(m.bank))
			ry.append(S.rel_b(m).y)
			th.append(rad_to_deg(m.theta))
	var mx := 0.0
	for v in phi:
		mx = maxf(mx, absf(v))
	return {"blowup": blow, "std_phi_deg": _std(phi), "std_theta_deg": _std(th), "std_rel_y_m": _std(ry),
		"max_abs_phi_deg": mx, "max_stretch_m": m.chain.max_stretch,
		"heading_drift_deg": rad_to_deg(m.heading - h10) }


## Цена шага (мкс) PendulumModel и FlightModel при шаге игры dt: то же крыло, полёт со смещением и ветром
## (как tools/flight/pendulum_bench.gd), лучший из 3 прогонов. Запуск — под flock /tmp/heat_ca_gpu.lock, с `--bench`.
func _bench() -> void:
	var air := func(p: Vector3) -> Vector3: return Vector3(1.5, 0.2 * sin(0.05 * p.x), 0.0)
	var inp := ControlInput.new()
	inp.roll = 0.3
	inp.weight_shift = true
	for w in WINGS:
		var wing: Dictionary = Config.get_config("wings/" + w)
		var pilot: Dictionary = Config.get_config("pilot").duplicate(true)
		pilot.mass_kg = float(wing.pilot_mass_ref_kg)
		for dt: float in [1.0 / 60.0, 1.0 / 120.0, 1.0 / 240.0]:
			var n := int(round(10.0 / dt))
			var t_fm := INF
			var t_pd := INF
			for r in 3:
				var fm: Object = (load("res://scripts/flight/flight_model.gd") as GDScript).new()
				fm.setup(wing, pilot)
				fm.reset_in_air(Vector3(0, 1000, 0), 0.0)
				var t0 := Time.get_ticks_usec()
				for i in n:
					fm.step(dt, inp, air, Callable())
				t_fm = minf(t_fm, float(Time.get_ticks_usec() - t0))
				var pm := PendulumModel.new()
				pm.setup(wing, pilot)
				pm.reset_in_air(Vector3(0, 1000, 0), 0.0)
				t0 = Time.get_ticks_usec()
				for i in n:
					pm.step(dt, inp, air, Callable())
				t_pd = minf(t_pd, float(Time.get_ticks_usec() - t0))
			_emit("bench", w, dt, {"us_flight_model": t_fm / n, "us_pendulum": t_pd / n,
				"ms_per_second_pendulum": t_pd / n * (1.0 / dt) / 1000.0,
				"ms_per_second_flight_model": t_fm / n * (1.0 / dt) / 1000.0})
