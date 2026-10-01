extends Node
## Выгрузка поля ветра из игры (Atmosphere.air_velocity_at / mean_wind_at — то, что чувствует
## планер) в регулярной сетке у старта; один и тот же скрипт для main и feature/air-model.
## Режим air-model (если есть AirRuntime): решатель на GPU (область 400 м + окна 100/50 м у старта),
## поэтому запуск НЕ headless: tools/research/wind_compare/run.sh <копия> <имя>
## Аргументы (после --): --out=<json> --loc=ongudai --wind=3 --from=151 --hour=12 --seed=20260401
##   --half=1000 --step=100 --thermals=0|1 --sky=clear
##   --turb=N — ещё N выборок с болтанкой в каждой точке (через 7,3 с): levels.<agl>.turb =
##   [[w_min, σ_w, w_ср], …] (AM-08в: пики рывков); air/mean — как всегда, без болтанки
##   --diag=1 — levels.<agl>.diag = [[r, dx, lee_f, U_H], …]: превышение гребня (relief_at), клетка
##   поля (sample_dx), признак отрыва поля, ветер поля на уровне гребня (AM-08в)
## Координаты выгрузки: east, north — м от старта; up — м над уровнем моря; agl — над рельефом.

var LEVELS: Array = [10.0, 20.0, 50.0, 100.0, 200.0, 400.0, 600.0]
var _a: Dictionary = {}


func _ready() -> void:
	for s in OS.get_cmdline_user_args():
		if s.begins_with("--"):
			var kv := s.substr(2).split("=", true, 1)
			_a[kv[0]] = kv[1] if kv.size() > 1 else "1"
	await get_tree().process_frame
	await _run()
	get_tree().quit(0)


