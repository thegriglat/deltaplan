extends TestCase
## RW-7b: фасад ведёт поле Пикара через DpAir (W3 v4) и подаёт его снимок в свой AirFieldSet для
## слагаемых на GDScript. Быстро и без расчёта Пикара: место — учебный остров (плоское, как в
## rust/dp-air/tests/acceptance.rs), поле старта thermal_plain — запечённое (data/locations/
## training_island/air). Нет расширения DpAir (свежая копия, CI) — пропуск.
## godot --headless --path . res://tests/run_tests.tscn -- --filter=test_rw7_field

const LOC := "training_island"
const SITE := "thermal_plain"
const TOL := 1.0e-4
const SKIP_NO_EXT := "нет расширения DpAir (tools/build_rust.sh tune linux)"


func skip_reason(_method: String) -> String:
	if not ClassDB.class_exists("DpAir"):
		return SKIP_NO_EXT
	if not FileAccess.file_exists(AirBakedField.path_of(LOC, SITE)):
		return "нет запечённого поля %s/%s" % [LOC, SITE]
	return ""


## Заголовок запечённого файла: key (центр, старт, набор погоды, хеш данных) и model_hash.
func _baked_header() -> Dictionary:
	return AirBakedField.read_header(AirBakedField.path_of(LOC, SITE))


## Место учебного острова: плоское 40 км (слой detail 25 м), площадка старта — из key файла.
func _place(h: Dictionary) -> AirPlaceData:
	var key: Dictionary = h.key
	var w: Dictionary = key.weather
	var n := 1601 * 1601
	var heights := PackedFloat32Array()
	heights.resize(n)
	heights.fill(100.0)
	var water := PackedByteArray()
	water.resize(n)
	var cls := PackedByteArray()
	cls.resize(n)
	cls.fill(SurfaceLayer.GRASS)
	var moist := PackedFloat32Array()
	moist.resize(n)
	moist.fill(0.5)
	var loc := {
		"id": LOC,
		"center_lat": float(key.center[0]),
		"center_lon": float(key.center[1]),
		"utc_offset_h": 2.0,
		"month": int(w.month),
		"day": int(w.day),
	}
	var grid := {
		"origin_x": -20000.0, "origin_z": -20000.0, "spacing": 25.0, "width": 1601, "height": 1601
	}
	var sites := [
		{
			"id": SITE,
			"x": float(key.start[0]),
			"z": float(key.start[1]),
			"h_msl": 100.0,
			"weather": w,
		}
	]
	var p := AirPlaceData.from_arrays(
		AirPlaceData.make_header(loc, grid, sites), heights, water, cls, moist
	)
	# хеши как в файле: данные острова на диске и модель могут отличаться от тех, что запекали
	p.header["data_hash"] = String(key.data_hash)
	p.header["model_hash"] = String(h.model_hash)
	p.fill_climate()
	p.fill_crate_inputs()
	return p


## Условия набора погоды файла (AirBakedField.conditions_of): час, ветер, температура, небо.
func _cond(h: Dictionary, hour_shift: float = 0.0, blend_s: Variant = null) -> Dictionary:
	var w: Dictionary = h.key.weather
	return {
		"forecast":
		{
			"temperature_c": float(w.temperature_c),
			"wind_speed_kmh": float(w.wind_speed_ms) * 3.6,
			"wind_from_deg": float(w.wind_from_deg),
			"sky": String(w.sky),
		},
		"start_hour": float(w.start_hour) + hour_shift,
		"speed": 1.0,
		"quantum_h": 0.5,
		"blend_s": blend_s,
		"rebuild": false,
		"inflow_mode": "start",
	}


func _focus(h: Dictionary) -> PackedVector3Array:
	return PackedVector3Array([Vector3(float(h.key.start[0]), 110.0, float(h.key.start[1]))])


## Фасад с местом острова до READY. deterministic — подача поля синхронно.
func _facade(h: Dictionary, det := true) -> Atmosphere:
	var a := Atmosphere.new()
	a.visuals_enabled = false
	a.deterministic = det
	check(a.configure(5) == 0, "configure")
	check(a.set_conditions(_cond(h)) == 0, "set_conditions")
	check(a.load_place(_place(h)) == 0, "load_place " + a.last_error())
	check(a.set_focuses(_focus(h), PackedFloat32Array([1.0])) == 0, "set_focuses")
	check(a.start_at(0.0) in [0, 3], "start_at")
	for i in 6000:
		if a.is_ready():
			break
		a.pump(8000)
		OS.delay_msec(2)
	return a


## Точки внутри уровней поля (центральные 60 %), n штук; высоты 30..1500 м над землёй (100 м).
func _points(a: Atmosphere, n: int) -> PackedVector3Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var out := PackedVector3Array()
	var lv: Array[WindField] = a.air_field.levels
	for i in n:
		var f: WindField = lv[i % lv.size()]
		var c := f.center_xz()
		var hx := 0.3 * f.size_x()
		var hz := 0.3 * f.ny * f.dx
		out.append(
			Vector3(
				c.x + rng.randf_range(-hx, hx),
				100.0 + rng.randf_range(30.0, 1500.0),
				c.y + rng.randf_range(-hz, hz)
			)
		)
	return out


