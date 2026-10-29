# gdlint: disable=max-public-methods
extends TestCase
## Контрактные тесты фасада ветра (rust-wind, docs/contracts/rust-wind.md): T5 (форматы, оси и
## единицы, ошибки, порядок команд), T6 (время, готовность, фокусы, найденные ядра), W7 (разложение).
## Без GPU: место — синтетическое из tests/fixtures/wind/places/synthetic, воздух — аналитика.
## Правка контракта (версия +1) — вместе с правкой CONTRACTS ниже.
##
## Реализация — один параметр: IMPLS (RW-7 добавит "rust" и прогонит файл ещё раз при
## air.backend = rust); создаёт её _make(). "calm" — CalmAir (ветер 0, READY сразу).

## Версии разделов — те же, что в заголовках docs/contracts/rust-wind.md и rust-wind/*.md.
const CONTRACTS := {
	W1 = 2, W2 = 3, W3 = 4, W4 = 5, W5 = 8, W6 = 3, W7 = 1, W8 = 1, W9 = 2, W10 = 2, W11 = 11
}
const DOCS: Array[String] = [
	"res://docs/contracts/rust-wind.md",
	"res://docs/contracts/rust-wind/descriptions.md",
	"res://docs/contracts/rust-wind/fixtures-tolerances.md",
]
const PLACE := "res://tests/fixtures/wind/places/synthetic"
## Реализации, которые гоняет файл.
const IMPLS: Array[String] = ["gd", "calm"]
## Коды классов поверхности (AirPlace.Surface, SurfaceLayer.CLASS_NAMES) — зафиксированы здесь.
const CLASSES := {
	"none": 0, "forest": 1, "grass": 2, "crop": 3, "shrub": 4, "bare": 5, "water": 6, "built": 7,
	"snow": 8,
}
const CENTER := Vector3(1500.0, 0.0, -2500.0)

static var _place: AirPlaceData


# ------------------------------------------------------------------ помощники


## Единственное место, где создаётся реализация фасада.
func _make(impl: String) -> Node:
	if impl == "calm":
		return CalmAir.new()
	var a := Atmosphere.new()
	a.visuals_enabled = false
	return a


static func _synthetic() -> AirPlaceData:
	if _place != null:
		return _place
	var h: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(PLACE + ".json"))
	var bin := FileAccess.get_file_as_bytes(PLACE + ".bin")
	var g: Dictionary = h.grid
	var n := int(g.width) * int(g.height)
	var heights := PackedFloat32Array()
	heights.resize(n)
	var off := float(h.h_offset)
	var sc := float(h.h_scale)
	for i in n:
		heights[i] = off + sc * bin.decode_s16(2 * i)
	var moist := PackedFloat32Array()
	moist.resize(n)
	for i in n:
		moist[i] = bin[4 * n + i] / 255.0
	_place = AirPlaceData.from_arrays(
		AirPlaceData.make_header(h.loc, h.grid, h.start_sites),
		heights,
		bin.slice(2 * n, 3 * n),
		bin.slice(3 * n, 4 * n),
		moist
	)
	_place.fill_climate()
	return _place


static func _preset(kmh: float = 14.0, from_deg: float = 230.0) -> Dictionary:
	var w: Dictionary = Config.get_config("weather/medium").duplicate(true)
	w.wind_speed_kmh = kmh
	w.wind_from_deg = from_deg
	return w


## До READY: pump с бюджетом, не больше max_iter кадров.
func _pump(a: Node, max_iter: int = 5000) -> bool:
	for i in max_iter:
		if int(a.status().state) == 2:
			return true
		a.pump(4000)
	return int(a.status().state) == 2


## Воздух на синтетическом месте в состоянии READY.
func _up(impl: String, preset: Dictionary = {}, seed: int = 4242) -> Node:
	var a := _make(impl)
	check(a.configure(seed) == 0, "%s: configure(seed) = OK" % impl)
	check(a.set_conditions({"preset": preset if not preset.is_empty() else _preset()}) == 0, "%s: set_conditions" % impl)
	check(a.load_place(_synthetic()) == 0, "%s: load_place" % impl)
	check(_pump(a), "%s: дошёл до READY" % impl)
	return a


func _pts_around(agls: Array[float], radius: float = 600.0) -> PackedVector3Array:
	var out := PackedVector3Array()
	var pl := _synthetic()
	for agl in agls:
		for k in 6:
			var a := TAU * k / 6.0
			var x := CENTER.x + cos(a) * radius
			var z := CENTER.z + sin(a) * radius
			out.append(Vector3(x, pl.height_at(x, z) + agl, z))
	return out


static func _all_finite(a: PackedFloat32Array) -> bool:
	for v in a:
		if not is_finite(v):
			return false
	return true


# ------------------------------------------------------------------ версии, константы


