extends Node
## RW-11d: дамп CloudField / CloudPhysics на опорной ревизии c591b1026 (без GPU, без окна).
## Запуск: run_dump.sh <копия на c591b1026> <каталог вывода> <поле Онгудая: каталог с field.json+field.bin>
## Пишет <out>/ref.json + ref.bin (zstd от склейки little-endian массивов; json["arrays"][имя] = [смещение, число, "f32"|"f64"]).
## Случаи: ongudai (поле RW-10d, AirThermals.build без земли), синтетические flat_field (как test_cloud_field.gd).

const N := 48
const NZ := 40
const DX := 400.0
const DZ := 100.0
const GROUND := 1000.0
const Z_BOT := 950.0

var _body := PackedByteArray()
var _arrays := {}
var _meta := {}


func _ready() -> void:
	var out_dir := ""
	var field_dir := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out_dir = a.substr(6)
		elif a.begins_with("--field="):
			field_dir = a.substr(8)
	DirAccess.make_dir_recursive_absolute(out_dir)
	_ongudai(field_dir)
	_synthetic()
	_physics()
	var raw_n := _body.size()
	var comp := _body.compress(FileAccess.COMPRESSION_ZSTD)
	var fb := FileAccess.open(out_dir.path_join("ref.bin"), FileAccess.WRITE)
	fb.store_buffer(comp)
	fb.close()
	_meta["arrays"] = _arrays
	_meta["raw_bytes"] = raw_n
	var fj := FileAccess.open(out_dir.path_join("ref.json"), FileAccess.WRITE)
	fj.store_string(JSON.stringify(_meta, "\t", true) + "\n")
	fj.close()
	get_tree().quit(0)


func _add(name: String, v: Variant, kind: String = "f32") -> void:
	var raw: PackedByteArray
	var n: int
	if kind == "f64":
		var a := PackedFloat64Array(v)
		raw = a.to_byte_array()
		n = a.size()
	else:
		var a := PackedFloat32Array(v)
		raw = a.to_byte_array()
		n = a.size()
	_arrays[name] = [_body.size(), n, kind]
	_body.append_array(raw)


func _cfg() -> Dictionary:
	return Config.get_config("atmosphere").cloud_field


func _snap(name: String, cf: CloudField) -> void:
	_add(name + ".cover", cf.cover)
	_add(name + ".depth", cf.depth)
	_add(name + ".stage", cf.stage)
	_add(name + ".activity", cf.activity)
	_add(name + ".sc", [cf.bg_cover, cf.bg_depth, cf.base_msl, cf.time], "f64")


func _thermals_cfg(cb: float, duty: float) -> Dictionary:
	var c: Dictionary = Config.get_config("atmosphere").thermal.duplicate()
	c["duty"] = duty
	c["cloudbase_msl"] = cb
	return c


func _weather(z_lcl: float, depth_m := 800.0, overdev := 0.0) -> Dictionary:
	return {
		cloud_depth_m = depth_m,
		overdevelopment_chance = overdev,
		stability_n_per_s = 0.012,
		_derived = {z_lcl_msl_m = z_lcl, temperature_c = 25.0, dew_point_c = 8.0},
	}


# ------------------------------------------------------------------ Онгудай


func _ongudai(field_dir: String) -> void:
	var fs := AirBakedField.load_file(field_dir.path_join("field.json"))
	var f: WindField = fs.levels[0]
	var cb := 3035.66521281331
	var air := AirThermals.new()
	air.build(f, _thermals_cfg(cb, 0.85))
	var inp := {air = air, wind_field = f, weather = _weather(cb), seed = 606}
	var cf := CloudField.new(_cfg())
	cf.set_inputs(inp)
	cf.reset(0.0)
	_snap("og_r0", cf)
	cf.reset(900.0)
	_snap("og_r900", cf)
	cf.reset(3600.0)
	_snap("og_r3600", cf)
	cf.step_to(3620.0)
	_snap("og_s3620", cf)
	cf.step_to(3700.0)
	_snap("og_s3700", cf)
	# выборка на состоянии 3700
	var pts := PackedFloat32Array()
	var sm := PackedFloat32Array()
	var dn := PackedFloat32Array()
	var sh := PackedFloat32Array()
	var sun := Vector3(0.3, 0.8, 0.2).normalized()
	for jz in 15:
		for ix in 15:
			var x := -16000.0 + ix * 2285.0
			var z := -16000.0 + jz * 2285.0
			for hy in [-100.0, 150.0, 500.0, 900.0]:
				var p := Vector3(x, cf.base_msl + hy, z)
				pts.append_array([p.x, p.y, p.z])
				var s := cf.sample(p)
				sm.append_array([s.x, s.y, s.z, s.w])
				dn.append(cf.density_at(p))
			sh.append(cf.shade_at(Vector2(x, z), sun))
	_add("og_pts", pts)
	_add("og_sample", sm)
	_add("og_density", dn)
	_add("og_shade", sh)
	_add("og_sun", [sun.x, sun.y, sun.z])
	# разгон по шагам: reset(900) = время -1500 + 120 шагов
	var c2 := CloudField.new(_cfg())
	c2.set_inputs(inp)
	c2._started = true
	c2.time = 900.0 - 2400.0
	var ks := [5, 30, 60, 100, 120]
	for k in ks:
		c2.step_to(900.0 - 2400.0 + 20.0 * k)
		_snap("og_spin%d" % k, c2)
	# смена входов (LCL ниже): переход input_blend_s
	var inp2 := {air = air, wind_field = f, weather = _weather(cb - 300.0), seed = 606}
	cf.set_inputs(inp2)
	cf.step_to(3700.0 + 20.0)
	_snap("og_b20", cf)
	cf.step_to(3700.0 + 60.0)
	_snap("og_b60", cf)
	cf.step_to(3700.0 + 200.0)
	_snap("og_b200", cf)
	_meta["ongudai"] = {cb = cb, seed = 606, duty = 0.85, n = f.nx * f.ny, weather_lcl2 = cb - 300.0}


