extends Node
## AM-08: замеры масштаба 3 с полем и без (docs/guide/air-model.md → «Масштаб 3: возмущения из поля»).
## Headless, детерминированно (сид 42, как база AM-00 tools/research/air_model_baseline/probe.gd).
##
##   godot --headless --path . res://tools/research/air_turb/turb_probe.tscn -- \
##     [--fields=tools/research/air_turb/fields] [--out=tools/research/air_turb/out] [--only=lee|table|spectrum]
##
## 1) lee: подветренная точка базы AM-00 (та же схема поиска) на 3 стартах — СКО w, рывки/мин (порог
##    3σ(dw/dt), как база), среднее w; без поля и с полем <loc>_<site>_w100_h13 (lee_fields.py).
##    Для п. 4 приёмки — ещё прогон без термиков: среднее w против w_mech поля + фон.
## 2) table: σ_u, σ_w (СКО по ряду 120 с) от ветра, у бровки/на ровном, в устойчивом воздухе —
##    синтетическое поле (лог-профиль) и точки реального поля.
## 3) spectrum: запись u, w на прямой траектории (12 м/с, 400 с, 50 Гц) — csv для spectrum.py.

const SEED := 42
const LEE_SITES: Array[Dictionary] = [
	{"loc": "altai", "site": "sinyukha_west"},
	{"loc": "askarovo", "site": "biyagoda_west"},
	{"loc": "aushkul", "site": "aushtau_east"},
]
const WIND_KMH := 20.0
const HZ := 20.0
const DUR := 180.0
const LEE_AGL: Array[float] = [10.0, 20.0, 35.0, 50.0, 65.0, 80.0, 100.0]

var fields_dir := "tools/research/air_turb/fields"
var out_dir := "tools/research/air_turb/out"


func _ready() -> void:
	var only := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--fields="):
			fields_dir = a.substr(9)
		elif a.begins_with("--out="):
			out_dir = a.substr(6)
		elif a.begins_with("--only="):
			only = a.substr(7)
	DirAccess.make_dir_recursive_absolute(out_dir)
	var res := {}
	if only == "" or only == "lee":
		res["lee"] = _lee_all()
	if only == "" or only == "table":
		res["table"] = _table()
	if only == "" or only == "spectrum":
		res["spectrum"] = _spectrum()
	var f := FileAccess.open(out_dir + "/turb_probe%s.json" % ("" if only == "" else "_" + only), FileAccess.WRITE)
	f.store_string(JSON.stringify(res, "  "))
	f.close()
	get_tree().quit(0)


func _make_atmo(terrain: Terrain, wind_kmh: float, from_deg: float) -> Atmosphere:
	var w: Dictionary = Config.get_config("weather/medium").duplicate(true)
	w.wind_speed_kmh = wind_kmh
	w.wind_from_deg = from_deg
	var atmo := Atmosphere.new()
	atmo.visuals_enabled = false
	atmo.seed_value = SEED
	atmo.configure(Config.get_config("atmosphere").duplicate(true), w)
	atmo.turbulence_enabled = true
	if terrain != null:
		atmo.set_ground(terrain.height_at, terrain.thermal_source_strength_at, terrain.surface_at)
	return atmo


func _load_terrain(loc_id: String) -> Terrain:
	var t := Terrain.new()
	t.location_id = ""
	if not t.load_location(loc_id):
		t.free()
		return null
	return t


## Точка глубже всего под линией тени (как probe.gd базы AM-00).
func _scan_lee_point(terrain: Terrain, site: Dictionary) -> Vector3:
	var heading: float = float(site.heading_deg)
	var atmo := _make_atmo(terrain, WIND_KMH, fposmod(heading + 180.0, 360.0))
	var pos0: Vector3 = site.position
	atmo.set_focus(pos0)
	atmo.step(1.0)
	var away := Vector2(sin(deg_to_rad(heading)), -cos(deg_to_rad(heading)))
	var best := -1.0e9
	var best_p := Vector3.ZERO
	var d := -1000.0
	while d <= 1000.0:
		var p2: Vector2 = Vector2(pos0.x, pos0.z) + away * d
		var gh := terrain.height_at(p2.x, p2.y)
		var gs: Vector4 = atmo.ground.sample(p2.x, p2.y)
		for agl: float in LEE_AGL:
			if gs.w - (gh + agl) > best:
				best = gs.w - (gh + agl)
				best_p = Vector3(p2.x, gh + agl, p2.y)
		d += 20.0
	atmo.free()
	return best_p


