extends Node
## WPC-1: замеры установившегося полёта настоящей модели (FlightModel) по всем крыльям.
## Для каждого крыла × {эталонная масса, пилот 85 кг (pilot.json, ограничен диапазоном крыла)}:
## перебор трапеции −1…+1 (установившееся планирование в штиле, ρ = 1,225), уточнение мин.
## снижения и макс. качества, снижение на 80 км/ч (секущая по трапеции), трим/«на себя»/«от себя»,
## сваливание (CL_max поляры), то же на высоте стартов (ρ из configs/flight.json → air_density).
## Пишет по строке JSON на (крыло, масса) в out/model_runs.jsonl; повторный запуск пропускает готовые.
## Высоты стартов — out/start_sites.json (из рельефа локаций).
## Запуск (из корня репозитория):
##   XDG_DATA_HOME=$(mktemp -d) godot --headless --path . res://tools/research/wing_physics_check/wings_audit_run.tscn
## Аргументы после «--»: --wings=a,b (только эти), --quick (грубая сетка, для оценки времени).

const DT := 1.0 / 120.0
const SETTLE_S := 25.0
const AVG_S := 5.0
const OUT_DIR := "res://tools/research/wing_physics_check/out/"
const RUNS := OUT_DIR + "model_runs.jsonl"
const SITES := OUT_DIR + "start_sites.json"
const LOCATIONS: Array[String] = ["altai", "askarovo", "aushkul", "ongudai"]
const ALTS: Array[float] = [0.0, 500.0, 1000.0, 1500.0, 2000.0]
const ALTS_FLY: Array[float] = [1000.0, 1500.0, 2000.0]

var _quick := false


func _ready() -> void:
	var only: Array[String] = []
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--wings="):
			for w in a.substr(8).split(","):
				only.append(w)
		elif a == "--quick":
			_quick = true
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	var sites := _start_sites()
	var done := _done_keys()
	var t0 := Time.get_ticks_msec()
	var pilot_default := float(Config.get_config("pilot").mass_kg)
	for path in Config.list_configs("wings"):
		var wid := String(path).get_file()
		if not only.is_empty() and not only.has(wid):
			continue
		var wing: Dictionary = Config.get_config("wings/" + wid)
		var cases := {
			"ref": float(wing.pilot_mass_ref_kg),
			"pilot85": FlightModel.clamp_pilot_mass(wing, pilot_default),
		}
		for mc in cases:
			var key := "%s|%s" % [wid, mc]
			if done.has(key):
				continue
			var t1 := Time.get_ticks_msec()
			var rec := _measure(wid, wing, mc, float(cases[mc]), sites)
			rec.key = key
			rec.wall_s = (Time.get_ticks_msec() - t1) / 1000.0
			_append(rec)
			print("%s: %.1f с" % [key, rec.wall_s])
	print("готово за %.0f с" % ((Time.get_ticks_msec() - t0) / 1000.0))
	get_tree().quit()


func _measure(wid: String, wing: Dictionary, mc: String, pm: float, sites: Array) -> Dictionary:
	var m := _make(wid, pm, false)
	var rec := {
		"wing": wid,
		"group": wing.group,
		"mass_case": mc,
		"pilot_mass_kg": pm,
		"total_mass_kg": m.mass,
		"mass_ref_kg": m.mass_ref,
		"area_m2": m.area,
		"cl_max": m.polar.cl_max,
		"alpha_stall_deg": rad_to_deg(m.alpha_stall),
		"stall_kmh": Units.to_kmh(m.stall_speed()),
		"trim_static_kmh": Units.to_kmh(m.trim_speed()),
	}
	# перебор трапеции
	var grid: Array[float] = []
	if _quick:
		for i in 11:
			grid.append(-1.0 + 0.2 * i)
	else:
		for p in [-1.0, -0.9, -0.8, -0.7, -0.6, -0.5, -0.45, -0.4]:
			grid.append(p)
		var p2 := -0.35
		while p2 < 0.6 + 1.0e-6:
			grid.append(snappedf(p2, 0.0001))
			p2 += 0.025
		for p in [0.7, 0.8, 0.9, 1.0]:
			grid.append(p)
	var sweep: Array = []
	for p in grid:
		sweep.append(_settle(m, p, 0.0))
	rec.sweep = sweep
	var trim: Dictionary = _find(sweep, 0.0)
	var pull: Dictionary = _find(sweep, -1.0)
	var push: Dictionary = _find(sweep, 1.0)
	rec.trim = trim
	rec.full_pull = pull
	rec.full_push = push
	# минимальная установившаяся скорость без срыва
	var vmin := 1.0e9
	for s: Dictionary in sweep:
		if not s.stalled and s.v_kmh < vmin:
			vmin = s.v_kmh
	rec.min_steady_kmh = vmin
	# уточнение мин. снижения и макс. качества (золотое сечение по трапеции у лучшей точки)
	rec.min_sink = _refine(m, sweep, "sink")
	rec.best_glide = _refine(m, sweep, "ld")
	# снижение на 80 км/ч
	rec.at_80 = _at_speed(m, sweep, 80.0)
	# аналитика: steady_glide по скоростям (как tests/flight/test_polar.gd → sweep)
	rec.analytic = _analytic(m)
	# высота: плотность по configs/flight.json
	var ma := _make(wid, pm, true)
	var alt_rows: Array = []
	var alts: Array[float] = ALTS.duplicate()
	for s: Dictionary in sites:
		alts.append(float(s.msl_m))
	for alt in alts:
		ma.rho = ma.air_density(alt)
		var row := {
			"alt_m": alt,
			"rho": ma.rho,
			"stall_kmh": Units.to_kmh(ma.stall_speed()),
			"trim_static_kmh": Units.to_kmh(ma.trim_speed()),
		}
		if ALTS_FLY.has(alt) and not _quick:
			row.trim = _settle(ma, 0.0, alt)
			row.full_pull = _settle(ma, -1.0, alt)
		alt_rows.append(row)
	rec.altitude = alt_rows
	return rec


