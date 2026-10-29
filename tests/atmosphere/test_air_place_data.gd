extends TestCase
## AirPlaceData: сборка места, которое игра отдаёт крейту (W5 v8). Регресс RW-P4: loc/start_sites
## как const-словари (read-only) не должны ронять fill_climate / fill_crate_inputs.

const LOC := {
	"id": "",
	"center_lat": 51.5,
	"center_lon": 86.5,
	"utc_offset_h": 6.0,
	"month": 7,
	"day": 15,
}
const SITES := [{"id": "s1", "x": 0.0, "z": 0.0, "h_msl": 0.0}]


static func _flat(_x: float, _z: float) -> float:
	return 100.0


static func _one(_x: float, _z: float) -> float:
	return 1.0


func test_const_loc_fill_climate() -> void:
	var p := AirPlaceData.from_functions(_flat, _one, LOC, -500.0, -500.0, 100.0, 11, 11, SITES)
	check(p.validate() == "", "место валидно: %s" % p.validate())
	var loc: Dictionary = p.header.loc
	for k in ["climate", "climate_lag", "climate_cell", "climate_cell_lag"]:
		check(loc.has(k), "loc.%s заполнено" % k)
	check(not LOC.has("climate"), "исходный const-словарь не тронут")


func test_const_sites_fill_crate_inputs() -> void:
	var p := AirPlaceData.from_functions(_flat, _one, LOC, -500.0, -500.0, 100.0, 11, 11, SITES)
	p.fill_crate_inputs()
	check(p.header.has("model_hash"), "model_hash задан (ключ кеша полей)")
	check(not p.header.has("data_hash"), "data_hash больше не передаётся (W5 v9)")
	check(not ("baked" in p), "AirPlaceData.baked удалено (W5 v9)")
	check(JSON.parse_string(p.header_json()) is Dictionary, "заголовок для крейта — json")