func _field_of(a: Atmosphere, p: Vector3) -> Vector3:
	var d: Dictionary = a.decompose(p)
	var i: int = (d.names as PackedStringArray).find("field")
	return (d.vel as PackedVector3Array)[i] if i >= 0 else Vector3.ZERO


func _max_diff(a: Atmosphere, pts: PackedVector3Array) -> float:
	var dp: RefCounted = a.get("_dp")
	var ref: PackedFloat32Array = dp.sample_many(pts, 1)
	var worst := 0.0
	for i in pts.size():
		var v := Vector3(ref[4 * i], ref[4 * i + 1], ref[4 * i + 2])
		worst = maxf(worst, (_field_of(a, pts[i]) - v).length())
	return worst


## (1) Слагаемое field фасада в 50 точках области и окон равно DpAir.sample_many(MEAN) (1e-4 м/с).
func test_field_term_equals_crate_sample() -> void:
	var h := _baked_header()
	var a := _facade(h)
	check(a.is_ready(), "READY")
	check(bool(a.status().field_on), "field_on после READY")
	check(a.air_field.levels.size() == 3, "уровней 3 (область и окна), есть %d" % a.air_field.levels.size())
	var pts := _points(a, 50)
	var nonzero := 0
	for p in pts:
		if _field_of(a, p).length() > 1.0e-3:
			nonzero += 1
	check(nonzero >= 40, "поле ненулевое в точках: %d из 50" % nonzero)
	var worst := _max_diff(a, pts)
	print("    max |field фасада − DpAir.sample_many(MEAN)| = %s м/с в 50 точках" % worst)
	check(worst <= TOL, "field фасада = DpAir.sample_many(MEAN): max |Δ| = %s м/с" % worst)
	a.free()


## (2) У фасада нет AirRuntime: ни дочернего узла, ни поля.
func test_no_air_runtime_in_facade() -> void:
	var h := _baked_header()
	var a := _facade(h)
	for c in a.get_children():
		check(not c is AirRuntime, "дочерний AirRuntime: " + c.name)
	check(a.get("runtime") == null, "поля runtime нет")
	a.free()


## (3) Смена условий (rebuild: false, другой час в пределах допуска набора погоды) — новый номер
## подачи; подмена за blend_s: доля нового поля растёт и приходит к 1.
func test_condition_change_blends_over_blend_s() -> void:
	var h := _baked_header()
	var a := _facade(h)
	var dp: RefCounted = a.get("_dp")
	var v0: int = dp.field_version()
	check(v0 > 0, "после загрузки поле подано (номер %d)" % v0)
	check(a.air_field.blend_fraction() == 1.0, "после загрузки подмены нет")
	var blend := 40.0
	check(a.set_conditions(_cond(h, 0.5, blend)) == 0, "set_conditions: другой час (+0,5 ч)")
	check(a.advance_to(1.0) == 0, "advance_to")
	var v1: int = dp.field_version()
	check(v1 != v0, "новый номер подачи: %d → %d" % [v0, v1])
	var f0: float = a.air_field.blend_fraction()
	check(f0 < 1.0, "подмена началась: доля нового %s" % f0)
	var last := f0
	var grew := false
	for i in 8:
		a.advance_to(a.time_s + blend / 8.0 * 0.9)
		var f: float = a.air_field.blend_fraction()
		check(f >= last - 1.0e-6, "доля нового монотонна: %s → %s" % [last, f])
		grew = grew or f > last + 1.0e-4
		last = f
	check(grew, "доля нового растёт")
	a.advance_to(a.time_s + blend)
	approx(a.air_field.blend_fraction(), 1.0, 1.0e-6, "после blend_s подмена кончилась")
	check(a.is_ready(), "READY")
	a.free()


## Игровой режим (deterministic = false): уровни снимка собираются в фоне, READY приходит с полем;
## главный поток уровни не ждёт, итог тот же, что в синхронном режиме.
func test_background_feed_gives_the_same_field() -> void:
	var h := _baked_header()
	var a := _facade(h, false)
	check(a.is_ready(), "READY")
	# уровни снимка собираются в фоне: до 3 с на подачу после READY (RW-P7: пробой — без неё 0 уровней)
	for i in 1500:
		if a.air_field.levels.size() == 3:
			break
		a.pump(4000)
		OS.delay_msec(2)
	check(bool(a.status().field_on), "field_on после READY (подача в фоне закончена)")
	check(a.air_field.levels.size() == 3, "уровней 3, есть %d" % a.air_field.levels.size())
	var worst := _max_diff(a, _points(a, 30))
	check(worst <= TOL, "field фасада = DpAir.sample_many(MEAN): max |Δ| = %s м/с" % worst)
	a.free()