func _make(wid: String, pm: float, alt_dep: bool) -> FlightModel:
	var wing: Dictionary = Config.get_config("wings/" + wid)
	var pilot: Dictionary = Config.get_config("pilot").duplicate(true)
	pilot.mass_kg = pm
	var m := FlightModel.new()
	m.setup(wing, pilot, {"air_density": {"altitude_dependent": alt_dep}})
	return m


## Ожидаемая скорость при трапеции p (как FlightModel._alpha_command) — начальное условие.
func _v_guess(m: FlightModel, p: float) -> float:
	var w := m.wing
	var v := lerpf(float(w.trim_speed_kmh), float(w.full_push_speed_kmh), maxf(p, 0.0))
	if p < 0.0:
		v = lerpf(float(w.trim_speed_kmh), float(w.full_pull_speed_kmh), -p)
	var s := sqrt(m.mass / m.mass_ref * 1.225 / m.air_density(3000.0))
	return maxf(Units.kmh(v) * s, m.stall_speed() * 1.02)


## Установившееся планирование при трапеции p; alt ≤ 0 — высота 3000 м (плотность постоянная
## у модели без altitude_dependent). Возвращает словарь замера.
func _settle(m: FlightModel, p: float, alt: float) -> Dictionary:
	var h := alt if alt > 0.0 else 3000.0
	m.reset_in_air(Vector3(0, h, 0), 0.0)
	var vg := _v_guess(m, p)
	m.reset_in_air(Vector3(0, h, 0), 0.0, vg)
	var c := ControlInput.new()
	c.pitch = p
	var n_settle := int(round((SETTLE_S if not _quick else 15.0) / DT))
	var n_avg := int(round(AVG_S / DT))
	var ever_stalled := false
	# окно перед усреднением — для оценки сходимости
	var sv0 := 0.0
	for i in n_settle:
		m.step(DT, c, Callable(), Callable())
		if i >= n_settle - n_avg:
			sv0 += m.telemetry.airspeed
	var sv := 0.0
	var ss := 0.0
	var sy := 0.0
	var sa := 0.0
	for i in n_avg:
		m.step(DT, c, Callable(), Callable())
		sv += m.telemetry.airspeed
		ss += -m.telemetry.vario
		sy += m.position.y
		sa += m.alpha
		ever_stalled = ever_stalled or m.stalled
	var v := sv / n_avg
	var sink := ss / n_avg
	return {
		"pitch": p,
		"v_kmh": Units.to_kmh(v),
		"sink_ms": sink,
		"ld": v / maxf(sink, 1.0e-3),
		"stalled": ever_stalled,
		"alpha_deg": rad_to_deg(sa / n_avg),
		"alt_m": sy / n_avg,
		"rho": m.rho,
		"drift_kmh": Units.to_kmh(v - sv0 / n_avg),
	}


func _find(sweep: Array, p: float) -> Dictionary:
	for s: Dictionary in sweep:
		if absf(float(s.pitch) - p) < 1.0e-6:
			return s
	return {}