func test_versions_match_docs() -> void:
	var re := RegEx.new()
	re.compile("(?m)^#{1,2} (W\\d+)\\..*\\(v(\\d+)\\)\\s*$")
	var found := {}
	for path in DOCS:
		var text := FileAccess.get_file_as_string(path)
		check(text != "", "документ %s читается" % path)
		for m in re.search_all(text):
			var id := m.get_string(1)
			var v := int(m.get_string(2))
			check(not found.has(id) or int(found[id]) == v, "%s: версии в документах расходятся" % id)
			found[id] = v
	for c: String in CONTRACTS:
		check(found.has(c), "раздел %s в контракте" % c)
		check(
			int(found.get(c, -1)) == int(CONTRACTS[c]),
			"%s: версия в документе v%s ≠ в тесте v%s" % [c, found.get(c, "?"), CONTRACTS[c]]
		)
	check(found.size() == CONTRACTS.size(), "лишние разделы в контракте: %s" % [found.keys()])
	check(Atmosphere.WIND_API_VERSION == int(CONTRACTS.W2), "WIND_API_VERSION = версия W2")
	check(CalmAir.WIND_API_VERSION == Atmosphere.WIND_API_VERSION, "CalmAir.WIND_API_VERSION")


func test_constants() -> void:
	check(
		[Atmosphere.STATE_EMPTY, Atmosphere.STATE_LOADING, Atmosphere.STATE_READY, Atmosphere.STATE_FAILED] == [0, 1, 2, 3],
		"состояния W1"
	)
	check([Atmosphere.OK, Atmosphere.BAD_INPUT, Atmosphere.NO_PLACE, Atmosphere.NOT_READY] == [0, 1, 2, 3], "коды W1")
	check(Atmosphere.SAMPLE_FULL == 0 and Atmosphere.SAMPLE_MEAN == 1, "режимы выборки")
	check(Atmosphere.CORE_STRIDE == 15 and Atmosphere.CLOUD_STRIDE == 10 and Atmosphere.CREST_STRIDE == 4, "шаги W6")
	check(CalmAir.CORE_STRIDE == 15 and CalmAir.CLOUD_STRIDE == 10 and CalmAir.CREST_STRIDE == 4, "шаги W6 у CalmAir")
	var core := [
		Atmosphere.CORE_ID, Atmosphere.CORE_FLAGS, Atmosphere.CORE_X, Atmosphere.CORE_Z,
		Atmosphere.CORE_Y_SRC, Atmosphere.CORE_TOP, Atmosphere.CORE_W, Atmosphere.CORE_RADIUS,
		Atmosphere.CORE_LEAN_X, Atmosphere.CORE_LEAN_Z, Atmosphere.CORE_AGE, Atmosphere.CORE_LIFE,
		Atmosphere.CORE_STAGE, Atmosphere.CORE_VIS_SEED, Atmosphere.CORE_STORM,
	]
	check(core == range(15), "смещения CORE_* = 0..14 в порядке W6")
	var cloud := [
		Atmosphere.CLOUD_ID, Atmosphere.CLOUD_CORE_ID, Atmosphere.CLOUD_X, Atmosphere.CLOUD_Z,
		Atmosphere.CLOUD_BASE, Atmosphere.CLOUD_TOP, Atmosphere.CLOUD_RADIUS, Atmosphere.CLOUD_GROWTH,
		Atmosphere.CLOUD_DECAY, Atmosphere.CLOUD_FLAGS,
	]
	check(cloud == range(10), "смещения CLOUD_* = 0..9 в порядке W6")
	check(
		[Atmosphere.CREST_X, Atmosphere.CREST_Z, Atmosphere.CREST_ETA, Atmosphere.CREST_CREST] == [0, 1, 2, 3],
		"смещения CREST_*"
	)


func test_surface_classes_fixed() -> void:
	check(AirPlaceData.surface_classes() == CLASSES, "коды классов поверхности: %s" % [AirPlaceData.surface_classes()])
	var h: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(PLACE + ".json"))
	var same := (h.surface_classes as Dictionary).size() == CLASSES.size()
	for k: String in h.surface_classes:
		same = same and CLASSES.has(k) and int(h.surface_classes[k]) == int(CLASSES[k])
	check(same, "коды в эталонном месте те же")


# ------------------------------------------------------------------ место и условия (W5)


func _check_climate(p: AirPlaceData, label: String) -> void:
	var cl: Variant = p.header.loc.get("climate")
	check(cl is Dictionary, "%s: loc.climate есть" % label)
	if not cl is Dictionary:
		return
	for k in ["tx_c", "dtr_k", "z_cell_m"]:
		check((cl as Dictionary).has(k) and is_finite(float(cl[k])), "%s: climate.%s — конечное число" % [label, k])
	for k in ["has_hh1", "has_hh5"]:
		check((cl as Dictionary).has(k) and cl[k] is bool, "%s: climate.%s — bool" % [label, k])
	check(float(cl.dtr_k) >= 0.0, "%s: суточная амплитуда ≥ 0" % label)


func test_place_climate() -> void:
	_check_climate(_synthetic(), "синтетика")
	# load_place сам дополняет заголовок без климата
	var g := _synthetic()
	var h: Dictionary = g.header.duplicate(true)
	(h.loc as Dictionary).erase("climate")
	var p := AirPlaceData.from_arrays(h, g.heights, g.water, g.surface_cls, g.surface_moist)
	var a := _make("gd")
	check(a.load_place(p) == 0, "load_place без climate — OK")
	_check_climate(p, "после load_place")
	a.free()