# ------------------------------------------------------------------ синтетика


func _flat_field(heat_fn: Callable, z_i: float, wind := Vector2.ZERO, gam_above := 0.0058) -> WindField:
	var m := {
		dx = DX, dz = DZ, x0 = -N * DX * 0.5, y0 = -N * DX * 0.5, z_bot = Z_BOT,
		nx = N, ny = N, nz = NZ, z0 = 0.1, z_i = z_i, u10 = wind.length() / 1.8,
	}
	var gam := []
	for k in NZ:
		gam.append(0.0 if Z_BOT + (k + 0.5) * DZ < z_i else gam_above)
	m["gam"] = gam
	var n := N * N * NZ
	var u := PackedFloat32Array()
	var v := PackedFloat32Array()
	var wm := PackedFloat32Array()
	var wc := PackedFloat32Array()
	var th := PackedFloat32Array()
	for a: PackedFloat32Array in [u, v, wm, wc, th]:
		a.resize(n)
	u.fill(wind.x)
	v.fill(-wind.y)
	var hc := PackedFloat32Array()
	hc.resize(N * N)
	hc.fill(GROUND)
	var heat := PackedFloat32Array()
	heat.resize(N * N)
	for j in N:
		for i in N:
			var x: float = m.x0 + (i + 0.5) * DX
			var zw: float = -(m.y0 + (j + 0.5) * DX)
			heat[j * N + i] = float(heat_fn.call(x, zw))
	m["heat"] = heat
	return WindField.from_arrays(m, u, v, wm, wc, th, hc)


func _blob(cx: float, cz: float, r: float, h: float) -> Callable:
	return func(x: float, z: float) -> float:
		return h if Vector2(x - cx, z - cz).length() < r else 0.0


func _synth_case(name: String, f: WindField, z_lcl: float, seed: int, t0: float, t1: float, depth := 800.0, overdev := 0.0) -> void:
	var duty := float(Config.get_config("weather/medium").thermal_duty)
	var air := AirThermals.new()
	air.build(f, _thermals_cfg(z_lcl, duty))
	var cf := CloudField.new(_cfg())
	cf.set_inputs({air = air, wind_field = f, weather = _weather(z_lcl, depth, overdev), seed = seed})
	cf.reset(t0)
	cf.step_to(t1)
	_snap(name, cf)


func _synthetic() -> void:
	_synth_case("sy_blob", _flat_field(_blob(0.0, 0.0, 4000.0, 300.0), 2500.0), 2000.0, 1, 0.0, 1800.0)
	_synth_case("sy_wind", _flat_field(_blob(1000.0, -2000.0, 5000.0, 250.0), 2500.0, Vector2(4.0, 1.0)), 2000.0, 7, 100.0, 2500.0)
	_synth_case("sy_tower", _flat_field(_blob(0.0, 0.0, 6000.0, 400.0), 2800.0), 1800.0, 3, 0.0, 7200.0, 800.0, 0.5)
	_synth_case("sy_advect", _flat_field(_blob(-4000.0, 0.0, 2500.0, 300.0), 2500.0, Vector2(6.0, 0.0)), 2000.0, 1, 0.0, 3600.0)
	# аналитика: два термика
	var cf := CloudField.new(_cfg())
	cf.setup_grid(N, N, DX, -N * DX * 0.5, -N * DX * 0.5)
	var th := AtmoThermal.new()
	th.src = Vector3(2000.0, 1000.0, -3000.0)
	th.top = 2600.0
	th.strength = 3.0
	th.radius = 180.0
	th.env = 1.0
	th.cloud_depth = 600.0
	var dry := AtmoThermal.new()
	dry.src = Vector3(-6000.0, 1000.0, 6000.0)
	dry.top = 1800.0
	dry.strength = 3.0
	dry.radius = 180.0
	dry.env = 1.0
	cf.set_inputs({
		thermals = [th, dry], cloudbase_msl = 2500.0, ground_ref = 1000.0,
		wind_at = func(_z: float) -> Vector2: return Vector2.ZERO,
	})
	cf.reset(0.0)
	cf.step_to(1800.0)
	_snap("sy_analytic", cf)