## Золотое сечение по трапеции вокруг лучшей точки перебора (без срыва).
func _refine(m: FlightModel, sweep: Array, what: String) -> Dictionary:
	var best := -1
	for i in sweep.size():
		var s: Dictionary = sweep[i]
		if s.stalled:
			continue
		if best < 0 or _better(s, sweep[best], what):
			best = i
	var lo := float(sweep[maxi(best - 1, 0)].pitch)
	var hi := float(sweep[mini(best + 1, sweep.size() - 1)].pitch)
	var best_s: Dictionary = sweep[best]
	if _quick:
		return best_s
	var gr := 0.618034
	var a := lo
	var b := hi
	var x1 := b - gr * (b - a)
	var x2 := a + gr * (b - a)
	var f1 := _settle(m, x1, 0.0)
	var f2 := _settle(m, x2, 0.0)
	for k in 6:
		if _better(f1, f2, what):
			b = x2
			x2 = x1
			f2 = f1
			x1 = b - gr * (b - a)
			f1 = _settle(m, x1, 0.0)
		else:
			a = x1
			x1 = x2
			f1 = f2
			x2 = a + gr * (b - a)
			f2 = _settle(m, x2, 0.0)
	for f: Dictionary in [f1, f2]:
		if not f.stalled and _better(f, best_s, what):
			best_s = f
	return best_s


func _better(a: Dictionary, b: Dictionary, what: String) -> bool:
	if what == "sink":
		return float(a.sink_ms) < float(b.sink_ms)
	return float(a.ld) > float(b.ld)


## Установившийся полёт на заданной скорости: секущая по трапеции от двух соседних точек перебора.
func _at_speed(m: FlightModel, sweep: Array, v_kmh: float) -> Dictionary:
	var i0 := -1
	for i in range(1, sweep.size()):
		var a: Dictionary = sweep[i - 1]
		var b: Dictionary = sweep[i]
		if (a.v_kmh - v_kmh) * (b.v_kmh - v_kmh) <= 0.0:
			i0 = i
			break
	if i0 < 0:
		return {}
	var pa: Dictionary = sweep[i0 - 1]
	var pb: Dictionary = sweep[i0]
	var r := pa
	for k in 3:
		var dv := float(pb.v_kmh) - float(pa.v_kmh)
		if absf(dv) < 1.0e-6:
			break
		var p := float(pa.pitch) + (v_kmh - float(pa.v_kmh)) * (float(pb.pitch) - float(pa.pitch)) / dv
		r = _settle(m, p, 0.0)
		if absf(float(r.v_kmh) - v_kmh) < 0.05:
			break
		if absf(float(pa.v_kmh) - v_kmh) > absf(float(pb.v_kmh) - v_kmh):
			pa = r
		else:
			pb = r
	# остаток — линейно по наклону поляры
	return r


func _analytic(m: FlightModel) -> Dictionary:
	var r := {"min_sink_ms": 99.0, "min_sink_kmh": 0.0, "best_ld": 0.0, "best_ld_kmh": 0.0}
	var v := m.stall_speed()
	while v < Units.kmh(120.0):
		var g := m.steady_glide(v)
		if g.y < r.min_sink_ms:
			r.min_sink_ms = g.y
			r.min_sink_kmh = Units.to_kmh(v)
		if v / g.y > r.best_ld:
			r.best_ld = v / g.y
			r.best_ld_kmh = Units.to_kmh(v)
		v += 0.02
	r.sink_80_ms = m.steady_glide(Units.kmh(80.0)).y
	return r


## Высоты стартов из рельефа (кешируются в out/start_sites.json).
func _start_sites() -> Array:
	if FileAccess.file_exists(SITES):
		var j = JSON.parse_string(FileAccess.get_file_as_string(SITES))
		if j is Array:
			return j
	var out: Array = []
	for loc in LOCATIONS:
		var t := Terrain.new()
		t.location_id = ""
		if not t.load_location(loc):
			t.free()
			push_error("не загрузилась локация " + loc)
			continue
		for s: Dictionary in t.get_start_sites():
			var p: Vector3 = s.position
			out.append({"location": loc, "start": s.id, "msl_m": snappedf(p.y, 0.1)})
		t.free()
	var f := FileAccess.open(SITES, FileAccess.WRITE)
	f.store_string(JSON.stringify(out, "  "))
	f.close()
	return out


func _done_keys() -> Dictionary:
	var d := {}
	if not FileAccess.file_exists(RUNS):
		return d
	for line in FileAccess.get_file_as_string(RUNS).split("\n"):
		if line.strip_edges().is_empty():
			continue
		var j = JSON.parse_string(line)
		if j is Dictionary and j.has("key"):
			d[j.key] = true
	return d


func _append(rec: Dictionary) -> void:
	var f: FileAccess
	if FileAccess.file_exists(RUNS):
		f = FileAccess.open(RUNS, FileAccess.READ_WRITE)
		f.seek_end()
	else:
		f = FileAccess.open(RUNS, FileAccess.WRITE)
	f.store_line(JSON.stringify(rec))
	f.close()
