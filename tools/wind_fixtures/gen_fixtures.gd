extends Node
## Генератор эталонов ветра (rust-wind, RW-1, W8): снимает на ТЕКУЩЕМ коде атмосферы фикстуры
## tests/fixtures/wind/ — места (places/), случаи (cases/: итог FULL/MEAN, σ, описания W6).
## Код атмосферы не меняет: читает внутренности (field, storm, wave, cloud_phys) только здесь.
##
## Запуск (случаи с полем Пикара — на GPU, окно; синтетика без поля идёт и headless):
##   tools/wind_fixtures/run.sh [--out=<каталог>] [--only=имя,имя] [--synthetic]
##   (вручную: godot --path . res://tools/wind_fixtures/gen_fixtures.tscn -- --out=<каталог>)
## Формат и допуски — docs/contracts/rust-wind/fixtures-tolerances.md (W8); поля места — W5,
## описания — W6, оси и единицы — W1. Что в наборе и как воспроизвести — tests/fixtures/wind/README.md.

const FORMAT_VERSION := 1
## Моменты снимка, с: старт, +15 мин, +60 мин. Каждый — отдельная атмосфера со start_at(t)
## (W2: состояние на t = прогон с 0), поэтому момент не зависит от порядка и истории.
const TIMES: Array[float] = [0.0, 900.0, 3600.0]
const TAGS: Array[String] = [
	"ground", "lee", "thermal", "field_edge", "above_base", "storm", "wave", "far"
]
## Стоит ли поле Пикара (GPU) — иначе аналитика (air_model.enabled = off).
const MONTH := 7
const DAY := 15

## Шаг описаний W6.
const CORE_STRIDE := 15
const CLOUD_STRIDE := 10
const CREST_STRIDE := 4

## Синтетический мир (AtmoFingerprint.height/source_static): сетка 25 м вокруг центра отпечатка.
const SYN_ORIGIN_X := -8500.0
const SYN_ORIGIN_Z := -12500.0
const SYN_N := 801
const SYN_H_SCALE := 0.05

## Описание случая. name — имя файлов; place — "synthetic" | "ongudai"; preset — configs/weather/*;
## wind_kmh/from_deg — поверх пресета (0 — как в пресете); seed; statics — статичные термики.
var CASES: Array[Dictionary] = [
	{name = "synth_weak", place = "synthetic", preset = "weak", wind_kmh = 7.0, from_deg = 250.0,
		seed = 101, statics = [[-4000.0, 3000.0, 2.5, 120.0]]},
	{name = "synth_medium", place = "synthetic", preset = "medium", wind_kmh = 14.0,
		from_deg = 230.0, seed = 4242, statics = [[-4000.0, 3000.0, 2.5, 120.0]]},
	{name = "synth_strong", place = "synthetic", preset = "strong", wind_kmh = 32.0,
		from_deg = 300.0, seed = 303, statics = []},
	{name = "synth_storm", place = "synthetic", preset = "storm", wind_kmh = 14.0,
		from_deg = 270.0, seed = 404, statics = []},
	{name = "synth_wave", place = "synthetic", preset = "wave", wind_kmh = 36.0,
		from_deg = 270.0, seed = 505, statics = []},
	{name = "ongudai_medium", place = "ongudai", preset = "medium", wind_kmh = 11.0,
		from_deg = 151.0, seed = 606, statics = []},
	{name = "ongudai_strong", place = "ongudai", preset = "strong", wind_kmh = 27.0,
		from_deg = 151.0, seed = 707, statics = []},
	{name = "ongudai_wave", place = "ongudai", preset = "wave", wind_kmh = 36.0,
		from_deg = 151.0, seed = 808, statics = []},
]

var _out := ""
var _only: PackedStringArray = []
var _synthetic_only := false
var _git_rev := "unknown"
var _tags_seen: Dictionary = {}
var _terrain: Terrain
var _ongudai: Dictionary = {}


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.substr(6)
		elif a.begins_with("--only="):
			_only = a.substr(7).split(",")
		elif a == "--synthetic":
			_synthetic_only = true
	if _out == "":
		_out = ProjectSettings.globalize_path("res://tests/fixtures/wind")
	Locations.fixtures_root = "res://tests/fixtures/locations"
	var rev: Array = []
	if OS.execute("git", ["-C", ProjectSettings.globalize_path("res://"), "rev-parse", "--short", "HEAD"], rev) == 0:
		_git_rev = String(rev[0]).strip_edges()
	await get_tree().process_frame
	var ok := await _run()
	get_tree().quit(0 if ok else 1)


