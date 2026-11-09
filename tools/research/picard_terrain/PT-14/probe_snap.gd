extends TestCase
## PT-14: копия test_air_field_import с печатью разностей по точкам (probe_snap).
## AirFieldImport.load_bytes (снимок поля крейта: DpAir.field_export_header / field_export_data):
## уровни снимка собираются без запечённого файла, отсчёт по ним равен слагаемому field крейта.
## Место — плоское синтетическое, область поля уменьшена: расчёт Пикара короткий.
## godot --headless --path . res://tests/run_tests.tscn -- --filter=field_import

const TOL := 1.0e-4
const SKIP_NO_EXT := "нет расширения DpAir (tools/build_rust.sh tune linux)"


func skip_reason(_method: String) -> String:
	return "" if ClassDB.class_exists("DpAir") else SKIP_NO_EXT


func _place() -> AirPlaceData:
	var loc := {
		"id": "t",
		"center_lat": 51.5,
		"center_lon": 86.5,
		"utc_offset_h": 6.0,
		"month": 7,
		"day": 15
	}
	return AirPlaceData.from_functions(
		func(_x: float, _z: float) -> float: return 500.0,
		func(_x: float, _z: float) -> float: return 0.8,
		loc,
		-3000.0,
		-3000.0,
		25.0,
		241,
		241
	)


func _facade() -> Atmosphere:
	var a := Atmosphere.new()
	a.visuals_enabled = false
	a.deterministic = true
	var small: Dictionary = Config.get_config("atmosphere").duplicate(true)
	small.air.domain_l_m = 9600.0
	a.cfg_override = small
	check(a.configure(5) == 0, "configure")
	check(
		(
			a.set_conditions(
				{
					"forecast":
					{
						"temperature_c": 26.0,
						"wind_speed_kmh": 14.0,
						"wind_from_deg": 270.0,
						"sky": "clear"
					},
					"start_hour": 12.0,
					"speed": 1.0,
					"quantum_h": 1.0,
				}
			)
			== 0
		),
		"set_conditions"
	)
	check(a.load_place(_place()) == 0, "load_place " + a.last_error())
	check(
		a.set_focuses(PackedVector3Array([Vector3(0, 600, 0)]), PackedFloat32Array([1.0])) == 0,
		"set_focuses"
	)
	check(a.start_at(0.0) in [0, 3], "start_at")
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 600000 and not a.is_ready():
		a.pump(8000)
		OS.delay_msec(2)
	return a


## Снимок крейта → load_bytes: уровни собраны, отсчёт уровней = слагаемое field крейта.
func test_load_bytes_of_crate_snapshot() -> void:
	var a := _facade()
	check(a.is_ready(), "READY: %s" % str(a.status().get("reason", "")))
	var dp: RefCounted = a.get("_dp")
	check(dp.field_export() >= 0, "field_export")
	var head: Variant = JSON.parse_string(String(dp.field_export_header()))
	check(head is Dictionary, "заголовок снимка — JSON-словарь")
	if not head is Dictionary:
		a.free()
		return
	var fs: AirFieldSet = AirFieldImport.load_bytes(head, dp.field_export_data(), "тест")
	check(fs != null, "load_bytes собрал набор уровней")
	if fs == null:
		a.free()
		return
	var lv: Array[WindField] = fs.levels
	check(
		lv.size() == (head.levels as Array).size() and lv.size() >= 1,
		"уровней как в заголовке: %d" % lv.size()
	)
	# точки внутри каждого уровня (центральные 60 %), 30..600 м над землёй (500 м)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var pts := PackedVector3Array()
	for i in 30:
		var f: WindField = lv[i % lv.size()]
		var c := f.center_xz()
		pts.append(
			Vector3(
				c.x + rng.randf_range(-0.3, 0.3) * f.size_x(),
				500.0 + rng.randf_range(30.0, 600.0),
				c.y + rng.randf_range(-0.3, 0.3) * f.ny * f.dx
			)
		)
	print("PROBE " + JSON.stringify({"tag": "snap.head", "levels": head.levels, "keys": head.keys()}))
	var nonzero := 0
	var worst := 0.0
	var names: PackedStringArray = dp.decompose_names()
	var fi := names.find("field")
	check(fi >= 0, "слагаемое field в разложении крейта")
	for pt in pts:
		var want: Vector3 = ((a.decompose(pt) as Dictionary).vel as PackedVector3Array)[fi]
		var got := fs.sample(pt, 500.0)
		if want.length() > 1.0e-3:
			nonzero += 1
		worst = maxf(worst, (Vector3(got.x, got.y, got.z) - want).length())
		print("PROBE " + JSON.stringify({"tag": "snap.pt", "agl": pt.y - 500.0, "x": pt.x, "z": pt.z, "want": [want.x, want.y, want.z], "got": [got.x, got.y, got.z], "d": (Vector3(got.x, got.y, got.z) - want).length()}))
	check(nonzero >= 20, "поле ненулевое в точках: %d из 30" % nonzero)
	check(worst <= TOL, "уровни снимка = слагаемое field крейта: max |Δ| = %s м/с" % worst)
	a.free()
