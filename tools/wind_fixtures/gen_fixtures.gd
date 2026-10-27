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
	# Набор 2 (RW-1b): ход игры на Онгудае — условия-прогноз W5 v3, ход дня AtmoDay, окна 100/50 м,
	# пересчёт поля в полёте. Идут ПОСЛЕ набора 1: меняют состояние рельефа (солнце классов, вода).
	{name = "ongudai_day_1", place = "ongudai", day = true, seed = 1101, start_hour = 10.9,
		forecast = {temperature_c = 24.0, wind_speed_kmh = 12.0, wind_from_deg = 151.0, sky = "clear"},
		inflow = "start"},
	{name = "ongudai_day_2", place = "ongudai", day = true, seed = 1202, start_hour = 11.4,
		forecast = {temperature_c = 26.0, wind_speed_kmh = 25.0, wind_from_deg = 151.0, sky = "clear"},
		inflow = "start"},
	{name = "ongudai_day_3", place = "ongudai", day = true, seed = 1303, start_hour = 11.7,
		forecast = {temperature_c = 23.0, wind_speed_kmh = 10.0, wind_from_deg = 200.0, sky = "partly"},
		inflow = "inflow"},
]

## Прогон дня (набор 2): шаг игры, с (степень двойки — время атмосферы складывается без ошибки),
## конец прогона и снимок после конца подмены поля.
const DAY_DT := 0.25
const DAY_END_S := 3600.0
const DAY_AFTER_BLEND_S := 30.0
## Точки термиков дневных случаев — не ниже этой высоты над землёй, м (ось у склона бывает под землёй).
const DAY_THERMAL_AGL_MIN_M := 10.0

## Места-острова для T1 «сильный ветер» (RW-6q): слой detail 25 м из data/locations (поставка игры).
## Пишутся без случаев: при --places-only[=id,id], без --only и в прогоне, где есть случай
## ISLANDS_WITH (так их воспроизводит и verify.sh — в группе, где этот случай).
const ISLANDS: Array[String] = ["training_island", "volcano_island"]
const ISLANDS_WITH := "ongudai_medium"

var _out := ""
var _only: PackedStringArray = []
var _synthetic_only := false
var _places_only := false
var _places_ids: PackedStringArray = []
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
		elif a == "--places-only" or a.begins_with("--places-only="):
			_places_only = true
			if a.begins_with("--places-only="):
				_places_ids = a.substr(14).split(",")
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
	if _places_only:
		return await _write_island_places(_places_ids if not _places_ids.is_empty() else PackedStringArray(ISLANDS))
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
		var ok_case: bool
		if bool(c.get("day", false)):
			ok_case = await _run_day_case(c, ctx)
		else:
			ok_case = await _run_case(c, ctx)
		if not ok_case:
			return false
		print("gen_fixtures: %s готов за %.1f с" % [c.name, (Time.get_ticks_msec() - t0) / 1000.0])
	if not _synthetic_only and gpu and (_only.is_empty() or _only.has(ISLANDS_WITH)):
		if not await _write_island_places(PackedStringArray(ISLANDS)):
			return false
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
			month = MONTH, day = DAY, climate = _climate(51.5, 86.5, MONTH, DAY),
			climate_lag = _climate_lag(51.5, 86.5),
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


## Климат места для заголовка (W5 v3, loc.climate): ClimateGrid.place у центра места на month/day
## без высоты долины (valley_msl_m не задан — значения ячейки как есть, поправку на высоту долины
## из растра высот делает потребитель). Нет сетки HH1/HH5 — has_* = false и запасные значения конфига.
func _climate(lat: float, lon: float, month: int = MONTH, day: int = DAY) -> Dictionary:
	var r := ClimateGrid.place({"lat": lat, "lon": lon, "month": month, "day": day})
	var src: Dictionary = r.src
	return {
		tx_c = float(r.tx_c),
		dtr_k = float(r.dtr_k),
		z_cell_m = float(r.z_cell_m),
		has_hh1 = String(src.hh1) != "none",
		has_hh5 = String(src.hh5) != "none",
	}