## Онгудай: место из рельефа игры (from_terrain), климат заполнен; has_hh5 соответствует сетке.
func test_place_from_terrain_ongudai() -> void:
	var t := Terrain.new()
	t.location_id = ""
	check(t.load_location("ongudai"), "Онгудай загрузился")
	t.wait_relief()
	var utc := float(Config.get_config("locations/ongudai").get("utc_offset_h", NAN))
	var p := AirPlaceData.from_terrain(t, utc, 7, 15)
	check(p != null, "from_terrain вернул место")
	if p != null:
		check(p.validate() == "", "место проходит validate: %s" % p.validate())
		_check_climate(p, "Онгудай")
		var cl: Dictionary = p.header.loc.climate
		var grid_present: bool = ClimateGrid.at(float(p.header.loc.center_lat), float(p.header.loc.center_lon), 7, 15).src.hh5 != "none"
		check(bool(cl.has_hh5) == grid_present, "has_hh5 соответствует наличию сетки")
		var sites: Array = p.header.start_sites
		check(sites.size() >= 1, "стартовые площадки есть")
		check(absf(p.height_at(0.0, 0.0) - t.height_at(0.0, 0.0)) < 1.0e-3, "высота — рельеф игры")
		check(p.raster_height(0.0, 0.0) > 0.0, "растр высот заполнен")
		var a := _make("gd")
		check(a.load_place(p) == 0, "load_place места из рельефа")
		check(_pump(a), "READY на месте из рельефа (аналитика)")
		check(_all_finite(a.sample_many(PackedVector3Array([Vector3(0, p.height_at(0, 0) + 50.0, 0)]))), "ответ конечен")
		a.free()
	t.free()


func test_place_validation() -> void:
	var a := _make("gd")
	var good := _synthetic()
	check(a.load_place(null) == 1, "место null — BAD_INPUT")
	var bad := AirPlaceData.from_arrays(good.header.duplicate(true), good.heights, good.water, good.surface_cls, good.surface_moist)
	bad.header.version = 2
	check(a.load_place(bad) == 1, "версия 2 — BAD_INPUT")
	bad = AirPlaceData.from_arrays(good.header, good.heights.slice(0, 100), good.water, good.surface_cls, good.surface_moist)
	check(a.load_place(bad) == 1, "длина heights ≠ сетке — BAD_INPUT")
	var hn := good.heights.duplicate()
	hn[5] = NAN
	bad = AirPlaceData.from_arrays(good.header, hn, good.water, good.surface_cls, good.surface_moist)
	check(a.load_place(bad) == 1, "NaN в heights — BAD_INPUT")
	check(a.last_error() != "", "last_error объясняет отказ")
	check(int(a.status().state) == 0, "отказ не меняет состояние (EMPTY)")
	a.free()


func test_conditions_validation() -> void:
	for impl in IMPLS:
		var a := _make(impl)
		check(a.set_conditions({}) == 1, "%s: пустые условия — BAD_INPUT" % impl)
		check(a.set_conditions({"preset": _preset(), "forecast": {}}) == 1, "%s: оба вида — BAD_INPUT" % impl)
		check(a.set_conditions({"preset": _preset(), "bogus": 1}) == 1, "%s: посторонний ключ — BAD_INPUT" % impl)
		if impl == "gd":
			check(a.set_conditions({"preset": _preset(), "inflow_mode": "x"}) == 1, "inflow_mode вне списка — BAD_INPUT")
			check(a.set_conditions({"preset": _preset(), "inflow_mode": "inflow"}) == 0, "inflow_mode inflow — OK")
			check(a.set_conditions({"preset": _preset(), "inflow_mode": "start", "speed": 1.0, "start_hour": 12.0, "blend_s": null, "rebuild": false}) == 0, "общие ключи эталона — OK")
			var fc := {"temperature_c": 25.0, "wind_speed_kmh": 10.0, "wind_from_deg": 90.0, "sky": "clear"}
			check(a.set_conditions({"forecast": fc, "start_hour": 11.0, "speed": 1.0, "quantum_h": 0.0167, "wind_ref": null, "overrides": {}}) == 0, "прогноз — OK")
			check(a.set_conditions({"forecast": {"temperature_c": 25.0}}) == 1, "прогноз без ветра — BAD_INPUT")
			check(a.set_conditions({"forecast": fc, "preset": "weather/medium"}) == 1, "прогноз и эталон вместе — BAD_INPUT")
			check(a.set_conditions({"preset": "weather/нет_такого"}) == 1, "неизвестный пресет — BAD_INPUT")
		a.free()


# ------------------------------------------------------------------ порядок команд (W4 v2)


