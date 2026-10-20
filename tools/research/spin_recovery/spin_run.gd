extends Node
## SR-К1 (docs/contracts/spin-recovery.md): стенд штопора — вход в штопор (вираж 30°, pitch 0 → 1) и выход
## (release / standard), один прогон на процесс. Логика входа/выхода — как _run в tests/flight/pendulum/test_pendulum_spin.gd.
## godot --headless --path . res://tools/research/spin_recovery/spin_run.tscn -- --wing=sport --variant=game --mode=release --dt=0.008333333 --out=<json> [--task=SR-2] [--trace=1]
## Варианты — таблица VARIANTS (имя → правки). Ключи правки:
##   wing_pend {поле: значение} — блок pendulum конфига крыла до setup (геометрия: washout_deg, tip_chord_m, sweep_deg…);
##   app {поле: значение}       — «Аппарат» (apparatus_cfg): dihedral_eff_deg…;
##   pnl_off                    — strips.nl_on = false после setup;
##   arms {поле: значение}      — поля PendulumPilotArms после setup (release_event…);
##   strips_script "res://…"    — наследник PendulumWingStrips, подставляемый в m.strips до setup (SR-3);
##   post                       — Callable(m) после setup, до балансировки (поля strips: SR-3);
##   (режимы: release, standard — обязательные; pull_release — «на себя» как standard, затем pitch 0)
##   rebalance                  — match_polar_cl_max + dcm0 секущими под паспортный трим (SR-К1); авто, если есть
##                                wing_pend/app/pnl_off/strips_script/post.
## SR-3 добавляет варианты только в VARIANTS; логика ниже не меняется.

const S := preload("res://tests/flight/pendulum/pendulum_sim.gd")
const RAMP_S := 10.0
const AFTER_S := 6.0
const WIN_S := 3.0
const REC_MAX_S := 60.0
const POST_S := 20.0
const NO_STALL_MAX_S := 120.0

var VARIANTS := {
	"game": {"doc": "игра как есть"},
	"pnl_off": {"doc": "pitch_nl выключен (strips.nl_on = false), dcm0 пересчитан под паспортный трим", "pnl_off": true},
	"rel_off": {"doc": "arms.release_event = false (без отпускания рук VM-12)", "arms": {"release_event": false}},
	"wash12": {"doc": "sport: washout_deg 10 → 12", "wings": ["sport"], "wing_pend": {"washout_deg": 12.0}},
	"wash14": {"doc": "sport: washout_deg 10 → 14", "wings": ["sport"], "wing_pend": {"washout_deg": 14.0}},
	"lam_tipchord": {"doc": "sport: tip_chord_m 0,55 → 0,62 (значение laminar)", "wings": ["sport"],
		"wing_pend": {"tip_chord_m": 0.62}},
	"lam_dihedral": {"doc": "sport: dihedral_eff_deg 0,5 → −1,5 (значение laminar)", "wings": ["sport"],
		"app": {"dihedral_eff_deg": -1.5}},
	"lam_washout": {"doc": "sport: washout_deg 10 → 11 (значение laminar)", "wings": ["sport"],
		"wing_pend": {"washout_deg": 11.0}},
	"lam_sweep": {"doc": "sport: sweep_deg 26 → 26,5 (значение laminar)", "wings": ["sport"],
		"wing_pend": {"sweep_deg": 26.5}},
	"sweep_25_5": {"doc": "sport: sweep_deg 25,5 (скан чувствительности)", "wings": ["sport"], "wing_pend": {"sweep_deg": 25.5}},
	"sweep_26_25": {"doc": "sport: sweep_deg 26,25 (скан чувствительности)", "wings": ["sport"], "wing_pend": {"sweep_deg": 26.25}},
	"sweep_27": {"doc": "sport: sweep_deg 27 (скан чувствительности)", "wings": ["sport"], "wing_pend": {"sweep_deg": 27.0}},
	"sweep_28": {"doc": "sport: sweep_deg 28 (скан чувствительности)", "wings": ["sport"], "wing_pend": {"sweep_deg": 28.0}},
	"lam_all": {"doc": "sport: все четыре параметра laminar (хорда конца, V-образность, крутка, стреловидность)",
		"wings": ["sport"], "wing_pend": {"tip_chord_m": 0.62, "washout_deg": 11.0, "sweep_deg": 26.5},
		"app": {"dihedral_eff_deg": -1.5}},
	"strips_id": {"doc": "SR-3: sr3_strips.gd с выключенными правками (проверка: = game)", "strips_script": "res://tools/research/spin_recovery/sr3_strips.gd"},
	"sprog2_a": {"doc": "SR-3: упор концов, 2 крайних полос, α_геом ≤ корень − 4°", "strips_script": "res://tools/research/spin_recovery/sr3_strips.gd",
		"post": func(m): m.strips.n_tip = 2; m.strips.sprog_min_washout_deg = 4.0},
	"sprog2_b": {"doc": "SR-3: упор концов, 2 крайних полос, α_геом ≤ корень − 7°", "strips_script": "res://tools/research/spin_recovery/sr3_strips.gd",
		"post": func(m): m.strips.n_tip = 2; m.strips.sprog_min_washout_deg = 7.0},
	"sprog3_a": {"doc": "SR-3: упор концов, 3 крайних полос, α_геом ≤ корень − 4°", "strips_script": "res://tools/research/spin_recovery/sr3_strips.gd",
		"post": func(m): m.strips.n_tip = 3; m.strips.sprog_min_washout_deg = 4.0},
	"sprog3_b": {"doc": "SR-3: упор концов, 3 крайних полос, α_геом ≤ корень − 7°", "strips_script": "res://tools/research/spin_recovery/sr3_strips.gd",
		"post": func(m): m.strips.n_tip = 3; m.strips.sprog_min_washout_deg = 7.0},
	"clmax2_10": {"doc": "SR-3: C_L max 2 крайних полос × 1.10, затем match_polar_cl_max", "strips_script": "res://tools/research/spin_recovery/sr3_strips.gd",
		"post": func(m): m.strips.n_tip = 2; m.strips.clmax_tip_k = 1.10},
	"clmax2_15": {"doc": "SR-3: C_L max 2 крайних полос × 1.15, затем match_polar_cl_max", "strips_script": "res://tools/research/spin_recovery/sr3_strips.gd",
		"post": func(m): m.strips.n_tip = 2; m.strips.clmax_tip_k = 1.15},
	"clmax3_10": {"doc": "SR-3: C_L max 3 крайних полос × 1.10, затем match_polar_cl_max", "strips_script": "res://tools/research/spin_recovery/sr3_strips.gd",
		"post": func(m): m.strips.n_tip = 3; m.strips.clmax_tip_k = 1.10},
	"clmax3_15": {"doc": "SR-3: C_L max 3 крайних полос × 1.15, затем match_polar_cl_max", "strips_script": "res://tools/research/spin_recovery/sr3_strips.gd",
		"post": func(m): m.strips.n_tip = 3; m.strips.clmax_tip_k = 1.15},
}