func _run() -> void:
	var loc_id := String(_a.get("loc", "ongudai"))
	var wind_ms := float(_a.get("wind", 3.0))
	var wdir := float(_a.get("from", 151.0))
	var hour := float(_a.get("hour", 12.0))
	var seed_v := int(_a.get("seed", 20260401))
	var half := float(_a.get("half", 1000.0))
	var step := float(_a.get("step", 100.0))
	var therm := String(_a.get("thermals", "0")) == "1"
	var sky := String(_a.get("sky", "clear"))
	var cx := float(_a.get("cx", 0.0))  # центр выборки: восток от старта, м
	var cn := float(_a.get("cn", 0.0))  # север от старта, м
	if _a.has("levels"):
		LEVELS = []
		for t in String(_a.levels).split(","):
			LEVELS.append(float(t))
	var ground_only := String(_a.get("ground_only", "0")) == "1"
	var out_path := String(_a.get("out", "out/wind.json"))

	var terrain := Terrain.new()
	add_child(terrain)
	if not terrain.load_location(loc_id):
		push_error("нет локации")
		return
	var loc_cfg: Dictionary = Config.get_config("locations/" + loc_id)
	var site: Dictionary = loc_cfg.start_sites[0]
	var s2 := terrain.latlon_to_local(float(site.lat), float(site.lon))
	var sx := s2.x
	var sz := s2.y
	var s_h := terrain.height_at(sx, sz)
	var utc := float(loc_cfg.get("utc_offset_h", NAN))

	var w: Dictionary = Config.get_config("weather/medium").duplicate(true)
	w.wind_speed_kmh = wind_ms * 3.6
	w.wind_from_deg = wdir
	if not therm:
		w.thermal_mode = "static"
		w.static_thermals = []
	var atmo = Atmosphere.new()
	atmo.visuals_enabled = false
	atmo.seed_value = seed_v
	atmo.configure(Config.get_config("atmosphere"), w)
	var src: Callable = (
		terrain.thermal_source_strength_at
		if terrain.has_method("thermal_source_strength_at")
		else terrain.sun_exposure_at
	)
	atmo.set_ground(terrain.height_at, src, terrain.surface_at)
	atmo.set_wind(wind_ms * 3.6, wdir, s_h)
	atmo.turbulence_enabled = false
	atmo.wave.enabled = false
	atmo.time_s = hour * 3600.0
	atmo.set_focus(Vector3(sx, s_h, sz))
	atmo.step(0.01)

	var info := {"air_runtime": false}
	if ground_only:
		var gg: Array = []
		var m := int(round(2.0 * half / step)) + 1
		for j in m:
			for i in m:
				gg.append(terrain.height_at(sx - half + i * step, sz + half - j * step))
		var fo := FileAccess.open(out_path, FileAccess.WRITE)
		fo.store_string(JSON.stringify({"n": m, "step": step, "half": half, "start_h": s_h, "h": gg}))
		fo.close()
		return
	var rt_path := "res://scripts/atmosphere/air_model/air_runtime.gd"
	if ResourceLoader.exists(rt_path):
		var rt: Node = load(rt_path).new()
		add_child(rt)
		await get_tree().process_frame
		var c := {hour = hour, u10 = wind_ms, wdir = wdir, t_max = NAN, sky = sky}
		rt.setup(atmo, rt.get_script().place_of(terrain, utc), func() -> Dictionary: return c)
		rt.focus_fn = func() -> Vector3: return Vector3(sx, s_h, sz)
		var why: String = rt.unavailable_reason()
		info["air_runtime"] = true
		info["unavailable"] = why
		if why == "":
			var t0 := Time.get_ticks_msec()
			var ok: bool = await rt.load_field()
			info["solver_ok"] = ok
			info["solver_wall_s"] = (Time.get_ticks_msec() - t0) / 1000.0
			info["solver_info"] = rt.last_info
			info["solver_err"] = rt.last_error
		# дать окнам клипмапа подняться, подмена поля — завершиться
		for i in 600:
			await get_tree().process_frame
			if not rt.busy() and i > 30:
				break
		for i in 200:
			atmo.step(0.5)
			atmo.time_s = hour * 3600.0
			if (atmo.get("air_field") as Object).call("blend_fraction") >= 1.0:
				break
		info["blend_fraction"] = (atmo.get("air_field") as Object).call("blend_fraction")
		info["field_on"] = _on(atmo)
		var lv: Array = []
		for f in (atmo.get("air_field") as Object).get("levels"):
			lv.append({"dx": f.dx, "nx": f.nx, "ny": f.ny, "x0": f.x0, "y0": f.y0})
		info["levels"] = lv
		rt.queue_free()
	atmo.time_s = hour * 3600.0
	atmo.set_focus(Vector3(sx, s_h, sz))
	atmo.step(0.0)
	atmo.time_s = hour * 3600.0

	# выборка
	var n := int(round(2.0 * half / step)) + 1
	var ground: Array = []
	var gstep := float(_a.get("gstep", step / 2.0))
	var gn := int(round(2.0 * half / gstep)) + 1
	for j in gn:
		for i in gn:
			var e := -half + i * gstep
			var no := -half + j * gstep
			ground.append(snappedf(terrain.height_at(sx + cx + e, sz - cn - no) - s_h, 0.01))
	var data := {}
	var turb_n := int(_a.get("turb", 0))
	var diag := String(_a.get("diag", "0")) == "1" and atmo.get("air_field") != null
	for agl in LEVELS:
		var U: Array = []
		var M: Array = []
		var T: Array = []
		var DG: Array = []
		for j in n:
			for i in n:
				var e := -half + i * step
				var no := -half + j * step
				var x := sx + cx + e
				var z := sz - cn - no
				var p := Vector3(x, terrain.height_at(x, z) + agl, z)
				var v := atmo.air_velocity_at(p)
				var m := atmo.mean_wind_at(p)
				U.append([snappedf(v.x, 0.001), snappedf(-v.z, 0.001), snappedf(v.y, 0.001)])
				M.append([snappedf(m.x, 0.001), snappedf(-m.z, 0.001), snappedf(m.y, 0.001)])
				if diag:
					DG.append(_diag(atmo, p, agl))
				if turb_n > 0:
					atmo.turbulence_enabled = true
					var wmin := INF
					var s1 := 0.0
					var sq := 0.0
					for q in turb_n:
						atmo.time_s = hour * 3600.0 + q * 7.3
						var wy := atmo.air_velocity_at(p).y
						wmin = minf(wmin, wy)
						s1 += wy
						sq += wy * wy
					atmo.turbulence_enabled = false
					atmo.time_s = hour * 3600.0
					var mw := s1 / turb_n
					T.append([
						snappedf(wmin, 0.001), snappedf(sqrt(maxf(sq / turb_n - mw * mw, 0.0)), 0.001),
						snappedf(mw, 0.001)
					])
		data[str(int(agl))] = {"air": U, "mean": M}
		if turb_n > 0:
			data[str(int(agl))]["turb"] = T
		if diag:
			data[str(int(agl))]["diag"] = DG
	var res := {
		"cond": {
			"loc": loc_id, "site": site.id, "hour": hour, "wind_ms_10m": wind_ms, "wind_from": wdir,
			"seed": seed_v, "sky": sky, "weather": "weather/medium", "thermals": therm,
			"turbulence": false, "turb_samples": int(_a.get("turb", 0)), "center_east": cx, "center_north": cn, "start_world": [sx, sz], "date": "лето (дата по умолчанию в Config)", "start_h": s_h
		},
		"grid": {"half": half, "step": step, "n": n, "gstep": gstep, "gn": gn},
		"info": info, "ground": ground, "levels": data,
		"is_air_field_on": _on(atmo),
	}
	DirAccess.make_dir_recursive_absolute(out_path.get_base_dir())
	var f := FileAccess.open(out_path, FileAccess.WRITE)
	f.store_string(JSON.stringify(res))
	f.close()
	print("dump_wind: ", out_path, " air_field_on=", _on(atmo), " ", JSON.stringify(info).left(400))


func _on(atmo: Object) -> bool:
	return bool(atmo.call("is_air_field_on")) if atmo.has_method("is_air_field_on") else false


## [r, dx, lee_f, U_H] в точке — как в Atmosphere._air_velocity_field (C4 v4).
func _diag(atmo: Object, p: Vector3, agl: float) -> Array:
	var af: Object = atmo.get("air_field")
	var gh := p.y - agl
	var fw: Vector4 = af.call("sample", p, gh)
	if fw.w <= 0.0:
		return [0, 0, 0, 0]
	var r: float = (atmo.get("ground") as Object).call("relief_at", p.x, p.z)
	var dx: float = af.call("sample_dx", p, gh)
	var uf := Vector2(fw.x, fw.z).length() / fw.w
	var tb: PackedFloat32Array = af.call("sample_turb", p, gh)
	var lee_f: float = (atmo.get("field_turb") as Object).call("lee", uf, agl, tb)
	var u_h := uf
	if r > agl:
		var fh: Vector4 = af.call("sample", Vector3(p.x, gh + r, p.z), gh)
		if fh.w > 0.0:
			u_h = Vector2(fh.x, fh.z).length() / fh.w
	return [snappedf(r, 0.1), snappedf(dx, 0.1), snappedf(lee_f, 0.001), snappedf(u_h, 0.001)]