func _run() -> bool:
	DirAccess.make_dir_recursive_absolute(_out.path_join("places"))
	DirAccess.make_dir_recursive_absolute(_out.path_join("cases"))
	var gpu := DisplayServer.get_name() != "headless"
	var places_done := {}
	for c in CASES:
		if not _only.is_empty() and not _only.has(String(c.name)):
			continue
		if String(c.place) == "ongudai" and (_synthetic_only or not gpu):
			print("gen_fixtures: пропуск %s (нужно окно с GPU)" % c.name)
			continue
		var t0 := Time.get_ticks_msec()
		var ctx: Dictionary
		if String(c.place) == "synthetic":
			ctx = _synthetic_ctx()
		else:
			ctx = await _ongudai_ctx()
			if ctx.is_empty():
				return false
		if not places_done.has(c.place):
			places_done[c.place] = true
			_write_place(String(c.place), ctx.place_data)
		if not await _run_case(c, ctx):
			return false
		print("gen_fixtures: %s готов за %.1f с" % [c.name, (Time.get_ticks_msec() - t0) / 1000.0])
	var missing: Array[String] = []
	for tag in TAGS:
		if not _tags_seen.has(tag):
			missing.append(tag)
	if _only.is_empty() and not _synthetic_only and not missing.is_empty():
		push_error("gen_fixtures: нет точек с метками %s" % str(missing))
		return false
	print("gen_fixtures: метки %s; пропущены %s" % [str(_tags_seen.keys()), str(missing)])
	return true


# ================================================================ места


func _synthetic_ctx() -> Dictionary:
	var n := SYN_N * SYN_N
	var heights := PackedFloat32Array()
	heights.resize(n)
	var moist := PackedFloat32Array()
	moist.resize(n)
	for j in SYN_N:
		for i in SYN_N:
			var x := SYN_ORIGIN_X + 25.0 * i
			var z := SYN_ORIGIN_Z + 25.0 * j
			heights[j * SYN_N + i] = AtmoFingerprint.height(x, z)
			moist[j * SYN_N + i] = clampf(AtmoFingerprint._surface_k(x, z), 0.0, 1.0)
	var water := PackedByteArray()
	water.resize(n)
	var cls := PackedByteArray()
	cls.resize(n)
	cls.fill(SurfaceLayer.GRASS)
	var centre := AtmoFingerprint.CENTER
	var pd := {
		loc = {
			id = "synthetic", center_lat = 51.5, center_lon = 86.5, utc_offset_h = 6.0,
			month = MONTH, day = DAY,
		},
		grid = {origin_x = SYN_ORIGIN_X, origin_z = SYN_ORIGIN_Z, spacing = 25.0, width = SYN_N, height = SYN_N},
		start_sites = [{x = centre.x, z = centre.z, h_msl = AtmoFingerprint.height(centre.x, centre.z)}],
		heights = heights, water = water, cls = cls, moist = moist, h_scale = SYN_H_SCALE,
		note = "аналитический мир atmo_fingerprint.gd: heights = AtmoFingerprint.height, moist = _surface_k (множитель поверхности источников, 0,3..1), cls = луг; сила источников в генераторе — AtmoFingerprint.source_static (по нормали и _surface_k)",
	}
	return {
		kind = "synthetic",
		place_data = pd,
		height_fn = AtmoFingerprint.height,
		sun_fn = AtmoFingerprint.source_static,
		surface_fn = Callable(),
		focus = Vector3(centre.x, AtmoFingerprint.height(centre.x, centre.z), centre.z),
		ref_msl = AtmoFingerprint.height(0.0, 0.0),
		desc_radius = 8000.0,
		far_m = 8500.0,
		field = false,
		overrides = {
			"atmosphere.air_model.enabled": "off",
			"atmosphere.thermal.generation_radius_m": 8000.0,
		},
	}


