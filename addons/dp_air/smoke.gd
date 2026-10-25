extends Node
## Дымовой тест поставки DpAir (W9): запускается экспортированной сборкой headless
## сценой smoke.tscn (tools/dp_air_smoke.sh; `-s` и путь сцены в релизном шаблоне не работают): расширение загрузилось, Calm отвечает. Печатает DP_AIR_SMOKE OK, exit 0.
## «Ветер ≠ 0» добавит RW-6 (на Calm ветер 0).

const HEADER := (
	'{"version":1,"loc":{"id":"smoke","center_lat":50.0,"center_lon":86.0,"utc_offset_h":7.0,'
	+ '"month":7,"day":1},"grid":{"origin_x":-100,"origin_z":-100,"spacing":50,"width":4,'
	+ '"height":4},"surface_classes":{"grass":1},"start_sites":[]}'
)


func _fail(msg: String) -> void:
	printerr("DP_AIR_SMOKE FAIL: " + msg)
	get_tree().quit(1)


func _ready() -> void:
	if not ClassDB.class_exists("DpAir"):
		_fail("класс DpAir не найден (расширение не загрузилось)")
		return
	var a: Object = ClassDB.instantiate("DpAir")
	if a.api_version() != 1:
		_fail("api_version = %s" % a.api_version())
		return
	var n := 16
	var water := PackedByteArray()
	water.resize(n)
	var cls := PackedByteArray()
	cls.resize(n)
	var h := PackedFloat32Array()
	h.resize(n)
	var m := PackedFloat32Array()
	m.resize(n)
	var rc: int = a.load_place(HEADER, h, water, cls, m)
	if rc != 0 or a.state() != 2:
		_fail("load_place rc=%s state=%s: %s" % [rc, a.state(), a.last_error()])
		return
	var out: PackedFloat32Array = a.sample_many(PackedVector3Array([Vector3(0, 100, 0)]), 0)
	if out.size() != 4:
		_fail("sample_many длина %s, ожидалось 4" % out.size())
		return
	print("DP_AIR_SMOKE OK")
	get_tree().quit(0)
