extends Node
## Дымовой тест поставки DpAir (W9): запускается экспортированной сборкой headless сценой
## smoke.tscn (tools/dp_air_smoke.sh; `-s` и путь сцены в релизном шаблоне не работают).
## Проверяет то, что нужно игре в полёте: расширение загрузилось, api_version = WIND_API_VERSION фасада (6), конфиги из
## pck принимаются, поле Пикара (с API 5 считается всегда, режима нет) на плоском месте
## доходит до READY, поле подано (field_version > 0, снимок не пуст), ветер у земли ≠ 0.
## Стадии печатаются строкой на смену этапа. Печатает DP_AIR_SMOKE OK, exit 0.

## Ожидаемая версия API — одно место в GD: константа фасада W2 (scripts/atmosphere/atmosphere.gd).
const API_VERSION := Atmosphere.WIND_API_VERSION
const TIMEOUT_S := 240.0
const CONFIGS := ["atmosphere", "weather_model", "surface_heat", "world"]
## Плоское место 10 × 10 км, клетка 25 м; площадка в центре.
const HEADER := (
	'{"version":1,"loc":{"id":"smoke","center_lat":50.0,"center_lon":86.0,"utc_offset_h":7.0,'
	+ '"month":7,"day":1},"grid":{"origin_x":-5000,"origin_z":-5000,"spacing":25,"width":400,'
	+ '"height":400},"surface_classes":{"grass":1},'
	+ '"start_sites":[{"x":0,"z":0,"h_msl":100.0}]}'
)
const COND := (
	'{"forecast":{"temperature_c":22,"wind_speed_kmh":14.4,"wind_from_deg":270,"sky":"clear"},'
	+ '"start_hour":12,"speed":1,"quantum_h":1,"blend_s":null,"rebuild":false}'
)

var _dp: Object
var _t0 := 0.0
var _stage_last := ""


func _fail(msg: String) -> void:
	printerr("DP_AIR_SMOKE FAIL: " + msg)
	set_process(false)
	get_tree().quit(1)


## Конфиги крейта из pck (res://configs); малая область и детерминизм — чтобы счёт был быстрым.
func _configs() -> PackedStringArray:
	var out := PackedStringArray()
	for n: String in CONFIGS:
		var path := "res://configs/%s.json" % n
		if not FileAccess.file_exists(path):
			return PackedStringArray()
		var text := FileAccess.get_file_as_string(path)
		if n == "atmosphere":
			var v: Variant = JSON.parse_string(text)
			if not v is Dictionary:
				return PackedStringArray()
			v["air"]["deterministic"] = true
			v["air"]["domain_l_m"] = 7200.0
			v["air"]["tol_scale"] = 5.0
			v["air_model"]["edge_blend_cells"] = 1.0
			text = JSON.stringify(v)
		out.append(n)
		out.append(text)
	var d := DirAccess.open("res://configs/weather")
	if d == null:
		return PackedStringArray()
	for f in d.get_files():
		if f.get_extension() == "json":
			out.append("weather/" + f.get_basename())
			out.append(FileAccess.get_file_as_string("res://configs/weather/" + f))
	return out


func _ready() -> void:
	set_process(false)
	if not ClassDB.class_exists("DpAir"):
		_fail("класс DpAir не найден (расширение не загрузилось)")
		return
	_dp = ClassDB.instantiate("DpAir")
	if _dp.api_version() != API_VERSION:
		_fail("api_version = %s, ожидалось %d" % [_dp.api_version(), API_VERSION])
		return
	print("DP_AIR_SMOKE расширение загружено, api_version=%d" % API_VERSION)
	var cfgs := _configs()
	if cfgs.is_empty():
		_fail("конфиги res://configs не прочитались (нет в pck?)")
		return
	if _dp.configure(cfgs, 1) != 0:
		_fail("configure: %s" % _dp.last_error())
		return
	if _dp.set_conditions(COND) != 0:
		_fail("set_conditions: %s" % _dp.last_error())
		return
	_dp.set_focuses(PackedVector3Array([Vector3(0, 110, 0)]), PackedFloat32Array([1.0]))
	var n := 400 * 400
	var water := PackedByteArray()
	water.resize(n)
	var cls := PackedByteArray()
	cls.resize(n)
	cls.fill(1)
	var h := PackedFloat32Array()
	h.resize(n)
	h.fill(100.0)
	var m := PackedFloat32Array()
	m.resize(n)
	m.fill(0.5)
	var rc: int = _dp.load_place(HEADER, h, water, cls, m)
	if rc != 0:
		_fail("load_place rc=%s: %s" % [rc, _dp.last_error()])
		return
	_t0 = Time.get_ticks_msec() * 0.001
	set_process(true)


func _process(_delta: float) -> void:
	var t := Time.get_ticks_msec() * 0.001 - _t0
	var st: int = _dp.state()
	var stage := String(_dp.stage())
	if stage != _stage_last:
		_stage_last = stage
		print("DP_AIR_SMOKE %.1f с: state=%d этап=%s итераций=%d" % [t, st, stage, _dp.iters()])
	if st == 3:
		_fail("FAILED за %.1f с: %s / %s" % [t, _dp.status_reason(), _dp.last_error()])
		return
	if st != 2:
		if t > TIMEOUT_S:
			_fail("поле не готово за %.0f с, этап %s (%d итераций)" % [TIMEOUT_S, stage, _dp.iters()])
		return
	set_process(false)
	print("DP_AIR_SMOKE READY за %.1f с" % t)
	_check_ready()


func _check_ready() -> void:
	# поле подано (Пикар посчитан), снимок не пуст
	if int(_dp.field_version()) <= 0:
		_fail("READY, но поля нет (field_version = 0)")
		return
	if int(_dp.field_export()) <= 0 or _dp.field_export_data().is_empty():
		_fail("READY, но снимок поля пуст")
		return
	var out: PackedFloat32Array = _dp.sample_many(PackedVector3Array([Vector3(0, 110, 0)]), 0)
	if out.size() != 4:
		_fail("sample_many длина %s, ожидалось 4" % out.size())
		return
	var speed := Vector3(out[0], out[1], out[2]).length()
	print(
		"DP_AIR_SMOKE ветер у земли %.2f м/с (σ %.2f), field_version=%d" % [speed, out[3], _dp.field_version()]
	)
	if not (speed > 0.1):
		_fail("ветер у земли нулевой: %.3f м/с" % speed)
		return
	print("DP_AIR_SMOKE OK")
	get_tree().quit(0)