func _ongudai_ctx() -> Dictionary:
	if not _ongudai.is_empty():
		return _ongudai
	_terrain = Terrain.new()
	add_child(_terrain)
	if not _terrain.load_location("ongudai"):
		push_error("gen_fixtures: Онгудай не загрузился")
		return {}
	_terrain.wait_relief()
	var lc: Dictionary = Config.get_config("locations/ongudai")
	var site: Dictionary = lc.start_sites[0]
	var s2 := _terrain.latlon_to_local(float(site.lat), float(site.lon))
	var sh := _terrain.height_at(s2.x, s2.y)
	var utc := float(lc.get("utc_offset_h", NAN))
	var place := AirRuntime.place_of(_terrain, utc, MONTH, DAY)
	(place.surface as AirPlace.Surface).wait()
	var detail: HeightLayer = place.detail
	var sf: AirPlace.Surface = place.surface
	if (
		sf.width != detail.width or sf.height != detail.height
		or sf.origin_x != detail.origin_x or sf.origin_z != detail.origin_z
	):
		push_error("gen_fixtures: сетка поверхности не совпала со слоем detail")
		return {}
	var n := detail.width * detail.height
	var water := _water_nodes(place.water, detail)
	var moist := sf.moist
	var cls := sf.cls
	if water.size() != n or cls.size() != n or moist.size() != n:
		push_error("gen_fixtures: длины растров места (%d, %d, %d) ≠ %d" % [water.size(), cls.size(), moist.size(), n])
		return {}
	var sites: Array = []
	for st: Dictionary in place.start_sites:
		var p: Vector3 = st.position
		sites.append({id = String(st.id), x = p.x, z = p.z, h_msl = p.y})
	var loc: Dictionary = (place.loc as Dictionary).duplicate()
	loc.month = MONTH
	loc.day = DAY
	var pd := {
		loc = loc,
		grid = {origin_x = detail.origin_x, origin_z = detail.origin_z, spacing = detail.spacing, width = detail.width, height = detail.height},
		start_sites = sites,
		heights = detail.heights, water = water, cls = cls, moist = moist, h_scale = 0.03125,
		note = "Онгудай (tests/fixtures/locations/ongudai): слой detail 25 м, AirRuntime.place_of; water — узел по ближайшему пикселю маски (> 127), cls/moist — снимок поверхности AirPlace.Surface",
	}
	_ongudai = {
		kind = "ongudai",
		place_data = pd,
		place = place,
		height_fn = _terrain.height_at,
		sun_fn = _terrain.thermal_source_strength_at,
		surface_fn = _terrain.surface_at,
		focus = Vector3(s2.x, sh, s2.y),
		ref_msl = sh,
		desc_radius = 6000.0,
		far_m = 14000.0,
		field = true,
		overrides = {
			"air_runtime": "без focus_fn (окон 100/50 м нет), один проход, без кеша и запечённого поля",
		},
		utc = utc,
	}
	return _ongudai


## Вода по узлам слоя: ближайший к узлу пиксель маски (как AirPlace.water_fraction при f = 1).
func _water_nodes(img: Image, layer: HeightLayer) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(layer.width * layer.height)
	if img == null:
		return out
	if img.is_compressed() or img.get_format() != Image.FORMAT_L8:
		img = img.duplicate()
		if img.is_compressed():
			img.decompress()
		img.convert(Image.FORMAT_L8)
	var px := img.get_data()
	var iw := img.get_width()
	var ih := img.get_height()
	for j in layer.height:
		var row := (ih - 1 - int((layer.height - 1 - j) * ih / layer.height)) * iw
		for i in layer.width:
			var col := int(i * iw / layer.width)
			out[j * layer.width + i] = 1 if px[row + col] > 127 else 0
	return out