## Климат воды (W5 v7, loc.climate_lag): та же ячейка на дату MONTH/DAY − round(water.lag_days) с
## переходом через год, как SurfaceHeat.water_temp_c (и AirPlaceData.fill_climate).
func _climate_lag(lat: float, lon: float, month: int = MONTH, day: int = DAY) -> Dictionary:
	var lag := int(round(float(SurfaceHeat.config().get("water", {}).get("lag_days", 30.0))))
	var doy := SunClock.day_of_year(month, day) - lag
	if doy < 1:
		doy += 365
	var md := SurfaceHeat._month_day(doy)
	return _climate(lat, lon, md.x, md.y)


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
	loc.climate = _climate(float(loc.center_lat), float(loc.center_lon), MONTH, DAY)
	loc.climate_lag = _climate_lag(float(loc.center_lat), float(loc.center_lon))
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

## Места-острова (RW-6q, T1): слой detail каждого острова из data/locations, дата — набор погоды
## первого старта (месяц острова: учебный — 7, вулканический — 1). Без случаев и без GPU.
func _write_island_places(ids: PackedStringArray) -> bool:
	var saved_root := Locations.fixtures_root
	Locations.fixtures_root = ""
	var ok := true
	for id in ids:
		var pd := await _island_place_data(id)
		if pd.is_empty():
			ok = false
			break
		_write_place(id, pd)
		print("gen_fixtures: место %s записано" % id)
	Locations.fixtures_root = saved_root
	return ok


func _island_place_data(id: String) -> Dictionary:
	var terrain := Terrain.new()
	add_child(terrain)
	if not terrain.load_location(id):
		push_error("gen_fixtures: место %s не загрузилось" % id)
		terrain.queue_free()
		return {}
	terrain.wait_relief()
	var month := MONTH
	var day := DAY
	for st: Dictionary in Locations.config(id).get("start_sites", []):
		if st.get("weather") is Dictionary:
			month = int(st.weather.month)
			day = int(st.weather.day)
			break
	# пояс часов места, как tools/terrain/bake_air.gd (_clock_utc_offset)
	var utc := NAN
	var uv: Variant = Config.value("world", "time.utc_offset_h", null)
	if uv is String and uv == "solar":
		utc = NAN
	elif uv != null:
		utc = float(uv)
	else:
		var z := float(terrain.location.get("utc_offset_h", NAN))
		utc = z if not is_nan(z) else roundf(terrain.center_lon / 15.0)
	var place := AirRuntime.place_of(terrain, utc, month, day)
	(place.surface as AirPlace.Surface).wait()
	var detail: HeightLayer = place.detail
	var sf: AirPlace.Surface = place.surface
	if (
		sf.width != detail.width or sf.height != detail.height
		or sf.origin_x != detail.origin_x or sf.origin_z != detail.origin_z
	):
		push_error("gen_fixtures: сетка поверхности %s не совпала со слоем detail" % id)
		return {}
	var n := detail.width * detail.height
	var water := _water_nodes(place.water, detail)
	if water.size() != n or sf.cls.size() != n or sf.moist.size() != n:
		push_error("gen_fixtures: длины растров места %s не сошлись с %d" % [id, n])
		return {}
	var sites: Array = []
	for st: Dictionary in place.start_sites:
		var p: Vector3 = st.position
		sites.append({id = String(st.id), x = p.x, z = p.z, h_msl = p.y})
	var loc: Dictionary = (place.loc as Dictionary).duplicate()
	loc.month = month
	loc.day = day
	loc.climate = _climate(float(loc.center_lat), float(loc.center_lon), month, day)
	loc.climate_lag = _climate_lag(float(loc.center_lat), float(loc.center_lon), month, day)
	var pd := {
		loc = loc,
		grid = {origin_x = detail.origin_x, origin_z = detail.origin_z, spacing = detail.spacing, width = detail.width, height = detail.height},
		start_sites = sites,
		heights = detail.heights, water = water, cls = sf.cls, moist = sf.moist, h_scale = 0.03125,
		note = "%s (data/locations/%s): слой detail 25 м, AirRuntime.place_of; water — узел по ближайшему пикселю маски (> 127), cls/moist — снимок поверхности AirPlace.Surface; для T1 «сильный ветер» RW-6q" % [id, id],
	}
	terrain.queue_free()
	return pd


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
	var names := ["atmosphere", "weather_model", "surface_heat"]
	if preset != "":
		names.append("weather/" + preset)
	for n in names:
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
	_pick_static(c, ctx, atmos[0], pts, tags)
	var st := {wave_done = false}
	for k in TIMES.size():
		_pick_moment(ctx, atmos[k], TIMES[k], pts, tags, st)


