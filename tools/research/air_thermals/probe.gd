extends Node
## AM-07: замеры термиков из поля (docs/air_model.md → «Масштаб 2: термики из поля»).
## Поля — tools/research/air_thermals/make_fields.py (эталон AM-01, вне git: fields/).
##
##   XDG_DATA_HOME=$(mktemp -d) godot --headless --path . \
##     res://tools/research/air_thermals/probe.tscn -- [--quick]
##
## Пишет out/*.json (источники и столбцы для картинок — figs.py, таблицы — README.md):
##   sources_<поле>.json — источники и карты столбцов (H, W̄, F̄, Φ, водосбор) на реальном рельефе;
##   stats.json — термики за 4 ч (сила, потолок, расстояние до соседа) с полем и без;
##   flux.json — поток массы пузырей против поля (Монте-Карло) по водосборам и по площади;
##   net.json — источники без ведущего на поле с шумом 1e-3·|u₀| (сколько расходится).

const SEED := 42
const DIR := "res://tools/research/air_thermals/"
const FIELDS := [
	"kayancha_w100_h12",
	"kayancha_w100_h15",
	"kayancha_w100_h09",
	"ongudai_d400_h12",
	"ongudai_d400_h15",
	"ongudai_d400_h09"
]
const DT := 5.0
const DAY_S := 4.0 * 3600.0
## Статистика термиков — в круге этого радиуса у старта Каянча (внутри области поля), м.
const STATS_R := 6000.0

var _quick := false
var _terrain: Terrain


func _ready() -> void:
	_quick = "--quick" in OS.get_cmdline_user_args()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DIR + "out"))
	_terrain = Terrain.new()
	_terrain.location_id = ""
	if not _terrain.load_location("ongudai"):
		push_error("нет рельефа ongudai")
		get_tree().quit(1)
		return
	var net := {}
	for name: String in FIELDS if not _quick else ["kayancha_w100_h12"]:
		var f := WindField.load_file(ProjectSettings.globalize_path(DIR + "fields/" + name))
		if f == null:
			continue
		var a := _atmo(f)
		var t0 := Time.get_ticks_usec()
		a.set_air_field(f, 0.0)
		a.refresh_now()
		var build_ms := (Time.get_ticks_usec() - t0) * 1.0e-3
		var s := a.field.air_src
		_dump_sources(name, f, s, build_ms)
		if name.begins_with("kayancha") or not _quick:
			net[name] = _net_noise(f, a)
		a.free()
	_save("net.json", net)
	var f12 := WindField.load_file(ProjectSettings.globalize_path(DIR + "fields/kayancha_w100_h12"))
	var fl := _flux(f12)
	fl["by_thermal"] = _flux_count(f12, true)
	fl["by_thermal_calm_noshade"] = _flux_count(f12, false)
	_save("flux.json", fl)
	if not _quick:
		var stats := {}
		for name: String in ["ongudai_d400_h12", "ongudai_d400_h15", "ongudai_d400_h09"]:
			var f := WindField.load_file(ProjectSettings.globalize_path(DIR + "fields/" + name))
			stats[name] = {"field": _day_stats(f, true), "analytic": _day_stats(f, false)}
		_save("stats.json", stats)
	_terrain.free()
	get_tree().quit(0)


func _atmo(f: WindField) -> Atmosphere:
	var w: Dictionary = Config.get_config("weather/medium").duplicate(true)
	var m := f.meta
	w.wind_speed_kmh = Units.to_kmh(float(m.get("u10", 3.0)))
	w.wind_from_deg = float(m.get("wdir", 150.0))
	w.thermal_extreme_chance = 0.0
	var a := Atmosphere.new()
	a.visuals_enabled = false
	a.seed_value = SEED
	a.configure(Config.get_config("atmosphere").duplicate(true), w)
	a.set_ground(_terrain.height_at, _terrain.thermal_source_strength_at, _terrain.surface_at)
	a.set_cloudbase_msl(float(m.get("z_lcl", 2700.0)))
	a.turbulence_enabled = false
	var c := f.center_xz()
	a.set_focus(Vector3(c.x, 2000.0, c.y))
	a.step(0.01)
	return a