func _write_place(name: String, pd: Dictionary) -> void:
	var heights: PackedFloat32Array = pd.heights
	var n := heights.size()
	var lo := INF
	var hi := -INF
	for h in heights:
		lo = minf(lo, h)
		hi = maxf(hi, h)
	var scale: float = pd.h_scale
	var offset := snappedf(0.5 * (lo + hi), scale)
	var buf := PackedByteArray()
	buf.resize(n * 5)
	var maxerr := 0.0
	for k in n:
		var v := roundi((heights[k] - offset) / scale)
		if v < -32768 or v > 32767:
			push_error("gen_fixtures: высота %f не влезает в int16 при шаге %f" % [heights[k], scale])
			return
		buf.encode_s16(2 * k, v)
		maxerr = maxf(maxerr, absf(offset + v * scale - heights[k]))
	var water: PackedByteArray = pd.water
	var cls: PackedByteArray = pd.cls
	var moist: PackedFloat32Array = pd.moist
	var o := 2 * n
	for k in n:
		buf[o + k] = water[k]
		buf[o + n + k] = cls[k]
		buf[o + 2 * n + k] = clampi(roundi(moist[k] * 255.0), 0, 255)
	var classes := {}
	for i in SurfaceLayer.CLASS_NAMES.size():
		classes[SurfaceLayer.CLASS_NAMES[i]] = i
	var header := {
		version = FORMAT_VERSION,
		name = name,
		loc = pd.loc,
		grid = pd.grid,
		surface_classes = classes,
		start_sites = pd.start_sites,
		h_offset = offset,
		h_scale = scale,
		bin = {
			layout = "heights int16 LE, water u8, cls u8, moist u8 (x 1/255); подряд, width*height узлов, строка j к +Z (W1)",
			h_max_err_m = maxerr,
			bytes = buf.size(),
		},
		note = pd.note,
	}
	_write_text(_out.path_join("places/%s.json" % name), JSON.stringify(header, "\t") + "\n")
	_write_bytes(_out.path_join("places/%s.bin" % name), buf)


# ================================================================ случай


func _weather_of(c: Dictionary) -> Dictionary:
	var w: Dictionary = Config.get_config("weather/" + String(c.preset)).duplicate(true)
	w.erase("static_thermals")
	w.static_thermals = []
	if float(c.wind_kmh) > 0.0:
		w.wind_speed_kmh = float(c.wind_kmh)
	if float(c.from_deg) >= 0.0:
		w.wind_from_deg = float(c.from_deg)
	return w


func _make_atmo(c: Dictionary, ctx: Dictionary, weather: Dictionary) -> Atmosphere:
	var cfg: Dictionary = Config.get_config("atmosphere").duplicate(true)
	if not bool(ctx.field):
		cfg.air_model.enabled = "off"
		cfg.thermal.generation_radius_m = 8000.0
	var w := weather.duplicate(true)
	w.static_thermals = []
	for s: Array in c.statics:
		w.static_thermals.append({x_m = s[0], z_m = s[1], strength_ms = s[2], radius_m = s[3]})
	var a := Atmosphere.new()
	a.visuals_enabled = false
	a.seed_value = int(c.seed)
	a.configure(cfg, w)
	a.cloud_phys.deterministic = true
	a.cloud_phys.async_field = false
	a.set_ground(ctx.height_fn, ctx.sun_fn, ctx.surface_fn)
	a.set_wind(float(w.wind_speed_kmh), float(w.wind_from_deg), float(ctx.ref_msl))
	a.set_focus(ctx.focus)
	return a