## Точки, не зависящие от момента (по состоянию атмосферы a0 на старте): земля, тень, над базой,
## далеко, край поля.
func _pick_static(
	c: Dictionary, ctx: Dictionary, a0: Atmosphere, pts: Array[Vector3], tags: Array[String]
) -> void:
	var f: Vector3 = ctx.focus
	var hf: Callable = ctx.height_fn
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


## Точки, зависящие от момента (состояние a на t): сильные термики, грозы, волна (st.wave_done —
## волна берётся один раз на случай: гребни одни на все моменты).
func _pick_moment(
	ctx: Dictionary, a: Atmosphere, t: float, pts: Array[Vector3], tags: Array[String], st: Dictionary
) -> void:
	var f: Vector3 = ctx.focus
	var hf: Callable = ctx.height_fn
	var addy := func(x: float, y: float, z: float, tag: String) -> void:
		pts.append(Vector3(x, y, z))
		tags.append(tag)
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
		var added := false
		for frac in [0.35, 0.6]:
			var y: float = th.src.y + (th.top - th.src.y) * frac
			var ax := th.axis_at(y)
			# ось термика у склона может уйти под землю (воздуха там нет — MEAN = 0): в дневных
			# случаях такие точки не берутся (st.agl_min); у набора 1 фильтра нет
			if y - float(hf.call(ax.x, ax.y)) < float(st.get("agl_min", -1.0e9)):
				continue
			addy.call(ax.x, y, ax.y, "thermal")
			added = true
		if added:
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
	if not st.wave_done and a.wave.enabled:
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
					st.wave_done = true
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


# ================================================================ ход игры (набор 2)


## Часовой пояс места так же, как Game._clock_utc_offset.
func _clock_utc_offset() -> float:
	var v: Variant = Config.value("world", "time.utc_offset_h", null)
	if v is String and v == "solar":
		return NAN
	if v != null:
		return float(v)
	var z := float(_terrain.location.get("utc_offset_h", NAN))
	return z if not is_nan(z) else roundf(_terrain.center_lon / 15.0)