func test_commands_before_place() -> void:
	for impl in IMPLS:
		var a := _make(impl)
		check(a.set_conditions({"preset": _preset()}) == 0, "%s: set_conditions до load_place — OK" % impl)
		a.set_sun_direction(Vector3(0.3, 0.8, 0.5).normalized())
		check(a.set_static_thermals(PackedFloat32Array([0.0, 0.0, 2.0, 100.0]), 1) == 0, "%s: set_static_thermals до load_place — OK" % impl)
		check(a.set_focuses(PackedVector3Array([Vector3(1, 2, 3)]), PackedFloat32Array([1.0])) == 0, "%s: set_focuses до load_place — OK" % impl)
		check(a.set_static_thermals(PackedFloat32Array([1.0, 2.0, 3.0]), 0) == 1, "%s: список не кратен 4 — BAD_INPUT" % impl)
		check(a.set_static_thermals(PackedFloat32Array(), 3) == 1, "%s: mode 3 — BAD_INPUT" % impl)
		check(a.advance_to(-1.0) == 1, "%s: t < 0 — BAD_INPUT" % impl)
		check(a.start_at(NAN) == 1, "%s: start_at(NaN) — BAD_INPUT" % impl)
		var r = a.sample_many(PackedVector3Array([CENTER]))
		check(r.size() == 4 and _all_finite(r), "%s: опрос до места — определённый ответ" % impl)
		if impl == "gd":
			check(a.advance_to(1.0) == 2, "advance_to без места — NO_PLACE")
			check(a.start_at(1.0) == 2, "start_at без места — NO_PLACE")
			check(int(a.status().state) == 0, "до места state = EMPTY")
			check(not a.is_ready(), "до места не готов")
			for v in r:
				check(v == 0.0, "EMPTY — нули")
		else:
			check(a.is_ready(), "CalmAir готов сразу")
		a.free()


func test_reload_and_unload() -> void:
	var a := _up("gd")
	check(a.advance_to(5.0) == 0, "advance_to(5)")
	var pts := _pts_around([30.0])
	var before = a.sample_many(pts)
	check(a.load_place(_synthetic()) == 0, "повторный load_place — OK")
	check(int(a.status().state) == 1, "после повторной загрузки LOADING")
	check(_pump(a), "повторная загрузка дошла до READY")
	check(is_equal_approx(float(a.status().time_s), 0.0), "после load_place time_s = 0")
	check(a.sample_many(pts).size() == before.size(), "после повторной загрузки опросы работают")
	a.unload_place()
	check(int(a.status().state) == 0, "unload_place — EMPTY")
	check(is_equal_approx(float(a.status().time_s), 0.0), "unload_place сбрасывает время")
	for v in a.sample_many(pts):
		check(v == 0.0, "после unload_place нули")
	check(a.advance_to(1.0) == 2, "после unload_place advance_to — NO_PLACE")
	check(a.load_place(_synthetic()) == 0, "загрузка после unload_place")
	check(_pump(a), "и снова READY")
	a.free()
	var c := _make("calm")
	check(c.load_place(_synthetic()) == 0, "CalmAir: load_place")
	c.unload_place()
	check(c.is_ready(), "CalmAir: READY всегда")
	c.free()


# ------------------------------------------------------------------ T5: форматы, оси, ошибки


func test_batch_formats() -> void:
	for impl in IMPLS:
		var a := _up(impl)
		var pts := _pts_around([3.0, 30.0, 300.0])
		var r = a.sample_many(pts)
		check(r.size() == 4 * pts.size(), "%s: длина 4N" % impl)
		check(_all_finite(r), "%s: все числа конечны" % impl)
		for i in pts.size():
			check(r[4 * i + 3] >= 0.0, "%s: σ ≥ 0" % impl)
		var m = a.sample_many(pts, 1)
		check(m.size() == r.size(), "%s: MEAN — длина 4N" % impl)
		check(a.sample_many(PackedVector3Array()).size() == 0, "%s: пустая пачка — пустой массив" % impl)
		check(a.sample_many(PackedVector3Array(), 1).size() == 0, "%s: пустая пачка MEAN" % impl)
		var one: Vector4 = a.sample(pts[2])
		check(one == Vector4(r[8], r[9], r[10], r[11]), "%s: sample = элемент sample_many" % impl)
		var cd = a.cloud_density_many(pts)
		check(cd.size() == pts.size(), "%s: cloud_density_many — N значений" % impl)
		for v in cd:
			check(v >= 0.0 and v <= 1.0, "%s: плотность облака 0..1" % impl)
		var bw = a.background_wind(PackedFloat32Array([1000.0, 2000.0, 3000.0]))
		check(bw.size() == 6 and _all_finite(bw), "%s: background_wind — 2N конечных" % impl)
		check(a.background_wind(PackedFloat32Array()).size() == 0, "%s: пустой background_wind" % impl)
		check(is_finite(a.cloudbase_msl()), "%s: cloudbase_msl конечна" % impl)
		var su: Vector4 = a.sun_state()
		check(su.w >= 0.0 and su.w <= 1.0, "%s: прогрев sun_state 0..1" % impl)
		check(a.weather() is Dictionary, "%s: погода — словарь" % impl)
		a.free()


func test_nonfinite_and_far_points() -> void:
	for impl in IMPLS:
		var a := _up(impl)
		var good := _pts_around([50.0])[0]
		var pts := PackedVector3Array(
			[
				Vector3(NAN, 100.0, 0.0), good, Vector3(0.0, INF, 0.0), Vector3(0.0, 100.0, -INF),
				Vector3(1.0e7, 500.0, -1.0e7), Vector3(-5.0e5, 20000.0, 3.0e5), good,
			]
		)
		var r = a.sample_many(pts)
		check(r.size() == 28, "%s: длина 4N с мусорными точками" % impl)
		check(_all_finite(r), "%s: выход конечен при NaN/inf и далёких точках" % impl)
		for k in [0, 2, 3]:
			for j in 4:
				check(r[4 * k + j] == 0.0, "%s: NaN/inf-точка %d → нули" % [impl, k])
		for j in 4:
			check(r[4 + j] == r[24 + j], "%s: одинаковые точки дают одинаковый ответ" % impl)
		check(_all_finite(a.cloud_density_many(pts)), "%s: плотность облака конечна" % impl)
		check(_all_finite(a.background_wind(PackedFloat32Array([NAN, INF, 1000.0]))), "%s: background_wind конечен" % impl)
		a.free()