func _run_case(c: Dictionary, ctx: Dictionary) -> bool:
	var weather := _weather_of(c)
	var levels: Array = []
	if bool(ctx.field):
		levels = await _solve_field(c, ctx, weather)
		if levels.is_empty():
			push_error("gen_fixtures: %s — поле не посчитано" % c.name)
			return false
	var atmos: Array[Atmosphere] = []
	for t in TIMES:
		var a := _make_atmo(c, ctx, weather)
		if not levels.is_empty():
			a.set_air_field(levels, 0.0)
		a.start_at(t)
		atmos.append(a)
	if bool(ctx.field) and not atmos[0].is_air_field_on():
		push_error("gen_fixtures: %s — поле не включилось" % c.name)
		return false
	# точки: по состоянию каждого момента
	var pts: Array[Vector3] = []
	var tags: Array[String] = []
	_pick_points(c, ctx, atmos, pts, tags)
	for tag in tags:
		_tags_seen[tag] = true
	# выборка
	var n := pts.size()
	var data := PackedFloat32Array()
	data.resize(TIMES.size() * n * 2 * 4)
	var descs: Array = []
	for k in TIMES.size():
		var a := atmos[k]
		for i in n:
			var r := _sample_both(a, pts[i])
			var o := ((k * n + i) * 2) * 4
			for m in 8:
				data[o + m] = r[m]
		descs.append(_describe(a, ctx, TIMES[k]))
	var focus: Vector3 = ctx.focus
	var tmp_cfg := {
		version = FORMAT_VERSION,
		place = String(c.place),
		conditions = {
			preset = weather, start_hour = 12.0, speed = 1.0, blend_s = null, rebuild = false,
		},
		seed = int(c.seed),
		static_thermals = c.statics,
		configs_sha1 = _config_hashes(String(c.preset)),
		times_s = TIMES,
		focuses = [[focus.x, focus.y, focus.z, 1.0]],
		points = _pts_json(pts),
		point_tags = tags,
		terms = null,
		generator = _git_rev,
		extra = {
			sample_recipe = "FULL: v = air_velocity_at(p), σ = _last_sigma (turbulence_enabled = true). MEAN: v = air_velocity_at(p) при turbulence_enabled = false (без шума порывов и бурления в облаке; поле, аналитика, термики, гроза, волна, ротор — в среднем); σ в MEAN — та же, что в FULL",
			moments = "каждый момент — новая атмосфера со start_at(t) (поле Пикара посчитано один раз при t = 0 для конфигурации и общее для моментов; пересчёта поля на +15 мин нет)",
			desc_center = [focus.x, focus.z],
			desc_radius = ctx.desc_radius,
			field = ctx.field,
			field_conditions = {u10 = float(weather.wind_speed_kmh) / 3.6, wdir = float(weather.wind_from_deg), hour = 12.0, t_max = 26.0, sky = "clear"},
			wind_ref_msl = ctx.ref_msl,
			config_overrides = ctx.overrides,
			hour_note = "AtmoDay не используется (эталон-пресет W5): ход дня и солнце — из пресета и clouds.sun_* конфига",
		},
	}
	_write_text(_out.path_join("cases/%s.json" % c.name), JSON.stringify(tmp_cfg) + "\n")
	_write_bytes(_out.path_join("cases/%s.bin" % c.name), data.to_byte_array())
	_write_text(
		_out.path_join("cases/%s.desc.json" % c.name),
		JSON.stringify({
			version = FORMAT_VERSION, core_stride = CORE_STRIDE, cloud_stride = CLOUD_STRIDE,
			crest_stride = CREST_STRIDE, frames = descs,
		}) + "\n"
	)
	for a in atmos:
		a.free()
	return true


func _config_hashes(preset: String) -> Dictionary:
	var out := {}
	for n in ["atmosphere", "weather_model", "surface_heat", "weather/" + preset]:
		out[n] = _sha1("res://configs/%s.json" % n)
	return out


func _sha1(path: String) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA1)
	ctx.update(FileAccess.get_file_as_bytes(path))
	return ctx.finish().hex_encode()


func _pts_json(pts: Array[Vector3]) -> Array:
	var out: Array = []
	for p in pts:
		out.append([p.x, p.y, p.z])
	return out


## Поле Пикара для условий случая (GPU): один раз на случай; уровни общие для моментов.
func _solve_field(c: Dictionary, ctx: Dictionary, weather: Dictionary) -> Array:
	var cond := {
		hour = 12.0, u10 = float(weather.wind_speed_kmh) / 3.6,
		wdir = float(weather.wind_from_deg), t_max = 26.0, sky = "clear",
	}
	var a := _make_atmo(c, ctx, weather)
	var rt := AirRuntime.new()
	rt.baked_enabled = false
	rt.cache_enabled = false
	add_child(rt)
	await get_tree().process_frame
	rt.setup(a, ctx.place, func() -> Dictionary: return cond)
	var why := rt.unavailable_reason()
	if why != "":
		push_error("gen_fixtures: поле недоступно: %s" % why)
		rt.queue_free()
		a.free()
		return []
	var ok: bool = await rt.load_field()
	var out: Array = []
	if ok:
		for f in a.air_field.levels:
			out.append(f)
	print("gen_fixtures: %s — поле %s, уровней %d, %s" % [c.name, "есть" if ok else "НЕТ", out.size(), str(rt.last_info.get("wall_s", "?"))])
	rt.stop()
	rt.queue_free()
	await get_tree().process_frame
	a.free()
	return out


