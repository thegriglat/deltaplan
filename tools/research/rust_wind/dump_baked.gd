extends Node
## RW-6p: дамп запечённых полей воздуха (AirBakedField, AirRuntime.baked_lookup) — эталон GDScript
## для rust/dp-air/tests/baked.rs. Каждое запечённое поле обоих островов (data/locations/*/air/*.json)
## читается как в игре (AirBakedField.load_file), у каждого уровня опрашиваются точки (скорость,
## θ′, w_conv) и берутся срезы сырых массивов; выбор поля под условия — настоящий
## AirRuntime.baked_lookup на несколько сценариев (причина отказа и warn пишутся в дамп).
##
## Запуск (CPU, Godot — под замком):
##   .dpcli/dpcli lock cpu rw6p --no-tmux -- tools/research/rust_wind/dump_baked.sh
##   tools/research/rust_wind/dump_baked.sh --verify    # пересъёмка и побитное сравнение
## Выход: <out>/baked.json + baked.bin (f32 LE подряд; arrays: имя → [смещение, длина]).

const DEFAULT_OUT := "res://rust/dp-air/tests/data/baked"
const ROOT := "res://data/locations"
const N_POINTS := 700
const RAW_STRIDE := 997
const TMP_ROOT := "user://rw6p_baked"

var _arrays := {}
var _blob := PackedFloat32Array()
var _seed := 4242


func _ready() -> void:
	var out := ProjectSettings.globalize_path(DEFAULT_OUT)
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out = a.substr(6)
	DirAccess.make_dir_recursive_absolute(out)
	var ok := _run(out)
	get_tree().quit(0 if ok else 1)


func _run(out: String) -> bool:
	var files: Array = []
	var locs := Array(DirAccess.get_directories_at(ROOT))
	locs.sort()
	for lid: String in locs:
		var dir := ROOT.path_join(lid).path_join("air")
		if not DirAccess.dir_exists_absolute(dir):
			continue
		var names := Array(DirAccess.get_files_at(dir))
		names.sort()
		for n: String in names:
			if n.ends_with(".json"):
				files.append([lid, n.trim_suffix(".json")])
	if files.is_empty():
		push_error("dump_baked: нет запечённых полей в %s" % ROOT)
		return false
	var doc_files: Array = []
	var scen: Array = []
	var mh := AirBakedField.model_hash()
	for fi in files.size():
		var lid: String = files[fi][0]
		var site: String = files[fi][1]
		var path := AirBakedField.path_of(lid, site)
		var h := AirBakedField.read_header(path)
		var fs := AirBakedField.load_file(path)
		if h.is_empty() or fs == null:
			push_error("dump_baked: %s не читается" % path)
			return false
		var levels: Array = []
		for li in fs.levels.size():
			var f: WindField = fs.levels[li]
			var tag := "f%d_l%d" % [fi, li]
			_query_level(f, tag)
			levels.append({tag = tag, name = h.levels[li].name, nx = f.nx, ny = f.ny, nz = f.nz})
		doc_files.append({lid = lid, site = site, file = fi, levels = levels})
		scen.append_array(_scenarios(fi, lid, site, h, mh))
	var doc := {
		format = "dp-baked-dump",
		version = 1,
		desc = "RW-6p: эталон GDScript (AirBakedField.load_file, AirRuntime.baked_lookup) по запечённым полям data/locations",
		model_hash = mh,
		n_points = N_POINTS,
		raw_stride = RAW_STRIDE,
		files = doc_files,
		scenarios = scen,
		arrays = _arrays,
	}
	return _write(out, doc)


func _rand() -> float:
	_seed = (_seed * 1103515245 + 12345) & 0x7fffffff
	return float(_seed >> 8) / float(1 << 23)