## Ветер с севера дует к +Z, с запада — к +X (W1); км/ч → м/с.
func test_axes_and_units() -> void:
	var cases := [[0.0, Vector2(0.0, 1.0)], [270.0, Vector2(1.0, 0.0)], [90.0, Vector2(-1.0, 0.0)]]
	for c: Array in cases:
		var a := _up("gd", _preset(36.0, c[0]))
		var pts := _pts_around([700.0, 1000.0], 400.0)
		var r = a.sample_many(pts, 1)
		var sx := 0.0
		var sz := 0.0
		for i in pts.size():
			sx += r[4 * i]
			sz += r[4 * i + 2]
		sx /= pts.size()
		sz /= pts.size()
		var dir: Vector2 = c[1]
		var along := sx * dir.x + sz * dir.y
		var across := absf(sx * dir.y - sz * dir.x)
		check(along > 3.0, "ветер с %d°: вдоль потока %.2f м/с > 3 (36 км/ч = 10 м/с у земли)" % [c[0], along])
		check(across < 0.5 * along, "ветер с %d°: поперёк %.2f меньше половины вдоль" % [c[0], across])
		var bw = a.background_wind(PackedFloat32Array([2000.0]))
		check(bw[0] * dir.x + bw[1] * dir.y > 3.0, "ветер с %d°: фоновый ветер по оси" % c[0])
		a.free()


func test_mean_mode() -> void:
	var a := _up("gd")
	var pts := _pts_around([3.0, 30.0, 300.0, 1000.0])
	var full = a.sample_many(pts, 0)
	var mean = a.sample_many(pts, 1)
	var mean2 = a.sample_many(pts, 1)
	check(mean == mean2, "MEAN: два опроса на одном t равны")
	var differ := 0
	for i in pts.size():
		check(mean[4 * i + 3] == full[4 * i + 3], "MEAN: σ та же, что у FULL")
		if absf(mean[4 * i] - full[4 * i]) + absf(mean[4 * i + 2] - full[4 * i + 2]) > 1.0e-4:
			differ += 1
	check(differ > 0, "FULL отличается от MEAN (болтанка и порывы есть)")
	var was: bool = a.turbulence_enabled
	a.sample_many(pts, 1)
	check(a.turbulence_enabled == was, "опрос MEAN не оставляет побочных эффектов на turbulence_enabled")
	a.free()


# ------------------------------------------------------------------ T6: время и готовность


func test_polls_equal_and_advance() -> void:
	var a := _up("gd")
	var pts := _pts_around([30.0, 600.0])
	check(a.sample_many(pts) == a.sample_many(pts), "два опроса на одном t равны (FULL)")
	check(a.advance_to(0.0) == 0, "advance_to(t = текущему) — OK")
	check(a.advance_to(2.0) == 0, "advance_to вперёд — OK")
	check(is_equal_approx(float(a.status().time_s), 2.0), "time_s = 2")
	var snap: PackedFloat32Array = a.sample_many(pts)
	check(a.advance_to(1.0) == 1, "advance_to назад — BAD_INPUT")
	check(is_equal_approx(float(a.status().time_s), 2.0), "BAD_INPUT не двигает время")
	check(a.sample_many(pts) == snap, "BAD_INPUT не меняет воздух")
	check(a.advance_to(2.0) == 0, "advance_to(t = текущему) ничего не меняет")
	check(a.sample_many(pts) == snap, "…воздух тот же")
	check(a.advance_to(-1.0) == 1 and a.advance_to(NAN) == 1 and a.advance_to(INF) == 1, "t < 0, NaN, inf — BAD_INPUT")
	for i in 10:
		check(a.advance_to(2.0 + (i + 1) * 0.0166) == 0, "тики вперёд — OK")
	check(_all_finite(a.sample_many(pts)), "после тиков ответ конечен")
	check(a.sample_many(pts) == a.sample_many(pts), "после тиков два опроса равны")
	a.free()
	var c := _up("calm")
	check(c.advance_to(1.0) == 0 and c.advance_to(0.5) == 1, "CalmAir: advance_to только вперёд")
	c.free()