# ================================================================ выборка


func _sample_both(a: Atmosphere, p: Vector3) -> Array:
	a.turbulence_enabled = true
	var v := a.air_velocity_at(p)
	var sig := a._last_sigma
	# MEAN — тот же воздух без неразрешённой болтанки и порывов (turbulence_enabled = false):
	# mean_wind_at + вертикаль из debug_overlays.mean_air_at с полем даёт вертикаль только поля
	# (без термиков, грозы, волны) и горизонталь без подветренной зоны и грозы — это не «итог без шума».
	a.turbulence_enabled = false
	var m := a.air_velocity_at(p)
	a.turbulence_enabled = true
	return [v.x, v.y, v.z, sig, m.x, m.y, m.z, sig]


func _pick_points(
	c: Dictionary, ctx: Dictionary, atmos: Array[Atmosphere], pts: Array[Vector3], tags: Array[String]
) -> void:
	var f: Vector3 = ctx.focus
	var hf: Callable = ctx.height_fn
	var a0 := atmos[0]
	var add := func(x: float, agl: float, z: float, tag: String) -> void:
		pts.append(Vector3(x, float(hf.call(x, z)) + agl, z))
		tags.append(tag)
	var addy := func(x: float, y: float, z: float, tag: String) -> void:
		pts.append(Vector3(x, y, z))
		tags.append(tag)
	# у земли: пять мест вокруг фокуса, 3 м и 30 м над землёй
	for s in AtmoFingerprint.SPOTS:
		add.call(f.x + s.x, 3.0, f.z + s.y, "ground")
		add.call(f.x + s.x, 30.0, f.z + s.y, "ground")
	# подветренная зона: максимум глубины тени × рельеф в ±4 км, две точки через ≥ 1 км
	var lee_best: Array = []
	var step := 200.0
	var lee_max := -1.0e9
	var relief_max := 0.0
	for gj in range(-20, 21):
		for gi in range(-20, 21):
			var x := f.x + gi * step
			var z := f.z + gj * step
			var gs := a0.ground.sample(x, z)
			var depth := gs.w - gs.x
			var relief := a0.ground.relief_at(x, z)
			lee_max = maxf(lee_max, depth)
			relief_max = maxf(relief_max, relief)
			if depth > 40.0 and relief > 60.0:
				lee_best.append([depth * relief, x, z])
	print("gen_fixtures: %s — лучшая тень %.1f м, рельеф %.1f м, кандидатов %d" % [c.name, lee_max, relief_max, lee_best.size()])
	lee_best.sort_custom(func(p: Array, q: Array) -> bool: return p[0] > q[0])
	var taken: Array[Vector2] = []
	for e: Array in lee_best:
		var pe := Vector2(e[1], e[2])
		var far_enough := true
		for q in taken:
			if q.distance_to(pe) < 1000.0:
				far_enough = false
		if not far_enough:
			continue
		taken.append(pe)
		add.call(pe.x, 20.0, pe.y, "lee")
		add.call(pe.x, 100.0, pe.y, "lee")
		if taken.size() >= 2:
			break
	# над базой облаков
	var base := a0.field.cloudbase_msl
	addy.call(f.x + 300.0, base + 150.0, f.z - 400.0, "above_base")
	addy.call(f.x - 1200.0, base + 600.0, f.z + 900.0, "above_base")
	addy.call(f.x + 2500.0, base + 1200.0, f.z + 2500.0, "above_base")
	# далеко от фокуса
	var far_m: float = ctx.far_m
	for ang in [30.0, 140.0, 250.0, 330.0]:
		var d := Vector2(sin(deg_to_rad(ang)), -cos(deg_to_rad(ang))) * far_m
		add.call(f.x + d.x, 50.0, f.z + d.y, "far")
		add.call(f.x + d.x, 600.0, f.z + d.y, "far")
	# край поля Пикара: вдоль ±X от фокуса — где доля поля падает ниже 0,9 и 0,4 (на 100 м над землёй)
	if bool(ctx.field):
		for dir in [Vector2(1, 0), Vector2(-1, 0), Vector2(0, 1), Vector2(0, -1)]:
			var hit9 := false
			var hit4 := false
			var r := 0.0
			while r < 40000.0 and not hit4:
				r += 100.0
				var x: float = f.x + dir.x * r
				var z: float = f.z + dir.y * r
				var gh := float(hf.call(x, z))
				var w := a0.air_field.sample(Vector3(x, gh + 100.0, z), gh).w
				if not hit9 and w < 0.9:
					hit9 = true
					add.call(x, 100.0, z, "field_edge")
				if w < 0.4:
					hit4 = true
					add.call(x, 100.0, z, "field_edge")
			if not hit9:
				print("gen_fixtures: %s — край поля по (%s) не найден" % [c.name, str(dir)])
	# по моментам: термики, грозы
	var wave_done := false
	for k in TIMES.size():
		var a := atmos[k]
		var t := TIMES[k]
		# ядра подъёма: самые сильные из живых в 5 км от фокуса, на 35 % и 60 % высоты столба
		var cores: Array = []
		for id: int in a.field.thermals:
			var th: AtmoThermal = a.field.thermals[id]
			th.update_time(t)
			var ax := th.axis_at(th.src.y)
			if Vector2(ax.x - f.x, ax.y - f.z).length() > 5000.0:
				continue
			cores.append([th.strength * th.env, id])
		cores.sort_custom(func(p: Array, q: Array) -> bool: return p[0] > q[0] or (p[0] == q[0] and p[1] < q[1]))
		var used := 0
		for e: Array in cores:
			if float(e[0]) < 0.8:
				break
			var th: AtmoThermal = a.field.thermals[int(e[1])]
			for frac in [0.35, 0.6]:
				var y: float = th.src.y + (th.top - th.src.y) * frac
				var ax := th.axis_at(y)
				addy.call(ax.x, y, ax.y, "thermal")
			used += 1
			if used >= 3:
				break
		# грозы: ячейки с силой > 0,2 — под ливнем, у фронта и в нисходящем потоке
		var st_used := 0
		for th: AtmoThermal in a.storm.cells:
			var e := a.storm.intensity(th, t)
			if e < 0.2 or st_used >= 2:
				continue
			var cc := th.cloud_center(t)
			var rd := a.storm.downdraft_radius(th)
			var rf := a.storm.front_radius(th, t)
			var cand: Array[Vector3] = [
				Vector3(cc.x + 0.5 * rd, 80.0, cc.y), Vector3(cc.x, 400.0, cc.y - 0.3 * rd),
				Vector3(cc.x + rf, 100.0, cc.y), Vector3(cc.x, 60.0, cc.y + rf),
			]
			for q in cand:
				var gh := float(hf.call(q.x, q.z))
				var sv := a.storm.sample(Vector3(q.x, gh + q.y, q.z), q.y, t)
				if Vector3(sv.x, sv.y, sv.z).length() > 0.3:
					addy.call(q.x, gh + q.y, q.z, "storm")
			st_used += 1
		# волна: гребни и подъём за ними (одни на все моменты — ветер не меняется)
		if not wave_done and a.wave.enabled:
			var wc: Dictionary = a.cfg.wave
			var crests := a.wave.crests(
				f, float(wc.lens_radius_m), float(wc.lens_min_eta_m), float(wc.lens_length_m[1]) * 0.9
			)
			var wu := a.wind.speed_at(a._wave_ref_agl)
			var cnt := 0
			for cr: Dictionary in crests:
				var p2: Vector2 = cr.pos
				if Vector2(p2.x - f.x, p2.y - f.z).length() > 14000.0:
					continue
				var gh := float(hf.call(p2.x, p2.y))
				for dy in [500.0, 1100.0, 1800.0]:
					var wy: float = maxf(float(cr.crest), gh) + dy
					var wv := a.wave.sample(Vector3(p2.x, wy, p2.y), wy - gh, wu)
					if absf(wv.x) > 0.3:
						addy.call(p2.x, wy, p2.y, "wave")
						wave_done = true
				cnt += 1
				if cnt >= 4:
					break