func _dump_sources(name: String, f: WindField, s: AirThermals, build_ms: float) -> void:
	if s == null:
		print("%s: источников нет (нет входа)" % name)
		return
	var src := []
	var ks := []
	var agl := []
	for k in s.count():
		var p := s.pos[k]
		(
			src
			. append(
				{
					"x": p.x,
					"z": p.z,
					"y": p.y,
					"w0": s.w0[k],
					"wstar": s.wstar[k],
					"top": s.top[k],
					"drift": [s.drift[k].x, s.drift[k].y],
					"flux": s.flux[k],
					"carried": s.carried[k],
					"area": s.area[k],
					"depth": s.depth[k],
				}
			)
		)
		ks.append(s.w0[k] / maxf(s.wstar[k], 1e-6))
		agl.append(minf(s.top[k], float(f.meta.z_lcl)) - p.y)
	var out := {
		"name": name,
		"build_ms": build_ms,
		"nx": f.nx,
		"ny": f.ny,
		"dx": f.dx,
		"x0": f.x0,
		"y0": f.y0,
		"z_i": f.meta.z_i,
		"z_lcl": f.meta.z_lcl,
		"hour": f.meta.cond.hour,
		"hc": Array(f.raw_hc()),
		"heat": Array(s.col_heat),
		"wbar": Array(s.col_w),
		"fbar": Array(s.col_f),
		"phi": Array(s.phi),
		"owner": Array(s.owner),
		"sources": src,
		"total_flux": s.total_flux,
		"carried_flux": s.carried_flux,
		"lost_flux": s.lost_flux,
		"life_mean": s.life_mean,
	}
	_save("sources_%s.json" % name, out)
	print(
		(
			"%s: источников %d (%.0f мс), w0 %s м/с, w0/w* %s, столб %s м; ядра несут %.0f %% потока"
			% [
				name,
				s.count(),
				build_ms,
				_stat(Array(s.w0)),
				_stat(ks),
				_stat(agl),
				100.0 * s.carried_flux / maxf(s.total_flux, 1.0)
			]
		)
	)


## Сеть: источники на поле и на поле с шумом 1e-3·|u₀| без ведущего — сколько столбцов разошлось.
func _net_noise(f: WindField, a: Atmosphere) -> Dictionary:
	var u0 := 1.8 * float(f.meta.get("u10", 3.0))
	var out := {}
	for amp: float in [1.0e-3 * u0, 1.0e-4 * u0]:
		var g := _noisy(f, amp)
		var cfg := a.field._cfg.duplicate()
		cfg["radius_m"] = a.field._w.thermal_radius_m
		cfg["duty"] = float(a.field._w.thermal_duty)
		cfg["cloudbase_msl"] = a.field.cloudbase_msl
		var s1 := AirThermals.new()
		s1.build(f, cfg)
		var s2 := AirThermals.new()
		s2.build(g, cfg)
		var set1 := {}
		for c in s1.col:
			set1[c] = true
		var diff := 0
		for c in s2.col:
			if not set1.has(c):
				diff += 1
		out["%.5f" % amp] = {"n1": s1.count(), "n2": s2.count(), "diff": diff}
		print(
			(
				"  сеть %s, шум %s м/с: источников %d / %d, других %d"
				% [f.meta.cond.level, "%.5f" % amp, s1.count(), s2.count(), diff]
			)
		)
	return out


static func _noisy(f: WindField, amp: float) -> WindField:
	var rng := RandomNumberGenerator.new()
	rng.seed = 777
	var n := f.nx * f.ny * f.nz
	var arr := []
	for q in 5:
		var a := PackedFloat32Array()
		a.resize(n)
		arr.append(a)
	for c in n:
		arr[0][c] = f.raw_vel()[c * 3] + rng.randf_range(-amp, amp)
		arr[1][c] = f.raw_vel()[c * 3 + 1] + rng.randf_range(-amp, amp)
		arr[2][c] = f.raw_vel()[c * 3 + 2] + rng.randf_range(-amp, amp)
		arr[3][c] = f.raw_w_conv()[c] + rng.randf_range(-amp, amp)
		arr[4][c] = f.raw_theta()[c] + rng.randf_range(-amp, amp)
	var m := f.meta.duplicate()
	m["heat"] = f.heat_flux()
	return WindField.from_arrays(m, arr[0], arr[1], arr[2], arr[3], arr[4], f.raw_hc())