func test_start_at_async_and_determinism() -> void:
	var a := _make("gd")
	check(a.configure(77) == 0, "configure")
	check(a.set_conditions({"preset": _preset()}) == 0, "set_conditions")
	check(a.load_place(_synthetic()) == 0, "load_place возвращает сразу")
	check(int(a.status().state) == 1, "после load_place state = LOADING")
	var pts := _pts_around([30.0, 600.0])
	var early: PackedFloat32Array = a.sample_many(pts)
	check(early.size() == 4 * pts.size() and _all_finite(early), "до READY — определённый конечный ответ")
	check(early == a.sample_many(pts), "до READY два опроса равны")
	check(a.advance_to(1.0) == 3, "advance_to во время загрузки — NOT_READY")
	check(_pump(a), "дошли до READY")
	check(is_equal_approx(float(a.status().time_s), 1.0), "запомненный момент старта применился")
	check(a.start_at(900.0) == 0, "start_at после load_place — OK")
	check(int(a.status().state) in [1, 2], "после start_at LOADING или READY")
	check(_pump(a), "start_at дошёл до READY")
	check(is_equal_approx(float(a.status().time_s), 900.0), "time_s = 900")
	check(a.start_at(NAN) == 1 and a.start_at(-5.0) == 1, "start_at(NaN / отрицательное) — BAD_INPUT")
	var s1: PackedFloat32Array = a.sample_many(pts)
	check(s1 == a.sample_many(pts), "после start_at два опроса равны")
	check(_all_finite(s1), "после start_at ответ конечен")
	# детерминизм W1: тот же вход — тот же выход
	var b := _make("gd")
	b.configure(77)
	b.set_conditions({"preset": _preset()})
	b.load_place(_synthetic())
	_pump(b)
	b.start_at(900.0)
	_pump(b)
	check(b.sample_many(pts) == s1, "детерминизм: два воздуха с одним входом дают одно и то же")
	check(b.sample_many(pts, 1) == a.sample_many(pts, 1), "детерминизм (MEAN)")
	# сид влияет
	var c := _make("gd")
	c.configure(78)
	c.set_conditions({"preset": _preset()})
	c.load_place(_synthetic())
	_pump(c)
	c.start_at(900.0)
	_pump(c)
	check(c.sample_many(pts) != s1, "другой сид — другой воздух")
	a.free()
	b.free()
	c.free()
	var calm := _make("calm")
	check(calm.start_at(10.0) == 0 and is_equal_approx(float(calm.status().time_s), 10.0), "CalmAir: start_at")
	calm.free()


func test_signals() -> void:
	var a := _make("gd")
	var states: Array[int] = []
	var rebuilt := [0]
	a.state_changed.connect(func(s: int) -> void: states.append(s))
	a.weather_changed.connect(func() -> void: rebuilt[0] += 1)
	a.configure(5)
	a.set_conditions({"preset": _preset()})
	a.load_place(_synthetic())
	_pump(a)
	check(states == [1, 2], "state_changed: LOADING, READY (получено %s)" % [states])
	check(rebuilt[0] >= 1, "weather_changed при сборке воздуха места")
	a.unload_place()
	check(states.back() == 0, "unload_place — state_changed(EMPTY)")
	a.free()


func test_conditions_soft_and_rebuild() -> void:
	var a := _up("gd")
	var updated := [0]
	a.weather_updated.connect(func() -> void: updated[0] += 1)
	var changed := [0]
	a.weather_changed.connect(func() -> void: changed[0] += 1)
	check(a.set_conditions({"preset": _preset(20.0, 200.0), "blend_s": 10.0}) == 0, "мягкая смена погоды — OK")
	check(updated[0] >= 1, "мягкая смена шлёт weather_updated")
	check(int(a.status().state) == 2, "мягкая смена не уводит в LOADING")
	check(a.set_conditions({"preset": _preset(20.0, 200.0), "rebuild": true}) == 0, "rebuild — OK")
	check(int(a.status().state) == 1, "rebuild — LOADING")
	check(_pump(a), "после rebuild снова READY")
	check(changed[0] >= 1, "rebuild шлёт weather_changed")
	var fc := {"temperature_c": 24.0, "wind_speed_kmh": 12.0, "wind_from_deg": 250.0, "sky": "clear"}
	check(a.set_conditions({"forecast": fc, "start_hour": 12.0, "speed": 1.0, "rebuild": true}) == 0, "прогноз с перестройкой — OK")
	check(_pump(a), "прогноз: READY")
	check(_all_finite(a.sample_many(_pts_around([30.0]))), "прогноз: ответ конечен")
	check(a.advance_to(120.0) == 0, "прогноз: ход дня идёт при advance_to")
	check(_all_finite(a.sample_many(_pts_around([30.0]))), "прогноз после хода времени: ответ конечен")
	a.free()


# ------------------------------------------------------------------ фокусы


func test_focuses() -> void:
	var a := _up("gd")
	var p0 := _pts_around([100.0])[0]
	check(a.set_focuses(PackedVector3Array([p0, p0 + Vector3(900, 0, 0)]), PackedFloat32Array([1.0, 0.5])) == 0, "два фокуса — OK")
	check(a.set_focuses(PackedVector3Array([p0]), PackedFloat32Array([1.0, 0.5])) == 1, "размеры различаются — BAD_INPUT")
	check(a.set_focuses(PackedVector3Array([p0]), PackedFloat32Array([0.0])) == 1, "вес 0 — BAD_INPUT")
	check(a.set_focuses(PackedVector3Array([p0]), PackedFloat32Array([-1.0])) == 1, "вес < 0 — BAD_INPUT")
	check(a.set_focuses(PackedVector3Array([Vector3(NAN, 0, 0)]), PackedFloat32Array([1.0])) == 1, "точка NaN — BAD_INPUT")
	check(a.set_focuses(PackedVector3Array(), PackedFloat32Array()) == 0, "пусто — OK (фокус в (0, 0) места)")
	check(a.start_at(300.0) == 0, "start_at с фокусами")
	check(_pump(a), "READY с фокусами")
	check(a.set_focuses(PackedVector3Array([p0, p0 + Vector3(5000, 0, 0), p0 - Vector3(0, 0, 5000)]), PackedFloat32Array([1.0, 1.0, 0.2])) == 0, "три фокуса")
	check(a.advance_to(301.0) == 0, "advance_to с тремя фокусами")
	check(_all_finite(a.sample_many(_pts_around([30.0]))), "ответ конечен")
	a.free()