## Ряд в неподвижной точке: СКО w, рывки/мин (|dw/dt| > 3σ, как база), среднее w, СКО u.
func _series(atmo: Atmosphere, pos: Vector3, dur: float = DUR, thr_abs: float = NAN) -> Dictionary:
	var dt := 1.0 / HZ
	var n := int(dur * HZ)
	var ws := PackedFloat32Array()
	var us := PackedFloat32Array()
	ws.resize(n)
	us.resize(n)
	atmo.set_focus(pos)
	var m := atmo.mean_wind_at(pos)
	var md := Vector2(m.x, m.z).normalized()
	for i in n:
		atmo.step(dt)
		var v := atmo.air_velocity_at(pos)
		ws[i] = v.y
		us[i] = v.x * md.x + v.z * md.y
	var sw := _stats(ws)
	var su := _stats(us)
	var dd := PackedFloat32Array()
	dd.resize(n - 1)
	for i in n - 1:
		dd[i] = (ws[i + 1] - ws[i]) / dt
	var sd := _stats(dd)
	var jerks := 0
	var jerks_abs := 0
	for x in dd:
		if absf(x - sd.x) > 3.0 * sd.y:
			jerks += 1
		if absf(x - sd.x) > thr_abs:
			jerks_abs += 1
	return {
		"sigma_w": sw.y, "mean_w": sw.x, "sigma_u": su.y, "mean_u": su.x,
		"jerks_per_min": jerks / (dur / 60.0), "jerk_threshold": 3.0 * sd.y,
		"jerks_per_min_abs_thr": jerks_abs / (dur / 60.0) if is_finite(thr_abs) else -1.0,
		"mean_wind_w": m.y, "mean_wind_h": Vector2(m.x, m.z).length(),
	}


static func _stats(a: PackedFloat32Array) -> Vector2:
	var s := 0.0
	for x in a:
		s += x
	var mu := s / a.size()
	var v := 0.0
	for x in a:
		v += (x - mu) * (x - mu)
	return Vector2(mu, sqrt(v / a.size()))


func _field_path(loc: String, site: String) -> String:
	return "%s/%s_%s_w100_h13" % [fields_dir, loc, site]


func _lee_all() -> Array:
	var out := []
	for e: Dictionary in LEE_SITES:
		var terrain := _load_terrain(e.loc)
		var site: Dictionary = {}
		for s: Dictionary in terrain.get_start_sites():
			if String(s.id) == e.site:
				site = s
		var p := _scan_lee_point(terrain, site)
		var from := fposmod(float(site.heading_deg) + 180.0, 360.0)
		var row := {"key": "%s/%s" % [e.loc, e.site], "pos": [p.x, p.y, p.z]}
		var a := _make_atmo(terrain, WIND_KMH, from)
		row["analytic"] = _series(a, p)
		a.free()
		var wf := WindField.load_file(_field_path(e.loc, e.site))
		if wf != null:
			a = _make_atmo(terrain, WIND_KMH, from)
			a.set_air_field(wf, 0.0)
			row["field"] = _series(a, p, DUR, float(row.analytic.jerk_threshold))
			var tb := a.air_field.sample_turb(p, terrain.height_at(p.x, p.z))
			var fw := a.air_field.sample(p, terrain.height_at(p.x, p.z))
			var uf := Vector2(fw.x, fw.z).length() / maxf(fw.w, 1.0e-6)
			var agl := p.y - terrain.height_at(p.x, p.z)
			row["field_at_point"] = {
				"w_mech": fw.y, "u_field": uf, "u_out": tb[WindField.T_UOUT],
				"a_out": tb[WindField.T_AOUT], "desc": tb[WindField.T_DESC],
				"ustar": tb[WindField.T_USTAR], "shear": tb[WindField.T_SHEAR],
				"n2": tb[WindField.T_N2], "wstar": tb[WindField.T_WSTAR],
				"lee_f": a.field_turb.lee(uf, agl, tb), "agl": agl, "share": fw.w,
			}
			a.free()
			# п. 4: без термиков — среднее w против w_mech поля + фон (у земли гаснет)
			for mode in ["analytic", "field"]:
				a = _make_atmo(terrain, WIND_KMH, from)
				a.set_thermal_mode("static")
				if mode == "field":
					a.set_air_field(WindField.load_file(_field_path(e.loc, e.site)), 0.0)
				var st := _series(a, p, 1800.0)
				var fade := minf(agl / float(a.cfg.ground_fade_m), 1.0)
				row["no_thermals_" + mode] = {
					"mean_w": st.mean_w, "sigma_w": st.sigma_w,
					"expected_mean_w": st.mean_wind_w + fade * a._bg_sink,
				}
				a.free()
		out.append(row)
		terrain.free()
		print(JSON.stringify(row))
	return out