func _run_day_case(c: Dictionary, ctx: Dictionary) -> bool:
	# Проход 1 — схема моментов и точки (термики/грозы берутся из состояния на моменте, а моменты
	# известны только в конце прогона); проход 2 — выборка и описания по этим точкам. Игровое время
	# держится на сроке, пока пересчёт не подан, поэтому оба прохода идут по одним и тем же t.
	var r1 := await _day_course(c, ctx, {})
	if r1.is_empty():
		return false
	var r2 := await _day_course(c, ctx, r1)
	if r2.is_empty():
		return false
	var times: Array = r1.times
	var n: int = r1.pts.size()
	var weather_cfg := WeatherModel.config()
	var focus: Vector3 = ctx.focus
	var fc: Dictionary = c.forecast
	var applies: Array = r2.applies
	var t_apply: Array = []
	for e: Dictionary in applies:
		t_apply.append(e.t)
	var blend := float(Config.get_config("atmosphere").air_model.blend_s)
	var statics: Array = []
	for st: Dictionary in _terrain.location.get("thermals", []):
		statics.append([float(st.x_m), float(st.z_m), float(st.strength_ms), float(st.radius_m)])
	var gain := float(r2.gain_per_km)
	var cfg := {
		version = FORMAT_VERSION,
		place = String(c.place),
		conditions = {
			forecast = fc,
			start_hour = float(c.start_hour),
			speed = float(r2.clock_speed),
			quantum_h = float(weather_cfg.get("diurnal", {}).get("update_s", 60.0)) / 3600.0,
			wind_ref = {ref_msl = focus.y, gain_per_km = gain},
			overrides = {thermal_spacing_m = float(r2.peak_spacing_m)},
			blend_s = null,
			rebuild = false,
			inflow_mode = String(c.inflow),
		},
		seed = int(c.seed),
		static_thermals = statics,
		configs_sha1 = _config_hashes(""),
		times_s = times,
		focuses = [[focus.x, focus.y, focus.z, 1.0]],
		points = _pts_json(r1.pts),
		point_tags = r1.tags,
		terms = null,
		generator = _git_rev,
		extra = {
			sample_recipe = "FULL: v = air_velocity_at(p), σ = _last_sigma (turbulence_enabled = true). MEAN: v = air_velocity_at(p) при turbulence_enabled = false (без шума порывов и бурления в облаке); σ в MEAN — та же, что в FULL",
			moments = "ход игры, не start_at на каждый момент: загрузка (AirRuntime.load_field: два прохода k при inflow_mode start, окна 100/50 м у старта) → шаги DAY_DT с 0; на сроке recompute_game_min пересчёт поля в полёте (подмена за blend_s). Игровое время держится на сроке, пока пересчёт не подан; t_apply — время атмосферы подачи нового поля. Моменты: 0 (после загрузки), t_apply[0] + blend_s/2, t_apply[0] + blend_s + 30, 3600",
			desc_center = [focus.x, focus.z],
			desc_radius = ctx.desc_radius,
			field = true,
			dt_s = DAY_DT,
			t_apply = t_apply,
			t_apply_1 = t_apply[0],
			blend_s = blend,
			applies = applies,
			load = r2.load,
			window_levels_m = Config.get_config("atmosphere").air_model.window_levels_m,
			levels = r2.levels,
			point_labels = r2.labels,
			wind_ref_msl = ctx.ref_msl,
			config_overrides = {
				"air_runtime": "как в игре: focus_fn = старт места (start_sites[0]), окна 100/50 м, без кеша и запечённого поля; фокус неподвижен — сдвигов окон нет",
			},
			hour_note = "ход дня AtmoDay (WeatherModel.derive по часу), солнце по дате и месту, источники термиков по солнцу с инерцией прогрева — как Game._make_day",
		},
	}
	_write_text(_out.path_join("cases/%s.json" % c.name), JSON.stringify(cfg) + "\n")
	_write_bytes(_out.path_join("cases/%s.bin" % c.name), (r2.data as PackedFloat32Array).to_byte_array())
	_write_text(
		_out.path_join("cases/%s.desc.json" % c.name),
		JSON.stringify({
			version = FORMAT_VERSION, core_stride = CORE_STRIDE, cloud_stride = CLOUD_STRIDE,
			crest_stride = CREST_STRIDE, frames = r2.descs,
		}) + "\n"
	)
	for t in _tag_set(r1.tags):
		_tags_seen[t] = true
	print("gen_fixtures: %s — моментов %d, точек %d, подач поля в полёте %d (t = %s)" % [c.name, times.size(), n, applies.size(), str(t_apply)])
	return true


func _tag_set(tags: Array) -> Array:
	var seen := {}
	for t: String in tags:
		seen[t] = true
	return seen.keys()