var _args := {"wing": "sport", "variant": "game", "mode": "release", "dt": "0.0083333333333", "out": "",
	"task": "SR-2", "trace": ""}


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--") and a.contains("="):
			var kv := a.substr(2).split("=", true, 1)
			_args[kv[0]] = kv[1]
	var res := run(String(_args.wing), String(_args.variant), String(_args.mode), float(_args.dt))
	res["task"] = String(_args.task)
	var path := String(_args.out)
	if path == "":
		print(JSON.stringify(res))
	else:
		var tmp := path + ".tmp"
		var f := FileAccess.open(tmp, FileAccess.WRITE)
		f.store_string(JSON.stringify(res))
		f.close()
		DirAccess.rename_absolute(ProjectSettings.globalize_path(tmp), ProjectSettings.globalize_path(path))
	get_tree().quit(0)


## Модель варианта: как S.make + правки; возвращает {m, trim_kmh, balanced, dcm0_game, info}.
func make_model(w: String, variant: String) -> Dictionary:
	var v: Dictionary = VARIANTS[variant]
	var wing: Dictionary = Config.get_config("wings/" + w).duplicate(true)
	for k: String in v.get("wing_pend", {}):
		wing.pendulum[k] = v.wing_pend[k]
	var pilot: Dictionary = Config.get_config("pilot").duplicate(true)
	pilot.mass_kg = float(wing.pilot_mass_ref_kg)
	var m := PendulumModel.new()
	if v.has("strips_script"):
		m.strips = load(String(v.strips_script)).new()
	m.setup(wing, pilot, {"air_density": {"altitude_dependent": false}}, v.get("app", {}))
	S.pd35_env(m)
	var info := {}
	var geometry_edit := v.has("wing_pend") or v.has("app") or v.has("pnl_off") or v.has("strips_script") or v.has("post")
	if v.get("pnl_off", false):
		m.strips.nl_on = false
	if v.has("post"):
		(v.post as Callable).call(m)
	for k: String in v.get("arms", {}):
		m.arms.set(k, v.arms[k])
	var out := {"m": m, "balanced": true, "info": info}
	var passport := float(wing.trim_speed_kmh)
	info["passport_kmh"] = passport
	info["dcm0_cfg"] = m.strips.dcm0
	if v.get("rebalance", geometry_edit):
		if bool(m.pendulum.get("strip_cl_max_match_polar", true)):
			m.strips.match_polar_cl_max()
		info["trim_before_kmh"] = float(m.solve_trim().V) * 3.6
		out.balanced = _retrim(m, passport)
		info["dcm0_balanced"] = m.strips.dcm0
	out["trim_kmh"] = float(m.solve_trim().V) * 3.6
	info["cl_max_wing"] = m.strips.wing_cl_max()
	info["cl_max_strip"] = m.strips.cl_max  # SR-3: C_L max полосы (корня) после match_polar_cl_max
	info["area_m2"] = m.area
	return out