## Точки уровня, опрос (скорость, θ′, w_conv, внутри) и срезы сырых массивов.
func _query_level(f: WindField, tag: String) -> void:
	_seed = 4242
	var x_lo := f.x0
	var x_hi := f.x0 + f.nx * f.dx
	var y_lo := f.y0
	var y_hi := f.y0 + f.ny * f.dx
	var top := f.z_bot + f.nz * f.dz
	var agls := [1.0, 5.0, 20.0, 50.0, 150.0, 400.0]
	var pos := PackedFloat32Array()
	var vel := PackedFloat32Array()
	var th := PackedFloat32Array()
	var wc := PackedFloat32Array()
	var ins := PackedFloat32Array()
	for q in N_POINTS:
		var m := 0.5 * f.dx if q % 5 == 0 else -0.5 * f.dx
		var x := lerpf(x_lo - m, x_hi + m, _rand())
		var y_g := lerpf(y_lo - m, y_hi + m, _rand())
		var z := -y_g
		var y := f.ground_height(x, z) + float(agls[q % 6]) * (0.5 + _rand())
		if q % 11 == 0:
			y = lerpf(f.z_bot - f.dz, top + f.dz, _rand())
		var p := Vector3(x, y, z)
		pos.append_array(PackedFloat32Array([p.x, p.y, p.z]))
		var v := f.sample(p, NAN)
		vel.append_array(PackedFloat32Array([v.x, v.y, v.z]))
		th.append(f.sample_theta(p, NAN))
		wc.append(f.sample_w_conv(p, NAN))
		ins.append(1.0 if f.contains(p) else 0.0)
	_add(tag + "_pos", pos)
	_add(tag + "_vel", vel)
	_add(tag + "_theta", th)
	_add(tag + "_wconv", wc)
	_add(tag + "_inside", ins)
	# срезы сырых массивов: каждая RAW_STRIDE-я клетка
	var rv := f.raw_vel()
	var rwc := f.raw_w_conv()
	var rth := f.raw_theta()
	var n := f.nx * f.ny * f.nz
	var ru := PackedFloat32Array()
	var rvv := PackedFloat32Array()
	var rwm := PackedFloat32Array()
	var rc := PackedFloat32Array()
	var rt := PackedFloat32Array()
	for c in range(0, n, RAW_STRIDE):
		ru.append(rv[c * 3])
		rvv.append(rv[c * 3 + 1])
		rwm.append(rv[c * 3 + 2])
		rc.append(rwc[c])
		rt.append(rth[c])
	_add(tag + "_raw_u", ru)
	_add(tag + "_raw_v", rvv)
	_add(tag + "_raw_wmech", rwm)
	_add(tag + "_raw_wconv", rc)
	_add(tag + "_raw_theta", rt)
	_add(tag + "_raw_hc", f.raw_hc())


## Сценарии baked_lookup для одного поля. Настоящий AirRuntime: место и площадка подставлены в
## _place, условия — по набору погоды старта из ключа файла.
func _scenarios(fi: int, lid: String, site: String, h: Dictionary, mh: String) -> Array:
	var key: Dictionary = h.key
	var w: Dictionary = key.weather
	var start := Vector3(float(key.start[0]), 0.0, float(key.start[1]))
	var base_cond := AirBakedField.conditions_of(w)
	var base := {
		lid = lid, site = site, center_lat = float(key.center[0]), center_lon = float(key.center[1]),
		start = [start.x, start.z], weather = w, month = int(w.month), day = int(w.day),
		window_dx = key.window_dx, cond = base_cond, site_query = site, focus_dx = 0.0,
		model_mutated = "",
	}
	var out: Array = []
	var defs: Array = [
		{name = "ok"},
		{name = "wind_close", cond = {u10 = base_cond.u10 + 0.04}},
		{name = "wind_far", cond = {u10 = base_cond.u10 + 0.2}},
		{name = "dir_close", cond = {wdir = fposmod(base_cond.wdir + 0.8, 360.0)}},
		{name = "dir_far", cond = {wdir = fposmod(base_cond.wdir + 2.0, 360.0)}},
		{name = "dir_wrap", cond = {wdir = fposmod(base_cond.wdir + 359.5, 360.0)}},
		{name = "hour", cond = {hour = base_cond.hour + 0.1}},
		{name = "tmax", cond = {t_max = base_cond.t_max + 1.0}},
		{name = "sky", cond = {sky = "clear" if base_cond.sky != "clear" else "overcast"}},
		{name = "wind_ref", cond = {wind_ref = "start" if base_cond.wind_ref != "start" else "inflow"}},
		{name = "date", day = int(w.day) + 1},
		{name = "no_site", site_query = "no_such_site"},
		{name = "no_weather", weather = {}, site_query = "no_such_site"},
		{name = "center", center_lat = float(key.center[0]) + 0.001},
		{name = "start_shift", start = [start.x + 0.5, start.z]},
		{name = "model", model_mutated = "deadbeef00000000"},
	]
	for d: Dictionary in defs:
		var sc := base.duplicate(true)
		for k: String in d:
			if k == "cond":
				for ck: String in d.cond:
					sc.cond[ck] = d.cond[ck]
			elif k != "name":
				sc[k] = d[k]
		sc.name = "%s/%s" % [site, d.name]
		sc.file = fi
		var res := _lookup(sc, h)
		sc.model_hash_now = mh
		sc.data_hash = AirBakedField.place_hash(Locations.data_dir(lid))
		sc.reason = res.reason
		sc.warn = res.warn
		sc.path = res.path
		sc.expect_ok = res.reason == ""
		out.append(sc)
	return out


