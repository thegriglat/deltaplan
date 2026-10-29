extends "res://tools/wind_fixtures/gen_fixtures.gd"
## RW-10d: дамп AirThermals.build на опорной ревизии c591b1026 (GPU, окно).
## Запуск (копия на c591b1026): tools/wind_fixtures/dump_air_thermals.tscn -- --out=<каталог> [--only=имя,имя]
## На случай <имя> (ongudai_medium | ongudai_strong | ongudai_wave) пишет в <out>/<имя>/:
##   field.json + field.bin — GPU-поле, на котором строились источники (AirBakedField.save, lossless: f32);
##   ref.json + ref.bin — вход (thermal-конфиг, сид, кромка, доля жизни, u10, edge_cells), результат build
##     (массивы источников и столбцов), таблицы вызовов (sun/is_water при pick_in_column по этим
##     столбцам; is_water при land_fraction) и результат pick_in_column по выбранным и каждому седьмому столбцу.
## ref.bin — zstd от склейки массивов little-endian; ref.json["arrays"][имя] = [смещение, число, "f32"|"f64"|"i32"|"u8"].

const CASES_DUMP := ["ongudai_medium", "ongudai_strong", "ongudai_wave"]


## Вызовы sun_fn/is_water при pick_in_column: [x, z, s_сырое, вода(-1 не спрашивали, 0, 1)] подряд.
class RecGround:
	extends GroundField
	var real: GroundField
	var log := PackedFloat64Array()

	func _sun(x: float, z: float) -> float:
		var s := float(real.sun_fn.call(x, z)) if real.sun_fn.is_valid() else 1.0
		log.append_array(PackedFloat64Array([x, z, s, -1.0]))
		return s

	func is_water(x: float, z: float) -> bool:
		var w := real.is_water(x, z)
		log[log.size() - 1] = 1.0 if w else 0.0
		return w


## Вызовы water_fn при land_fraction: [x, z, вода] подряд.
class RecWater:
	extends RefCounted
	var real: GroundField
	var log := PackedFloat64Array()

	func call_water(x: float, z: float) -> bool:
		var w := real.is_water(x, z)
		log.append_array(PackedFloat64Array([x, z, 1.0 if w else 0.0]))
		return w


var _body := PackedByteArray()
var _arrays := {}


func _ready() -> void:
	var out_dir := ""
	var only: PackedStringArray = []
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out_dir = a.substr(6)
		elif a.begins_with("--only="):
			only = a.substr(7).split(",")
	if out_dir == "":
		push_error("dump_air_thermals: нужен --out=<каталог>")
		get_tree().quit(2)
		return
	Locations.fixtures_root = "res://tests/fixtures/locations"
	await get_tree().process_frame
	var ok := true
	for c in CASES:
		if not CASES_DUMP.has(String(c.name)) or (not only.is_empty() and not only.has(String(c.name))):
			continue
		ok = await _dump_case(c, out_dir.path_join(String(c.name)))
		if not ok:
			break
	get_tree().quit(0 if ok else 1)


func _add(name: String, v: Variant, kind: String) -> void:
	var raw: PackedByteArray
	var n: int
	match kind:
		"f32":
			var a := PackedFloat32Array(v)
			raw = a.to_byte_array()
			n = a.size()
		"f64":
			var a := PackedFloat64Array(v)
			raw = a.to_byte_array()
			n = a.size()
		"i32":
			var a := PackedInt32Array(v)
			raw = a.to_byte_array()
			n = a.size()
		_:
			var a := PackedByteArray(v)
			raw = a
			n = a.size()
	_arrays[name] = [_body.size(), n, kind]
	_body.append_array(raw)


func _vec2s(a: PackedVector2Array) -> PackedFloat32Array:
	var o := PackedFloat32Array()
	for v in a:
		o.append(v.x)
		o.append(v.y)
	return o