# ------------------------------------------------------------------ описания W6


func test_descriptions_format() -> void:
	var a := _up("gd", _preset(14.0, 230.0))
	check(a.set_static_thermals(PackedFloat32Array([CENTER.x + 700.0, CENTER.z + 300.0, 2.5, 120.0]), 2) == 0, "статический термик")
	check(a.start_at(60.0) == 0, "start_at")
	check(_pump(a), "READY")
	var cores: PackedFloat32Array = a.cores(CENTER, 8000.0)
	var clouds: PackedFloat32Array = a.clouds(CENTER, 8000.0)
	var crests: PackedFloat32Array = a.wave_crests(Vector2(CENTER.x, CENTER.z), 8000.0, 50.0)
	check(cores.size() % Atmosphere.CORE_STRIDE == 0 and cores.size() > 0, "ядра кратны %d и есть (%d)" % [Atmosphere.CORE_STRIDE, cores.size()])
	check(clouds.size() % Atmosphere.CLOUD_STRIDE == 0, "облака кратны %d" % Atmosphere.CLOUD_STRIDE)
	check(crests.size() % Atmosphere.CREST_STRIDE == 0, "гребни кратны %d" % Atmosphere.CREST_STRIDE)
	var statics := 0
	for j in range(0, cores.size(), Atmosphere.CORE_STRIDE):
		var id := cores[j + Atmosphere.CORE_ID]
		check(id >= 0.0 and id < 16777216.0 and id == floorf(id), "id ядра — целое в [0, 2^24)")
		var flags := int(cores[j + Atmosphere.CORE_FLAGS])
		if flags & 1:
			statics += 1
		check(cores[j + Atmosphere.CORE_TOP] > cores[j + Atmosphere.CORE_Y_SRC], "верх выше источника")
		check(cores[j + Atmosphere.CORE_RADIUS] > 0.0, "радиус ядра > 0")
		var st := cores[j + Atmosphere.CORE_STAGE]
		check(st >= 0.0 and st <= 3.0, "stage 0..3")
		for k in Atmosphere.CORE_STRIDE:
			if k != Atmosphere.CORE_LIFE:
				check(is_finite(cores[j + k]), "поле ядра %d конечно" % k)
	check(statics >= 1, "статический термик виден среди ядер (флаг бит 0)")
	var small: PackedFloat32Array = a.cores(CENTER, 1.0)
	check(small.size() <= cores.size(), "меньший радиус — не больше ядер")
	var r: Dictionary = a.cloud_raster()
	check(r.has("version"), "cloud_raster — словарь с version")
	check(int(r.version) == a.cloud_raster_version(), "версия растра = cloud_raster_version()")
	if int(r.version) > 0:
		var n := int(r.nx) * int(r.ny)
		for k in ["cover", "depth", "stage", "activity", "bg_cover", "bg_depth"]:
			check((r[k] as PackedFloat32Array).size() == n, "слой %s — nx·ny" % k)
	a.free()
	var c := _up("calm")
	check(c.cores(CENTER, 5000.0).size() == 0 and c.clouds(CENTER, 5000.0).size() == 0, "CalmAir: описаний нет")
	check(int(c.cloud_raster().version) == 0, "CalmAir: растр облаков {version: 0}")
	c.free()


## Найденное ядро — местный избыток подъёма (W6 v3): у ядра без Cb и с w ≥ 1,5 м/с средний vy в
## круге 0,5·r на высоте (y_src + top)/2 больше, чем в кольце 2–3·r. Проверяются ВСЕ такие ядра,
## на нескольких моментах и двух погодах.
func test_found_core_is_a_local_updraft() -> void:
	var checked := 0
	for preset in [_preset(14.0, 230.0), _preset(32.0, 300.0)]:
		var a = _up("gd", preset)
		for t in [0.0, 900.0, 3600.0]:
			check(a.start_at(t) == 0, "start_at(%d)" % int(t))
			check(_pump(a), "READY на t = %d" % int(t))
			var cores: PackedFloat32Array = a.cores(CENTER, 8000.0)
			for j in range(0, cores.size(), Atmosphere.CORE_STRIDE):
				if (int(cores[j + Atmosphere.CORE_FLAGS]) & 4) != 0 or cores[j + Atmosphere.CORE_W] < 1.5:
					continue
				var row := cores.slice(j, j + Atmosphere.CORE_STRIDE)
				var y := 0.5 * (row[Atmosphere.CORE_Y_SRC] + row[Atmosphere.CORE_TOP])
				var ax := row[Atmosphere.CORE_X] + row[Atmosphere.CORE_LEAN_X] * (y - row[Atmosphere.CORE_Y_SRC])
				var az := row[Atmosphere.CORE_Z] + row[Atmosphere.CORE_LEAN_Z] * (y - row[Atmosphere.CORE_Y_SRC])
				var rad := row[Atmosphere.CORE_RADIUS]
				var inner := PackedVector3Array([Vector3(ax, y, az)])
				for rr in [0.25, 0.5]:
					for k in 8:
						var an := TAU * k / 8.0
						inner.append(Vector3(ax + cos(an) * rr * rad, y, az + sin(an) * rr * rad))
				var outer := PackedVector3Array()
				for rr in [2.0, 2.5, 3.0]:
					for k in 16:
						var an := TAU * (k + 0.5) / 16.0
						outer.append(Vector3(ax + cos(an) * rr * rad, y, az + sin(an) * rr * rad))
				var vi := _mean_vy(a.sample_many(inner, 1))
				var vo := _mean_vy(a.sample_many(outer, 1))
				checked += 1
				check(vi > vo, "t=%d, ядро %d (w %.2f): средний vy в круге %.2f ≤ в кольце %.2f" % [int(t), int(row[0]), row[Atmosphere.CORE_W], vi, vo])
		a.free()
	check(checked >= 10, "проверено ядер без Cb с w ≥ 1,5: %d (нужно ≥ 10)" % checked)