## Синтетическое поле: ровная земля hc = 0, лог-профиль U(z) = U10·ln(z/z0)/ln(10/z0) по x,
## θ′ = 0; gam — устойчивость (К/м); heat/z_i — конвекция (heat = 0 — без конвекции).
func _synthetic(u10: float, gam: float, heat: float, z_i: float) -> WindField:
	var nx := 16
	var nz := 40
	var dz := 25.0
	var m := {
		"dx": 100.0, "dz": dz, "x0": -800.0, "y0": -800.0, "z_bot": 0.0,
		"nx": nx, "ny": nx, "nz": nz, "z0": 0.1,
	}
	var g := []
	for k in nz:
		g.append(gam)
	m["gam"] = g
	var h := []
	for c in nx * nx:
		h.append(heat)
	m["heat"] = h
	m["z_i"] = z_i
	var n := nx * nx * nz
	var u := PackedFloat32Array()
	var z0a := PackedFloat32Array()
	u.resize(n)
	z0a.resize(n)
	for k in nz:
		var z := (k + 0.5) * dz
		var s := u10 * log(z / 0.1) / log(10.0 / 0.1)
		for c in nx * nx:
			u[k * nx * nx + c] = s
	var hc := PackedFloat32Array()
	hc.resize(nx * nx)
	return WindField.from_arrays(m, u, z0a, z0a, z0a, z0a, hc)