## Прогон дня в духе игры (Game._load_air_field + Game.tick). plan пуст — проход 1 (выбор точек и
## схемы моментов); иначе — проход 2 (выборка по plan.pts на plan.times). Пустой результат — ошибка.
func _day_course(c: Dictionary, ctx: Dictionary, plan: Dictionary) -> Dictionary:
	var picking := plan.is_empty()
	var terrain := _terrain
	var fc: Dictionary = c.forecast
	var focus: Vector3 = ctx.focus
	var wcfg := WeatherModel.config()
	# --- контекст погоды: Game._weather_context
	var g: Dictionary = Config.get_config("atmosphere").ground
	var wctx := WeatherModel.ground_context(
		terrain.height_at, float(g.reference_radius_m), int(g.reference_samples), float(wcfg.valley_percentile)
	)
	var utc := _clock_utc_offset()
	wctx.merge({
		"month": MONTH, "day": DAY, "lat": terrain.center_lat, "lon": terrain.center_lon, "utc_offset_h": utc,
	})
	var peak := float(WeatherModel.derive(fc, wctx).thermal_spacing_m)
	var derive := func(hour: float) -> Dictionary:
		var w := WeatherModel.derive(fc, wctx, {}, hour)
		w.thermal_spacing_m = peak
		return w
	# --- атмосфера: Game.start (порядок вызовов как там)
	var a := Atmosphere.new()
	a.visuals_enabled = false
	a.seed_value = int(c.seed)
	a.set_day(null)
	a.set_weather(derive.call(float(c.start_hour)))
	a.time_s = 0.0
	a.cloud_phys.deterministic = true
	a.cloud_phys.async_field = false
	# сборка источников термиков при подаче нового поля — синхронно: иначе она подменяется «по
	# готовности» в рабочем потоке, на шаге, зависящем от времени стены (недетерминированно)
	a.field.air_async = false
	a.set_ground(terrain.height_at, terrain.thermal_source_strength_at)
	var clock := SunClock.new()
	clock.start_flight(
		terrain.center_lat, terrain.center_lon, MONTH, DAY, float(c.start_hour),
		float(terrain.location.get("utc_offset_h", NAN))
	)
	terrain.set_sun(clock.to_sun())
	clock.sun_changed.connect(terrain.set_sun)
	terrain.set_flight_date(MONTH, DAY)
	terrain.clear_water_heat()
	var heating := SurfaceHeating.new()
	heating.setup(float(wctx.lat), float(wctx.lon), MONTH, DAY, float(wctx.utc_offset_h))
	var wh := {hour = NAN}
	var water_at := func(hour: float) -> Dictionary:
		var wcf: Dictionary = SurfaceHeat.config().water
		var z := float(wctx.get("valley_msl_m", 0.0))
		return {
			"t_water_c": SurfaceHeat.water_temp_c(MONTH, DAY, z, wctx, wcf),
			"t_air_c": SurfaceHeat.air_temp_c(hour, float(fc.get("temperature_c", 20.0)), z, wctx, wcf),
			"u_ms": float(fc.get("wind_speed_kmh", 0.0)) / 3.6,
			"z_m": z,
		}
	var on_sun := func(to_sun: Vector3) -> void:
		a.set_sun_direction(to_sun)
		var h: float = clock.hour
		terrain.set_class_sun(heating.directions(h), heating.built_night(h))
		# контекст воды Terrain — раз в час игры (Game._update_water_heat)
		if is_nan(float(wh.hour)) or absf(h - float(wh.hour)) >= 1.0:
			wh.hour = h
			var w: Dictionary = water_at.call(h)
			terrain.set_water_heat(w.t_water_c, w.t_air_c, w.u_ms)
	clock.sun_changed.connect(on_sun)
	on_sun.call(clock.to_sun())
	# --- ход дня: Game._make_day
	var d := AtmoDay.new()
	d.start_hour = clock.hour
	d.t0 = a.time_s
	d.speed = clock.speed
	d.quantum_h = float(wcfg.get("diurnal", {}).get("update_s", 60.0)) / 3600.0
	d.weather_fn = derive
	var sun_fn := AtmoDay.sun_direction.bind(
		clock.latitude_deg, clock.longitude_deg, clock.month, clock.day, utc
	)
	d.sun_fn = sun_fn
	var cache := {"h": NAN, "dirs": PackedVector3Array(), "sun": Vector3.UP, "water": {}, "night": {}}
	d.source_fn = func(x: float, z: float, h: float) -> float:
		if h != float(cache.h):
			cache.h = h
			cache.dirs = heating.directions(h)
			cache.sun = sun_fn.call(h)
			cache.water = water_at.call(h)
			cache.night = heating.built_night(h)
		return terrain.thermal_source_strength_water(x, z, cache.dirs, cache.sun, cache.water, cache.night)
	a.set_day(d)
	a.load_static_thermals(terrain.location.get("thermals", []))
	var gain := float(ClimateGrid.place(wctx.merged({"start_msl_m": focus.y})).gain_per_km)
	a.set_wind(float(fc.wind_speed_kmh), float(fc.wind_from_deg), focus.y, gain)
	a.set_focus(focus)
	# --- поле: AirRuntime как в игре (окна у старта, два прохода k, без кеша и запечённого поля)
	var rt := AirRuntime.new()
	rt.baked_enabled = false
	rt.cache_enabled = false
	add_child(rt)
	await get_tree().process_frame
	var inflow := String(c.inflow)
	rt.setup(a, ctx.place, func() -> Dictionary:
		return {
			hour = clock.hour,
			u10 = float(a.weather().get("wind_speed_kmh", 0.0)) / 3.6,
			wdir = float(a.weather().get("wind_from_deg", 0.0)),
			t_max = float(fc.temperature_c),
			sky = String(fc.sky),
			wind_ref = inflow,
		}
	)
	rt.focus_fn = func() -> Vector3: return focus
	var loads: Array = []
	var applies: Array = []
	rt.field_applied.connect(func(info: Dictionary) -> void:
		var ks: Array = []
		for pl: Dictionary in info.get("pass_log", []):
			ks.append(pl.k)
		var u1 := float(info.get("u_start10", NAN))
		var e := {
			t = a.time_s,
			hour = float(info.hour),
			reason = String(info.reason),
			passes = int(info.get("passes", 1)),
			k_passes = ks,
			inflow_k = float(info.get("inflow_k", 1.0)),
			u_start10 = null if is_nan(u1) else u1,
		}
		if bool(info.get("loading", false)):
			loads.append(e)
		else:
			applies.append(e)
	)
	var why := rt.unavailable_reason()
	if why != "":
		push_error("gen_fixtures: %s — поле недоступно: %s" % [c.name, why])
		return _day_fail(rt, a)
	var ok: bool = await rt.load_field()
	if not ok or not a.is_air_field_on() or loads.size() != 1:
		push_error("gen_fixtures: %s — поле не посчитано при загрузке" % c.name)
		return _day_fail(rt, a)
	rt.recompute_enabled = true
	rt.set_process(false)  # дальше _process зовём сами, по шагу (детерминированный порядок)
	a.refresh_now()
	# --- ход: Game.tick = clock.advance + air.step; пересчёт — AirRuntime._process
	var S := {
		picking = picking, c = c, ctx = ctx, st = {wave_done = false, agl_min = DAY_THERMAL_AGL_MIN_M},
		pts = [] as Array[Vector3], tags = [] as Array[String], special = {},
		data = PackedFloat32Array(), descs = [], times = [],
	}
	if not picking:
		S.pts = plan.pts
		S.tags = plan.tags
		S.special = plan.special
	var snaps: Array = [0.0]
	if not picking:
		snaps = (plan.times as Array).duplicate()
	var si := 0
	var steps := 0
	var guard := 0
	while true:
		while si < snaps.size() and a.time_s >= float(snaps[si]) - 1.0e-9:
			_day_snapshot(S, a)
			si += 1
		if a.time_s >= DAY_END_S - 1.0e-9:
			break
		clock.advance(DAY_DT)
		a.step(DAY_DT)
		steps += 1
		rt._process(0.0)
		while rt.busy():
			await get_tree().process_frame
			rt._process(0.0)
			guard += 1
			if guard > 100000:
				push_error("gen_fixtures: %s — пересчёт не завершается" % c.name)
				return _day_fail(rt, a)
		if rt.failed_count > 0:
			push_error("gen_fixtures: %s — пересчёт поля в полёте не удался: %s" % [c.name, rt.last_error])
			return _day_fail(rt, a)
		if picking and applies.size() >= 1 and snaps.size() == 1:
			var ta := float(applies[0].t)
			var bl := float(Config.get_config("atmosphere").air_model.blend_s)
			snaps.append(ceilf((ta + 0.5 * bl) / DAY_DT) * DAY_DT)
			snaps.append(ceilf((ta + bl + DAY_AFTER_BLEND_S) / DAY_DT) * DAY_DT)
			snaps.append(DAY_END_S)
		if steps % 1000 == 0:
			await get_tree().process_frame
	if picking and snaps.size() < 4:
		push_error("gen_fixtures: %s — пересчёта поля в полёте не было" % c.name)
		return _day_fail(rt, a)
	if si != snaps.size():
		push_error("gen_fixtures: %s — не все моменты сняты (%d из %d)" % [c.name, si, snaps.size()])
		return _day_fail(rt, a)
	if not picking and applies.size() != int(plan.applies.size()):
		push_error("gen_fixtures: %s — проход 2 подал поле %d раз, проход 1 — %d" % [c.name, applies.size(), plan.applies.size()])
		return _day_fail(rt, a)
	for i in applies.size():
		if not picking and float(applies[i].t) != float(plan.applies[i].t):
			push_error("gen_fixtures: %s — t_apply расходится между проходами: %s и %s" % [c.name, applies[i].t, plan.applies[i].t])
			return _day_fail(rt, a)
	# подписи точек: самый мелкий уровень поля, где вес края 1; особые — края окон
	var lv: Array = a.air_field.levels
	var labels: Array = []
	var levels_json: Array = []
	for f: WindField in lv:
		var cc := f.center_xz()
		levels_json.append({dx = f.dx, size_m = f.size_x(), center = [cc.x, cc.y], edge_cells = f.edge_cells})
	for i in S.pts.size():
		if S.special.has(i):
			labels.append(S.special[i])
			continue
		# самый мелкий уровень с весом 1; иначе точка в полосе края (смесь уровней), иначе — аналитика
		var lab := "analytic"
		for f: WindField in lv:
			var w := f.edge_weight(S.pts[i])
			if w >= 0.999:
				lab = "L%d" % int(f.dx)
				break
			if w > 0.0:
				lab = "blend"
				break
		labels.append(lab)
	var out := {
		times = S.times, pts = S.pts, tags = S.tags, labels = labels, special = S.special,
		data = S.data, descs = S.descs,
		applies = applies, load = loads[0], levels = levels_json, gain_per_km = gain,
		peak_spacing_m = peak, clock_speed = clock.speed,
	}
	rt.stop()
	rt._release_clip()
	rt.queue_free()
	await get_tree().process_frame
	a.free()
	return out


