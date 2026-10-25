extends TestCase
## Расширение DpAir (W3, RW-4b): класс gdext поверх Calm. Нет бинарника (свежая копия, CI) —
## тесты пропускаются с сообщением. Сборка: tools/build_rust.sh tune linux.

const HEADER := (
	'{"version":1,"loc":{"id":"t","center_lat":50.0,"center_lon":86.0,"utc_offset_h":7.0,'
	+ '"month":7,"day":1},"grid":{"origin_x":-100,"origin_z":-100,"spacing":50,"width":4,'
	+ '"height":4},"surface_classes":{"grass":1},"start_sites":[]}'
)


func skip_reason(_method: String) -> String:
	if ClassDB.class_exists("DpAir"):
		return ""
	return "нет расширения DpAir (tools/build_rust.sh tune linux)"


func _new() -> Object:
	return ClassDB.instantiate("DpAir")


func _load(a: Object) -> int:
	var n := 16
	var water := PackedByteArray()
	water.resize(n)
	var cls := PackedByteArray()
	cls.resize(n)
	cls.fill(1)
	var h := PackedFloat32Array()
	h.resize(n)
	var m := PackedFloat32Array()
	m.resize(n)
	return a.load_place(HEADER, h, water, cls, m)


func test_api_version_and_constants() -> void:
	var a := _new()
	check(a.api_version() == 1, "api_version")
	check(a.get_class() == "DpAir", "class")
	check(a.state() == 0, "EMPTY")
	var c := 0
	c += ClassDB.class_get_integer_constant("DpAir", "CORE_STRIDE")
	c += ClassDB.class_get_integer_constant("DpAir", "CLOUD_STRIDE")
	c += ClassDB.class_get_integer_constant("DpAir", "CREST_STRIDE")
	check(c == 29, "strides 15+10+4")
	check(ClassDB.class_get_integer_constant("DpAir", "STATE_READY") == 2, "STATE_READY")


func test_load_and_sample_lengths() -> void:
	var a := _new()
	check(a.configure(PackedStringArray(["atmosphere", "{}"]), 1) == 0, "configure")
	check(_load(a) == 0, "load_place " + a.last_error())
	check(a.state() == 2, "READY на Calm")
	var pts := PackedVector3Array([Vector3(0, 100, 0), Vector3(10, 50, -10), Vector3(1, 1, 1)])
	var out: PackedFloat32Array = a.sample_many(pts, 0)
	check(out.size() == 12, "4N")
	for v in out:
		check(is_finite(v) and v == 0.0, "Calm: ветер 0")
	check(a.sample_many(PackedVector3Array(), 0).size() == 0, "пустая пачка")
	check(a.sample(Vector3(0, 100, 0), 1) == Vector4.ZERO, "sample")
	check(a.cloud_density_many(pts).size() == 3, "cloud_density N")
	check(a.background_wind(PackedFloat32Array([10.0, 500.0])).size() == 4, "background 2N")
	check(a.cores(Vector3.ZERO, 1000.0).size() == 0, "нет ядер")
	check(a.clouds(Vector3.ZERO, 1000.0).size() == 0, "нет облаков")
	check(a.wave_crests(Vector2.ZERO, 1000.0, 0.0, 10.0).size() == 0, "нет гребней")
	check(a.cloud_raster_header() == '{"version":0}', "нет растра")
	check(a.decompose(Vector3.ZERO).size() == 4, "decompose: total")


func test_codes_and_bad_input() -> void:
	var a := _new()
	check(a.advance_to(1.0) == 2, "NO_PLACE до места")
	check(a.load_place("{bad", PackedFloat32Array(), PackedByteArray(), PackedByteArray(),
			PackedFloat32Array()) == 1, "BAD_INPUT: заголовок")
	check(a.last_error() != "", "last_error")
	check(_load(a) == 0, "load")
	check(a.advance_to(5.0) == 0 and a.time_s() == 5.0, "advance_to")
	check(a.advance_to(4.0) == 1, "назад — BAD_INPUT")
	check(a.advance_to(NAN) == 1, "NaN — BAD_INPUT")
	check(a.set_static_thermals(PackedFloat32Array([1, 2, 3]), 0) == 1, "длина не кратна 4")
	check(a.set_focuses(PackedVector3Array([Vector3.ZERO]), PackedFloat32Array()) == 1, "размеры")
	var bad := PackedVector3Array([Vector3(NAN, 0, 0), Vector3(0, INF, 0)])
	var out: PackedFloat32Array = a.sample_many(bad, 0)
	check(out.size() == 8, "NaN-точки: длина сохраняется")
	for v in out:
		check(is_finite(v), "конечный ответ")
	a.unload_place()
	check(a.state() == 0, "EMPTY после unload")


func test_unload_during_use_is_fast() -> void:
	var t0 := Time.get_ticks_msec()
	var a := _new()
	_load(a)
	a.unload_place()
	a = null
	check(Time.get_ticks_msec() - t0 < 1000, "выгрузка ≤ 1 с")