# ================================================================ описания W6


func _describe(a: Atmosphere, ctx: Dictionary, t: float) -> Dictionary:
	var f: Vector3 = ctx.focus
	var center := Vector2(f.x, f.z)
	var radius: float = ctx.desc_radius
	var cores := PackedFloat32Array()
	var ids: Array = a.field.thermals.keys()
	ids.sort()
	for id: int in ids:
		var th: AtmoThermal = a.field.thermals[id]
		th.update_time(t)
		var ax := th.axis_at(th.src.y)
		if center.distance_to(ax) > radius:
			continue
		var age := t - th.t_birth
		var stage := 1.5
		if not th.is_static:
			if age < th.t_grow:
				stage = clampf(age / maxf(th.t_grow, 1.0e-6), 0.0, 1.0)
			elif age <= th.t_grow + th.t_mature:
				stage = 1.0 + (age - th.t_grow) / maxf(th.t_mature, 1.0e-6)
			else:
				stage = 2.0 + th.decay_progress(t)
		var flags := (1 if th.is_static else 0) | (2 if th.has_cloud else 0) | (4 if th.is_cb else 0)
		var storm_k := a.storm.intensity(th, t) if th.is_cb else 0.0
		var life := NAN if th.is_static else th.t_end() - th.t_birth
		cores.append_array(PackedFloat32Array([
			id, flags, ax.x, ax.y, th.src.y, th.top, th.strength * th.env, th.radius,
			th.lean.x, th.lean.y, age, life, stage, th.noise_seed, storm_k,
		]))
	var clouds := PackedFloat32Array()
	var fld := a.cloud_phys.field
	var cid := 0
	if fld != null and fld.nx > 0:
		for cl: Dictionary in a.cloud_phys.visible_clouds(a.field.thermals, t, f):
			var cc: Vector2 = cl.center
			if center.distance_to(cc) > radius:
				continue
			var s := fld.sample(Vector3(cc.x, fld.base_msl, cc.y))
			var core_id := -1
			for id: int in ids:
				var th2: AtmoThermal = a.field.thermals[id]
				if not th2.is_cb and th2.axis_at(fld.base_msl) == cc:
					core_id = id
					break
			cid += 1
			clouds.append_array(PackedFloat32Array([
				cid, core_id, cc.x, cc.y, s.y, s.z, cl.radius, cl.growth, cl.decay, 0,
			]))
	for id: int in ids:
		var th3: AtmoThermal = a.field.thermals[id]
		if not th3.is_cb:
			continue
		var st := a.cloud_phys.model.stage(th3, t)
		if st.x < 0.0:
			continue
		var c3 := a.cloud_phys.model.center(th3, t)
		if center.distance_to(c3) > radius:
			continue
		var sz := a.cloud_phys.model.size(th3, st)
		clouds.append_array(PackedFloat32Array([
			100000 + id, id, c3.x, c3.y, th3.top, th3.top + sz.z, maxf(sz.x, sz.y), st.x, st.y, 4,
		]))
	var crests := PackedFloat32Array()
	if a.wave.enabled and a.wave.ground.has_ground:
		var wc: Dictionary = a.cfg.wave
		for cr: Dictionary in a.wave.crests(
			f, float(wc.lens_radius_m), float(wc.lens_min_eta_m), float(wc.lens_length_m[1]) * 0.9
		):
			var p2: Vector2 = cr.pos
			crests.append_array(PackedFloat32Array([p2.x, p2.y, cr.eta, cr.crest]))
	return {
		t = t,
		cloudbase_msl = a.get_cloudbase_msl(),
		cores = _flat(cores),
		clouds = _flat(clouds),
		crests = _flat(crests),
	}


# ================================================================ запись


## Плоский массив для json: NaN → null (json чисел NaN не знает).
func _flat(pf: PackedFloat32Array) -> Array:
	var out: Array = []
	for v in pf:
		out.append(null if is_nan(v) else v)
	return out



func _write_text(path: String, text: String) -> void:
	_write_bytes(path, text.to_utf8_buffer())


## Запись во временный файл и переименование.
func _write_bytes(path: String, bytes: PackedByteArray) -> void:
	var tmp := path + ".tmp"
	var fa := FileAccess.open(tmp, FileAccess.WRITE)
	if fa == null:
		push_error("gen_fixtures: не открыть %s" % tmp)
		return
	fa.store_buffer(bytes)
	fa.close()
	DirAccess.rename_absolute(tmp, path)