func _day_fail(rt: AirRuntime, a: Atmosphere) -> Dictionary:
	rt.stop()
	rt._release_clip()
	rt.queue_free()
	a.free()
	return {}


## Момент снимка дня: проход 1 — точки (статичные на t = 0, зависящие от момента — на каждом);
## проход 2 — выборка по уже выбранным точкам и описания.
func _day_snapshot(S: Dictionary, a: Atmosphere) -> void:
	var t := a.time_s
	S.times.append(t)
	var ctx: Dictionary = S.ctx
	if S.picking:
		if S.times.size() == 1:
			_pick_static(S.c, ctx, a, S.pts, S.tags)
			_pick_windows(ctx, a, S.pts, S.tags, S.special)
		_pick_moment(ctx, a, t, S.pts, S.tags, S.st)
		return
	var data: PackedFloat32Array = S.data
	var base := data.size()
	data.resize(base + S.pts.size() * 8)
	for i in S.pts.size():
		var r := _sample_both(a, S.pts[i])
		for m in 8:
			data[base + i * 8 + m] = r[m]
	S.data = data
	S.descs.append(_describe(a, ctx, t))


## Края окон поля: по 4 направлениям, на 100 м над землёй, в середине полосы края уровня (там
## поле плавно уступает следующему уровню): край окна 50 м (граница 100/50) и окна 100 м (граница
## 100/400). Теги W8 — field_edge, пометка — в special (extra.point_labels).
func _pick_windows(
	ctx: Dictionary, a: Atmosphere, pts: Array[Vector3], tags: Array[String], special: Dictionary
) -> void:
	var hf: Callable = ctx.height_fn
	var lv: Array = a.air_field.levels
	for i in lv.size() - 1:
		var f: WindField = lv[i]
		var parent: WindField = lv[i + 1]
		var cc := f.center_xz()
		var r := 0.5 * f.size_x() - 0.5 * f.edge_cells * f.dx
		for dir in [Vector2(1, 0), Vector2(-1, 0), Vector2(0, 1), Vector2(0, -1)]:
			var x: float = cc.x + dir.x * r
			var z: float = cc.y + dir.y * r
			pts.append(Vector3(x, float(hf.call(x, z)) + 100.0, z))
			tags.append("field_edge")
			special[pts.size() - 1] = "edge_%d_%d" % [int(f.dx), int(parent.dx)]


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