static func _mean_vy(r: PackedFloat32Array) -> float:
	var s := 0.0
	for i in r.size() / 4:
		s += r[4 * i + 1]
	return s / maxf(r.size() / 4, 1)


# ------------------------------------------------------------------ W7


func test_decompose() -> void:
	var a := _up("gd")
	check(a.advance_to(30.0) == 0, "advance_to")
	var pts := _pts_around([3.0, 50.0, 400.0, 1500.0])
	pts.append(Vector3(CENTER.x, 6000.0, CENTER.z))
	for p in pts:
		var d: Dictionary = a.decompose(p)
		for k in ["names", "vel", "sigma", "total"]:
			check(d.has(k), "decompose: ключ %s" % k)
		var names: PackedStringArray = d.names
		var vel: PackedVector3Array = d.vel
		var sg: PackedFloat32Array = d.sigma
		check(names.size() == vel.size() and vel.size() == sg.size() and names.size() > 0, "names, vel, sigma одной длины")
		var sum := Vector3.ZERO
		for v in vel:
			sum += v
		var tot: Vector4 = d.total
		check((sum - Vector3(tot.x, tot.y, tot.z)).length() <= 1.0e-4, "Σ vel = total.xyz: %s против %s" % [sum, tot])
		check(tot == a.sample(p), "total = sample(pos) побитно")
		for s in sg:
			check(s >= 0.0 and is_finite(s), "sigma[i] ≥ 0")
	var bad: Dictionary = a.decompose(Vector3(NAN, 0, 0))
	check((bad.total as Vector4) == Vector4(), "decompose(NaN): total — нули")
	a.free()


## CalmAir несёт тот же набор методов W2, что Atmosphere (в т. ч. обёртки).
func test_calm_has_facade_methods() -> void:
	var methods: Array[String] = [
		"configure", "load_place", "unload_place", "set_conditions", "set_sun_direction",
		"set_static_thermals", "advance_to", "start_at", "pump", "status", "is_ready", "set_focuses",
		"sample_many", "sample", "air_velocity_at", "mean_wind_at", "turbulence_intensity_at",
		"thermals_near", "cloud_density_many", "cloud_density_at", "cloudbase_msl",
		"get_cloudbase_msl", "background_wind", "weather", "sun_state", "cores", "clouds",
		"cloud_raster", "cloud_raster_version", "wave_crests", "decompose", "debug_raster",
		"debug_raster_names", "last_error",
	]
	for impl in IMPLS:
		var a := _make(impl)
		for m in methods:
			check(a.has_method(m), "%s: есть метод %s" % [impl, m])
		a.free()
	var c := _up("calm")
	var p := Vector3(100.0, 500.0, 100.0)
	check(c.turbulence_intensity_at(p) == 0.0, "CalmAir: turbulence_intensity_at = 0")
	check(c.thermals_near(p, 1000.0).is_empty(), "CalmAir: thermals_near пусто")
	check(c.cloud_density_at(p) == 0.0, "CalmAir: cloud_density_at = 0")
	check(c.get_cloudbase_msl() == c.cloudbase_msl(), "CalmAir: get_cloudbase_msl = cloudbase_msl()")
	c.free()


func test_debug_rasters() -> void:
	var a := _up("gd")
	var names: PackedStringArray = a.debug_raster_names()
	for n in names:
		var r: Dictionary = a.debug_raster(n)
		for k in ["nx", "ny", "dx", "x0", "z0", "data"]:
			check(r.has(k), "debug_raster %s: ключ %s" % [n, k])
		if r.has("data"):
			check((r.data as PackedFloat32Array).size() == int(r.nx) * int(r.ny), "debug_raster %s: nx·ny" % n)
	check(a.debug_raster("нет_такого").is_empty(), "неизвестное имя — {}")
	a.free()
	var c := _make("calm")
	check(c.debug_raster_names().size() == 0 and c.debug_raster("x").is_empty(), "CalmAir: отладочных растров нет")
	c.free()