func _dump_case(c: Dictionary, dir: String) -> bool:
	DirAccess.make_dir_recursive_absolute(dir)
	var ctx := await _ongudai_ctx()
	if ctx.is_empty():
		return false
	var weather := _weather_of(c)
	var levels: Array = await _solve_field(c, ctx, weather)
	if levels.is_empty():
		push_error("dump_air_thermals: %s — поле не посчитано" % c.name)
		return false
	var a := _make_atmo(c, ctx, weather)
	a.set_air_field(levels, 0.0)
	a.start_at(0.0)
	var th: ThermalField = a.field
	var src0 := th.air_src
	if src0 == null:
		push_error("dump_air_thermals: %s — источников из поля нет" % c.name)
		return false
	var f0 := src0.level
	var cb: float = float(th._air_src_inputs[0])
	var duty: float = float(th._air_src_inputs[1])
	# Поле сохраняется как запечённое TI-К3 (f16): влезает в бюджет данных, и источники ниже строятся
	# по ЭТОМУ полю (перечитанному), а не по GPU-полю — тест крейта читает ровно его.
	var fs := AirFieldSet.new()
	fs.levels.append(f0)
	fs.edge_cells = a.air_field.edge_cells
	var hdr := {location = "ongudai", site = "dump", key = {}, model_hash = ""}
	# без потерь (f32) — только размер, в отчёт
	var tmp := "user://rw10d_lossless_%s.json" % c.name
	AirBakedField.save(fs, hdr, tmp, true)
	var lossless_bytes := FileAccess.get_file_as_bytes(ProjectSettings.globalize_path(tmp).trim_suffix(".json") + ".bin").size()
	if not AirBakedField.save(fs, hdr, dir.path_join("field.json"), false):
		push_error("dump_air_thermals: поле не записано")
		return false
	var fs2 := AirBakedField.load_file(dir.path_join("field.json"))
	if fs2 == null or fs2.levels.is_empty():
		push_error("dump_air_thermals: записанное поле не читается")
		return false
	var f := fs2.levels[0]
	f.edge_cells = fs.edge_cells
	var cfg_b: Dictionary = th._cfg.duplicate()
	cfg_b["duty"] = duty
	cfg_b["cloudbase_msl"] = cb
	cfg_b["height_fn"] = th.ground.height
	cfg_b["pick_fn"] = AirThermals.pick_in_column.bind(f, th.ground, th._seed, int(th._cfg.source_candidates))
	cfg_b["water_fn"] = th.ground.is_water
	cfg_b["land"] = PackedFloat32Array()
	var src := AirThermals.new()
	src.bands = 1
	if not src.build(f, cfg_b):
		push_error("dump_air_thermals: %s — сборка по перечитанному полю не удалась" % c.name)
		return false
	print("dump_air_thermals: %s — по GPU-полю источников %d, по f16-полю %d; поле без потерь %d байт" % [c.name, src0.count(), src.count(), lossless_bytes])
	_body = PackedByteArray()
	_arrays = {}
	var n_col := f.nx * f.ny
	# результат build
	_add("col", src.col, "i32")
	_add("pos", _vec3s(src.pos), "f32")
	for nm in ["w0", "radius", "wstar", "top", "flux", "carried", "net", "ring", "area", "depth"]:
		_add(nm, src.get(nm), "f32")
	_add("drift", _vec2s(src.drift), "f32")
	_add("owner", src.owner, "i32")
	for nm in ["phi", "col_heat", "col_w", "col_f", "c_top", "col_wstar", "col_wm", "col_zi", "col_sub", "land"]:
		_add(nm, src.get(nm), "f32")
	# pick_in_column: выбранные столбцы и каждый седьмой — с журналом вызовов
	var rec := RecGround.new()
	rec.real = th.ground
	rec.has_ground = true
	rec.sun_fn = Callable(rec, "_sun")
	var cands := int(th._cfg.source_candidates)
	var want := PackedByteArray()
	want.resize(n_col)
	for cc in src.col:
		want[cc] = 1
	var pcols := PackedInt32Array()
	var picks := PackedFloat32Array()
	for cc in n_col:
		if want[cc] == 0 and cc % 7 != 0:
			continue
		var p := AirThermals.pick_in_column(cc % f.nx, cc / f.nx, f, rec, th._seed, cands)
		pcols.append(cc)
		picks.append(p.x)
		picks.append(p.y)
	_add("pick_cols", pcols, "i32")
	_add("pick_xz", picks, "f32")
	var lx := PackedFloat32Array()
	var lz := PackedFloat32Array()
	var ls := PackedFloat64Array()
	var lw := PackedByteArray()
	for q in range(0, rec.log.size(), 4):
		lx.append(rec.log[q])
		lz.append(rec.log[q + 1])
		ls.append(rec.log[q + 2])
		lw.append(2 if rec.log[q + 3] < 0.0 else int(rec.log[q + 3]))
	_add("pl_x", lx, "f32")
	_add("pl_z", lz, "f32")
	_add("pl_s", ls, "f64")
	_add("pl_w", lw, "u8")
	var chk := 0
	for s in src.col.size():
		var k := pcols.find(src.col[s])
		if k < 0 or picks[2 * k] != src.pos[s].x or picks[2 * k + 1] != src.pos[s].z:
			chk += 1
	if chk > 0:
		push_error("dump_air_thermals: %s — %d точек источников не совпали с pick_in_column" % [c.name, chk])
		return false
	# land_fraction с журналом вызовов
	var rw := RecWater.new()
	rw.real = th.ground
	var land := AirThermals.land_fraction(f, Callable(rw, "call_water"))
	if src.land.size() == n_col and land != src.land:
		push_error("dump_air_thermals: %s — land_fraction не совпала с land сборки" % c.name)
		return false
	var wx := PackedFloat32Array()
	var wz := PackedFloat32Array()
	var ww := PackedByteArray()
	for q in range(0, rw.log.size(), 3):
		wx.append(rw.log[q])
		wz.append(rw.log[q + 1])
		ww.append(int(rw.log[q + 2]))
	_add("wl_x", wx, "f32")
	_add("wl_z", wz, "f32")
	_add("wl_w", ww, "u8")
	var cfg: Dictionary = th._cfg.duplicate(true)
	for k in cfg.keys():
		if cfg[k] is Callable:
			cfg.erase(k)
	var ref := {
		case = String(c.name),
		generator = _git_rev,
		seed = th._seed,
		source_candidates = cands,
		thermal_cfg = cfg,
		cloudbase_msl = cb,
		duty = duty,
		lossless_field_bytes = lossless_bytes,
		sources_gpu_field = src0.count(),
		u10 = f.u10(),
		edge_cells = f.edge_cells,
		nx = f.nx, ny = f.ny, nz = f.nz,
		scalars = {
			shape_area = src.shape_area, life_mean = src.life_mean, alive_frac = src.alive_frac,
			phi_ref = src.phi_ref, lost_flux = src.lost_flux, total_flux = src.total_flux,
			carried_flux = src.carried_flux,
		},
		count = src.count(),
		arrays = _arrays,
		raw_bytes = _body.size(),
	}
	var f_bin := FileAccess.open(dir.path_join("ref.bin"), FileAccess.WRITE)
	f_bin.store_buffer(_body.compress(FileAccess.COMPRESSION_ZSTD))
	f_bin.close()
	var f_js := FileAccess.open(dir.path_join("ref.json"), FileAccess.WRITE)
	f_js.store_string(JSON.stringify(ref) + "\n")
	f_js.close()
	print("dump_air_thermals: %s — источников %d, столбцов %d, ref.bin %d байт" % [c.name, src.count(), n_col, _body.size()])
	a.free()
	return true


func _vec3s(a: PackedVector3Array) -> PackedFloat32Array:
	var o := PackedFloat32Array()
	for v in a:
		o.append(v.x)
		o.append(v.y)
		o.append(v.z)
	return o