func _table() -> Array:
	var out := []
	var flat := func(_x: float, _z: float) -> float: return 0.0
	var sun := func(_x: float, _z: float) -> float: return 0.5
	var cases := [
		["ветер 2 м/с, нейтр.", 2.0, 0.0, 0.0],
		["ветер 4 м/с, нейтр.", 4.0, 0.0, 0.0],
		["ветер 6 м/с, нейтр.", 6.0, 0.0, 0.0],
		["ветер 8 м/с, нейтр.", 8.0, 0.0, 0.0],
		["6 м/с, устойчиво N=0,010", 6.0, 0.0033, 0.0],
		["6 м/с, устойчиво N=0,018 (инверсия)", 6.0, 0.01, 0.0],
		["6 м/с, конвекция H=300 Вт/м², z_i=1500", 6.0, 0.0, 300.0],
	]
	for cs: Array in cases:
		for agl: float in [20.0, 100.0, 300.0]:
			var a := _make_atmo(null, float(cs[1]) * 3.6, 270.0)
			a.set_ground(flat, sun)
			a.set_thermal_mode("static")
			a.set_air_field(_synthetic(cs[1], cs[2], cs[3], 1500.0), 0.0)
			var st := _series(a, Vector3(0.0, agl, 0.0), 120.0)
			var row := {"case": cs[0], "agl": agl, "sigma_u": st.sigma_u, "sigma_w": st.sigma_w}
			a.free()
			a = _make_atmo(null, float(cs[1]) * 3.6, 270.0)
			a.set_ground(flat, sun)
			a.set_thermal_mode("static")
			var sa := _series(a, Vector3(0.0, agl, 0.0), 120.0)
			row["analytic_sigma_u"] = sa.sigma_u
			row["analytic_sigma_w"] = sa.sigma_w
			a.free()
			out.append(row)
			print(JSON.stringify(row))
	# реальное поле: бровка против ровного места против ветра (Синюха, 5,6 м/с)
	var terrain := _load_terrain("altai")
	var site: Dictionary = {}
	for s: Dictionary in terrain.get_start_sites():
		if String(s.id) == "sinyukha_west":
			site = s
	var from := fposmod(float(site.heading_deg) + 180.0, 360.0)
	var d := deg_to_rad(from)
	var down := Vector2(-sin(d), cos(d))  # куда дует (мир x, z)
	var p0: Vector3 = site.position
	for pt: Array in [["наветренная равнина −1400 м", -1400.0], ["бровка (старт)", 0.0],
			["за гребнем +400 м", 400.0]]:
		for agl: float in [20.0, 100.0]:
			var q := Vector2(p0.x, p0.z) + down * float(pt[1])
			var gh := terrain.height_at(q.x, q.y)
			var pos := Vector3(q.x, gh + agl, q.y)
			var a := _make_atmo(terrain, WIND_KMH, from)
			a.set_thermal_mode("static")
			a.set_air_field(WindField.load_file(_field_path("altai", "sinyukha_west")), 0.0)
			var st := _series(a, pos, 120.0)
			var row := {"case": "Синюха: " + String(pt[0]), "agl": agl,
				"sigma_u": st.sigma_u, "sigma_w": st.sigma_w}
			a.free()
			a = _make_atmo(terrain, WIND_KMH, from)
			a.set_thermal_mode("static")
			var sa := _series(a, pos, 120.0)
			row["analytic_sigma_u"] = sa.sigma_u
			row["analytic_sigma_w"] = sa.sigma_w
			a.free()
			out.append(row)
			print(JSON.stringify(row))
	terrain.free()
	return out


## Прямая траектория поперёк ветра на постоянной высоте над морем (Аушкуль, поле
## aushtau_east), 12 м/с, 400 с, 50 Гц: ряды u (вдоль ветра поля) и w — csv для spectrum.py.
func _spectrum() -> Dictionary:
	var res := {}
	var terrain := _load_terrain("aushkul")
	var site: Dictionary = {}
	for s: Dictionary in terrain.get_start_sites():
		if String(s.id) == "aushtau_east":
			site = s
	var from := fposmod(float(site.heading_deg) + 180.0, 360.0)
	var d := deg_to_rad(from)
	var across := Vector2(cos(d), sin(d))
	var p0: Vector3 = site.position
	for mode in ["field", "analytic"]:
		for alt: float in [150.0, 400.0]:
			var a := _make_atmo(terrain, WIND_KMH, from)
			a.set_thermal_mode("static")
			if mode == "field":
				a.set_air_field(WindField.load_file(_field_path("aushkul", "aushtau_east")), 0.0)
			var y := p0.y + alt
			var hz := 50.0
			var n := int(400.0 * hz)
			var start := Vector2(p0.x, p0.z) - across * 2400.0
			var path := "%s/flight_%s_%d.csv" % [out_dir, mode, int(alt)]
			var f := FileAccess.open(path, FileAccess.WRITE)
			f.store_line("t,u,v,w,agl")
			var md := Vector2(a.wind.dir.x, a.wind.dir.z)
			for i in n:
				var t := i / hz
				var q := start + across * 12.0 * t
				var pos := Vector3(q.x, y, q.y)
				a.step(1.0 / hz)
				var v := a.air_velocity_at(pos)
				f.store_line(
					"%.3f,%.4f,%.4f,%.4f,%.1f"
					% [t, v.x * md.x + v.z * md.y, v.x * md.y - v.z * md.x, v.y,
						y - terrain.height_at(q.x, q.y)]
				)
			f.close()
			res["%s_%d" % [mode, int(alt)]] = path
			a.free()
	terrain.free()
	return res