## Поток массы: Монте-Карло 60 мин (шаг 30 с) на ξ = 0,25/0,5/0,75 — ядра пузырей (w > 0 без
## «между») против ожидания поля (AirThermals.expected_up) по водосборам и по внутренней площади;
## и полный конвективный (пузыри + между) против w_conv поля.
func _flux(f: WindField) -> Dictionary:
	var a := _atmo(f)
	a.set_air_field(f, 0.0)
	a.start_at(0.0)
	var s := a.field.air_src
	var tf := a.field
	var levels := [0.25, 0.5, 0.75]
	var got := {}
	var want := {}
	var tot := {}
	var wc := {}
	var per_got := {}
	var per_want := {}
	for xi: float in levels:
		got[xi] = 0.0
		want[xi] = 0.0
		tot[xi] = 0.0
		wc[xi] = 0.0
	var n := 0
	var step := 40.0 if not _quick else 80.0
	var t := 0.0
	var dur := 3600.0 if not _quick else 1200.0
	var fc := f.center_xz()
	var half := 0.5 * f.size_x() - (f.edge_cells + 3.0) * f.dx
	while t < dur:
		a.step(30.0)
		t += 30.0
		for zz in range(0, int(2.0 * half / step) + 1):
			for xx in range(0, int(2.0 * half / step) + 1):
				var x := fc.x - half + xx * step
				var z := fc.y - half + zz * step
				var ci := int(floor((x - f.x0) / f.dx))
				var cj := int(floor((-z - f.y0) / f.dx))
				var col := cj * f.nx + ci
				var o := s.owner[col]
				var hc := f.raw_hc()[col]
				var d := s.depth[o] if o >= 0 else 1500.0
				for xi: float in levels:
					var p := Vector3(x, hc + xi * d, z)
					tf.air_src = null
					var wb := tf.sample(p).x
					tf.air_src = s
					var full := tf.sample(p)
					var e := s.expected_up(p)
					got[xi] += maxf(wb, 0.0)
					want[xi] += e
					tot[xi] += full.x
					wc[xi] += a.air_field.sample_w_conv(p, NAN).x
					if xi == 0.5 and o >= 0:
						per_got[o] = float(per_got.get(o, 0.0)) + maxf(wb, 0.0)
						per_want[o] = float(per_want.get(o, 0.0)) + e
				n += 1
	var rows := []
	for xi: float in levels:
		(
			rows
			. append(
				{
					"xi": xi,
					"bubbles_up": got[xi] / n,
					"field_expected": want[xi] / n,
					"ratio": got[xi] / maxf(want[xi], 1e-9),
					"total_conv": tot[xi] / n,
					"field_wconv": wc[xi] / n,
				}
			)
		)
		print(
			(
				"  поток ξ %.2f: ядра %.3f, ожидание %.3f (%.2f); пузыри+между %.3f, w_conv поля %.3f м/с"
				% [
					xi,
					got[xi] / n,
					want[xi] / n,
					got[xi] / maxf(want[xi], 1e-9),
					tot[xi] / n,
					wc[xi] / n
				]
			)
		)
	# по водосборам: 12 крупнейших
	var owners := per_want.keys()
	owners.sort_custom(func(p: int, q: int) -> bool: return s.area[p] > s.area[q])
	var catch := []
	for o: int in owners.slice(0, 12):
		(
			catch
			. append(
				{
					"source": o,
					"area_km2": s.area[o] * 1e-6,
					"w0": s.w0[o],
					"wstar": s.wstar[o],
					"ratio": float(per_got[o]) / maxf(float(per_want[o]), 1e-9),
					"x": s.pos[o].x,
					"z": s.pos[o].z,
				}
			)
		)
	a.free()
	return {"levels": rows, "catchments": catch, "samples": n}