## AirRuntime.baked_lookup по сценарию sc. model_mutated — копия заголовка с другим model_hash во
## временном корне (baked_root).
func _lookup(sc: Dictionary, h: Dictionary) -> Dictionary:
	var rt := AirRuntime.new()
	var pos := Vector3(float(sc.start[0]), 0.0, float(sc.start[1]))
	var focus := Vector3(float(h.key.start[0]), 0.0, float(h.key.start[1]))
	var weather: Dictionary = sc.weather
	rt._place = {
		loc = {id = sc.lid, center_lat = sc.center_lat, center_lon = sc.center_lon, month = sc.month, day = sc.day},
		start_sites = [{id = sc.site_query, position = pos, weather = weather}],
	}
	rt._cfg = {window_levels_m = sc.window_dx}
	rt._focus_start = focus
	var saved_root := AirBakedField.baked_root
	if sc.model_mutated != "":
		var root := TMP_ROOT
		var dir := root.path_join(sc.lid).path_join("air")
		DirAccess.make_dir_recursive_absolute(dir)
		var hh := h.duplicate(true)
		hh.model_hash = sc.model_mutated
		var fa := FileAccess.open(dir.path_join(sc.site + ".json"), FileAccess.WRITE)
		fa.store_string(JSON.stringify(hh, "\t", true))
		fa.close()
		AirBakedField.baked_root = root
	var c: Dictionary = (sc.cond as Dictionary).duplicate()
	var r := rt.baked_lookup(c)
	AirBakedField.baked_root = saved_root
	rt.free()
	var path := String(r.path)
	if sc.model_mutated != "":
		path = path.replace(TMP_ROOT, ROOT)
	return {reason = String(r.reason), warn = bool(r.warn), path = path}


func _add(name: String, a: PackedFloat32Array) -> void:
	_arrays[name] = [_blob.size(), a.size()]
	_blob.append_array(a)


## Запись через временные файлы и переименование (json — последним).
func _write(out: String, doc: Dictionary) -> bool:
	var bin := out + "/baked.bin"
	var js := out + "/baked.json"
	var f := FileAccess.open(bin + ".tmp", FileAccess.WRITE)
	if f == null:
		return false
	f.store_buffer(_blob.to_byte_array())
	f.close()
	var j := FileAccess.open(js + ".tmp", FileAccess.WRITE)
	if j == null:
		return false
	j.store_string(JSON.stringify(doc, "\t", true))
	j.close()
	DirAccess.rename_absolute(bin + ".tmp", bin)
	DirAccess.rename_absolute(js + ".tmp", js)
	return true