# ------------------------------------------------------------------ физика


func _physics() -> void:
	# поле — из синтетики sy_wind (облака есть), 2500 с
	var f := _flat_field(_blob(1000.0, -2000.0, 5000.0, 250.0), 2500.0, Vector2(4.0, 1.0))
	var duty := float(Config.get_config("weather/medium").thermal_duty)
	var air := AirThermals.new()
	air.build(f, _thermals_cfg(2000.0, duty))
	var cf := CloudField.new(_cfg())
	cf.set_inputs({air = air, wind_field = f, weather = _weather(2000.0), seed = 7})
	cf.reset(100.0)
	cf.step_to(2500.0)
	var t := 2500.0
	var ph := CloudPhysics.new()
	var atm := Config.get_config("atmosphere")
	ph.setup(atm.clouds, atm.thermal, 1.0)
	ph.field = cf
	# термики: LCG
	var seed := 12345
	var ths: Dictionary = {}
	var rows := []
	var cover_cols := []
	for c in N * N:
		if cf.cover[c] > 0.3:
			cover_cols.append(c)
	for k in 14:
		seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF
		var r1 := float(seed % 1000) / 1000.0
		seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF
		var r2 := float(seed % 1000) / 1000.0
		var th := AtmoThermal.new()
		th.id = 100 + k
		var is_cb := k >= 10
		var x := 0.0
		var z := 0.0
		if k < 10 and not cover_cols.is_empty():
			var c: int = cover_cols[(k * 7) % cover_cols.size()]
			x = cf.x0 + (c % N + 0.5) * DX + (r1 - 0.5) * 200.0
			z = -(cf.y0 + (c / N + 0.5) * DX) + (r2 - 0.5) * 200.0
		else:
			x = (r1 - 0.5) * 8000.0
			z = (r2 - 0.5) * 8000.0
		th.src = Vector3(x, 1000.0, z)
		th.top = cf.base_msl + 100.0 + 400.0 * r1
		th.strength = 1.5 + 3.0 * r2
		th.radius = 150.0 + 100.0 * r1
		th.lean = Vector2(0.05 * (r1 - 0.5), 0.05 * (r2 - 0.5))
		th.drift_vel = Vector2(4.0 * r2, 1.0 * r1)
		th.drift_delay = 600.0 if k % 2 == 0 else -1.0
		th.t_birth = t - 400.0 - 50.0 * (k - 10) if is_cb else t - 900.0 - 100.0 * k
		th.t_grow = 180.0
		th.t_mature = 1500.0 if is_cb else 600.0
		th.t_decay = 240.0
		th.has_cloud = is_cb
		th.cloud_depth = 6000.0 if is_cb else 500.0
		th.cloud_stretch = 1.0 + 0.5 * r1
		th.overdevelop = 1.0 if is_cb else r2
		th.is_cb = is_cb
		th.suck = 0.4 if is_cb else 0.0
		th.is_static = (k == 9)
		if is_cb:
			th.strength *= 1.5
			th.top = cf.base_msl + 200.0
		th.update_time(t)
		ths[th.id] = th
		rows.append([th.id, th.is_static, th.src.x, th.src.y, th.src.z, th.top, th.strength, th.radius, th.lean.x, th.lean.y, th.drift_vel.x, th.drift_vel.y, th.drift_delay, th.t_birth, th.t_grow, th.t_mature, th.t_decay, th.has_cloud, th.cloud_depth, th.cloud_stretch, th.overdevelop, th.is_cb, th.suck])
	_meta["phys_thermals"] = rows
	_meta["phys_t"] = t
	ph._refresh_objects(ths, t, Vector3.ZERO, 6000.0)
	_meta["phys_count"] = ph.cloud_count()
	var sk := PackedFloat32Array()
	for id in ths:
		var s := ph.suck(ths[id], t)
		sk.append_array([s.x, s.y])
	_add("ph_suck", sk)
	var pts := PackedFloat32Array()
	var sm := PackedFloat32Array()
	var dn := PackedFloat32Array()
	for jz in 21:
		for ix in 21:
			for hy in [-100.0, 100.0, 300.0, 700.0, 1500.0, 3000.0]:
				var p := Vector3(-7000.0 + ix * 700.0, cf.base_msl + hy, -7000.0 + jz * 700.0)
				pts.append_array([p.x, p.y, p.z])
				var s3 := ph.sample(p)
				sm.append_array([s3.x, s3.y, s3.z])
				dn.append(ph.density_at(p))
	_add("ph_pts", pts)
	_add("ph_sample", sm)
	_add("ph_density", dn)
	var vc := PackedFloat32Array()
	for cl: Dictionary in ph.visible_clouds(ths, t, Vector3.ZERO):
		var c: Vector2 = cl.center
		vc.append_array([c.x, c.y, cl.radius, cl.growth, cl.decay])
	_add("ph_visible", vc)
	_add("ph_field", [cf.base_msl, cf.time], "f64")
	_snap("ph", cf)