## Термики за 4 ч (как база AM-00, probe.gd): сила, потолок над землёй, расстояние до ближайшего
## одновременно живого — термики с источником в круге STATS_R у Каянчи (фокус), с полем и без
## (та же погода medium, та же кромка).
func _day_stats(f: WindField, use_field: bool) -> Dictionary:
	var a := _atmo(f)
	if use_field:
		a.set_air_field(f, 0.0)
	var site: Dictionary = _terrain.get_start_sites()[0]
	var focus: Vector3 = site.position
	var seen := {}
	var nb_sum := 0.0
	var nb_n := 0
	var t := 0.0
	var i := 0
	var dur := DAY_S if not _quick else 1800.0
	while t < dur:
		a.set_focus(focus)
		a.step(DT)
		var alive := []
		for id in a.field.thermals:
			var th: AtmoThermal = a.field.thermals[id]
			if Vector2(th.src.x - focus.x, th.src.z - focus.z).length() > STATS_R:
				continue
			alive.append(th)
			if not seen.has(id):
				seen[id] = [th.strength, th.top - th.src.y, th.cell.x >= 1 << 19]
		if i % 12 == 0:
			for p: AtmoThermal in alive:
				var best := 1.0e18
				for q: AtmoThermal in alive:
					if q != p:
						best = minf(
							best, Vector2(p.src.x, p.src.z).distance_to(Vector2(q.src.x, q.src.z))
						)
				if best < 1.0e17:
					nb_sum += best
					nb_n += 1
		t += DT
		i += 1
	var st := []
	var ce := []
	var n_air := 0
	for v: Array in seen.values():
		st.append(v[0])
		ce.append(v[1])
		n_air += 1 if v[2] else 0
	a.free()
	var r := {
		"count": seen.size(),
		"from_field": n_air,
		"strength": _stats(st),
		"ceiling_agl": _stats(ce),
		"neighbor_m": nb_sum / maxi(nb_n, 1),
	}
	print("  %s %s: %s" % [f.meta.cond.hour, "поле" if use_field else "аналитика", r])
	return r


static func _stats(v: Array) -> Dictionary:
	if v.is_empty():
		return {}
	v.sort()
	var s := 0.0
	for x: float in v:
		s += x
	var n := v.size()
	return {
		"mean": s / n,
		"p10": v[int(0.1 * (n - 1))],
		"p50": v[int(0.5 * (n - 1))],
		"p90": v[int(0.9 * (n - 1))]
	}


static func _stat(v: Array) -> String:
	var s := _stats(v)
	if s.is_empty():
		return "—"
	return "%.2f [%.2f…%.2f]" % [s.mean, s.p10, s.p90]


func _save(name: String, d: Variant) -> void:
	var fa := FileAccess.open(ProjectSettings.globalize_path(DIR + "out/" + name), FileAccess.WRITE)
	fa.store_string(JSON.stringify(d, " "))
	fa.close()


## Поток ядер по термикам (без пространства): Σ по живым термикам источников поля их поток ядра
## на ξ = 0,5 (π R² e⁻¹ · сила · огибающая, отрыв низа) против Σ ожидания источников (carried·q/q̄).
## real = false — без тени облаков (cloud_shade_factor = 0): чистая статистика жизни.
func _flux_count(f: WindField, real: bool) -> Dictionary:
	var a := _atmo(f)
	if not real:
		a.field._cfg["cloud_shade_factor"] = 0.0
	a.set_air_field(f, 0.0)
	a.start_at(0.0)
	var s := a.field.air_src
	var rmin := float(a.field._cfg.radius_min_factor)
	var got := 0.0
	var n := 0
	var t := 0.0
	while t < 3600.0:
		a.step(30.0)
		t += 30.0
		for id in a.field.thermals:
			var th: AtmoThermal = a.field.thermals[id]
			if th.cell.x < 1 << 19 or t > th.t_end():
				continue
			var d := th.top - th.src.y
			var y := th.src.y + 0.5 * d
			if y < th.cut_h:
				continue
			var rf := maxf(rmin, pow(0.5, 1.0 / 3.0) * (1.0 - 0.125) / 0.75)
			var r := th.radius * rf
			got += AirThermals.CORE_FLUX * PI * r * r * th.strength * th.envelope(t)
		n += 1
	var want := 0.0
	for k in s.count():
		var p := s.pos[k]
		want += s.carried[k] * s._q[(s._NQ - 1) / 2] / s._q_mean
	got /= n
	print(
		(
			"  поток по термикам (%s): %.0f м³/с против ожидания %.0f — %.2f"
			% ["с тенью" if real else "без тени", got, want, got / want]
		)
	)
	a.free()
	return {"got": got, "want": want, "ratio": got / want}