## dcm0 так, чтобы solve_trim().V = паспорт (секущие, как pullin_speed.gd:_retrim), допуск 0,005 км/ч.
func _retrim(m: PendulumModel, v_kmh: float) -> bool:
	var x0 := m.strips.dcm0
	var f0 := _trim_v(m) - v_kmh
	if absf(f0) < 0.005:
		return true
	var x1 := x0 + 0.01
	m.strips.dcm0 = x1
	var f1 := _trim_v(m) - v_kmh
	for _i in 20:
		if absf(f1) < 0.005 or absf(f1 - f0) < 1.0e-9:
			break
		var x2 := x1 - f1 * (x1 - x0) / (f1 - f0)
		x0 = x1
		f0 = f1
		x1 = x2
		m.strips.dcm0 = x1
		f1 = _trim_v(m) - v_kmh
	return absf(f1) < 0.01 and absf(m.strips.dcm0) < 1.0


func _trim_v(m: PendulumModel) -> float:
	return float(m.solve_trim().V) * 3.6


func _yaw_rate(m: PendulumModel, prev: float, dt: float) -> float:
	return wrapf(m.heading - prev, -PI, PI) / dt


func _n(x: float) -> Variant:
	return null if (is_nan(x) or is_inf(x)) else x


func run(w: String, variant: String, mode: String, dt: float) -> Dictionary:
	var mk := make_model(w, variant)
	var m: PendulumModel = mk.m
	S.reset(m)
	var v_trim := S.airspeed(m) * 3.6
	var hb := S.BankHold.new(deg_to_rad(30.0), 6.0, 2.5, 1.0)
	var inp := S.input()
	var o := {"contract": "SR-К2 v1", "task": "SR-2", "wing": w, "variant": variant, "mode": mode, "dt": dt,
		"trim_kmh": mk.trim_kmh, "first": "", "spin_yaw_dps": null, "spin_bank_max_deg": null,
		"spin_sink_max_ms": null, "recovered": false, "recover_s": null, "loss_m": null,
		"after_bank_max_deg": null, "after_stall_s": null, "finite": true}
	var ex := {"v_trim_kmh": v_trim, "balanced": mk.balanced, "info": mk.info}
	o["extra"] = ex
	for i in int(round(14.0 / dt)):
		inp.roll = hb.roll(m)
		m.step(dt, inp, Callable(), Callable())
	if not S.finite(m):
		o.finite = false
		return o
	var h := m.strips.n / 2
	var t0 := m.time_s
	var hd := m.heading
	var phase := 0
	var t_st := 0.0
	var roll_frz := 0.0
	var h_stall := 0.0
	var bank_max := -INF
	var sink_max := 0.0
	var yaw_sum := 0.0
	var n_yaw := 0
	var t_rec0 := 0.0
	var pulling := true
	var rec_since := NAN
	var h_rec := 0.0
	var t_done := NAN
	var yr_prev := 0.0
	var after_bank := 0.0
	var after_stall := 0.0
	var vmax_rec := 0.0
	var yr_abs_max_rec := 0.0
	var step_i := 0
	var tr_end := 0.0
	var nr := 0
	var nl := 0
	var yr := 0.0
	var tracing := String(_args.trace) != ""
	while true:
		var t := m.time_s - t0
		if phase == 0:
			inp.pitch = clampf(t / RAMP_S, 0.0, 1.0)
			inp.roll = hb.roll(m)
			if t > NO_STALL_MAX_S:
				ex["no_stall"] = true
				break
		elif phase == 1:
			inp.pitch = clampf(t / RAMP_S, 0.0, 1.0)
			inp.roll = roll_frz
		elif phase == 2:
			var tr := m.time_s - t_rec0
			if mode == "release":
				inp.pitch = 0.0
				inp.roll = 0.0
			else:
				hb.target = 0.0
				inp.roll = hb.roll(m)
				if pulling:
					inp.pitch = -1.0
					inp.roll = -signf(yr_prev)
				elif mode == "pull_release":
					inp.pitch = 0.0  # после «на себя» — нейтраль, не держать −1 по скорости (диагностика пилот-модели теста)
				else:
					inp.pitch = clampf(-2.0 * (S.airspeed(m) * 3.6 - v_trim) / v_trim, -1.0, 0.0)
			if tr > REC_MAX_S:
				break
		else:
			if m.time_s - t_done >= POST_S:
				break
		m.step(dt, inp, Callable(), Callable())
		step_i += 1
		if not S.finite(m):
			o.finite = false
			ex["nonfinite_t_s"] = m.time_s - t0
			break
		yr = _yaw_rate(m, hd, dt)
		yr_prev = yr
		hd = m.heading
		nr = 0
		nl = 0
		for j in h:
			if m.strips.blend[j] > 0.01:
				nr += 1
			if m.strips.blend[j + h] > 0.01:
				nl += 1
		t = m.time_s - t0
		if phase == 0:
			if nr + nl > 0:
				phase = 1
				t_st = t
				roll_frz = inp.roll
				h_stall = m.position.y
				o.first = "обе" if nr > 0 and nl > 0 else ("внутренняя" if nr > 0 else "внешняя")
				ex["h_stall_m"] = h_stall
				ex["t_stall_s"] = t
				ex["pitch_at_stall"] = inp.pitch
				ex["bank0_deg"] = rad_to_deg(m.bank)
		elif phase == 1:
			bank_max = maxf(bank_max, rad_to_deg(m.bank))
			sink_max = maxf(sink_max, -m.velocity.y)
			yaw_sum += yr
			n_yaw += 1
			if t - t_st >= AFTER_S:
				phase = 2
				t_rec0 = m.time_s
				o.spin_yaw_dps = rad_to_deg(yaw_sum / n_yaw)
				o.spin_bank_max_deg = bank_max
				o.spin_sink_max_ms = sink_max
				ex["h_rec0_m"] = m.position.y
				ex["stall_n_rec0"] = nr + nl
				ex["v_rec0_kmh"] = S.airspeed(m) * 3.6
		elif phase == 2:
			var tr2 := m.time_s - t_rec0
			vmax_rec = maxf(vmax_rec, S.airspeed(m) * 3.6)
			yr_abs_max_rec = maxf(yr_abs_max_rec, absf(rad_to_deg(yr)))
			if tracing and step_i % int(round(0.25 / dt)) == 0:
				print("tr %5.2f h %7.1f крен %6.1f yr %6.1f срыв %d/%d V %5.1f p %5.2f" % [
					tr2, m.position.y, rad_to_deg(m.bank), rad_to_deg(yr), nr, nl, S.airspeed(m) * 3.6, inp.pitch])
			if mode != "release" and pulling and tr2 >= 1.0 and (tr2 >= 10.0 or (nr + nl == 0 and absf(yr) < deg_to_rad(45.0))):
				pulling = false
				ex["pull_s"] = tr2
			tr_end = tr2
			if absf(rad_to_deg(m.bank)) < 15.0 and absf(rad_to_deg(yr)) < 20.0 and nr + nl == 0:
				if is_nan(rec_since):
					rec_since = m.time_s
					h_rec = m.position.y
				elif m.time_s - rec_since >= WIN_S:
					o.recovered = true
					o.recover_s = rec_since - t_rec0
					o.loss_m = h_stall - h_rec
					t_done = m.time_s
					phase = 3
			else:
				rec_since = NAN
		else:
			after_bank = maxf(after_bank, absf(rad_to_deg(m.bank)))
			if nr + nl > h:
				after_stall += dt
	if o.recovered:
		o.after_bank_max_deg = after_bank
		o.after_stall_s = after_stall
	if "sprog_active_max_deg" in m.strips:
		ex["sprog_active_max_deg"] = m.strips.sprog_active_max_deg  # SR-3: макс. срез упором за прогон
	if phase >= 2:
		ex["v_max_rec_kmh"] = vmax_rec
		ex["yaw_abs_max_rec_dps"] = yr_abs_max_rec
		ex["end_bank_deg"] = rad_to_deg(m.bank)
		ex["end_yaw_dps"] = rad_to_deg(yr)
		ex["end_stalled"] = nr + nl
		ex["end_v_kmh"] = S.airspeed(m) * 3.6
		ex["end_h_m"] = m.position.y
		ex["tr_end_s"] = tr_end
	return o
