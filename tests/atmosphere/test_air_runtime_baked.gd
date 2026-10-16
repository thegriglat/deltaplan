extends TestCase
## AirRuntime и запечённое поле старта (TI-4, TI-К3) без GPU: при совпадении key поле берётся из файла
## (в атмосферу без расчёта, состояние выставлено — поле старта не пересчитывается сразу, фоновый пересчёт
## ждёт включения recompute_enabled); нет файла / key не совпал / условия не как в наборе погоды /
## baked_enabled = false — обычный путь (здесь headless: аналитика). Файлы — user://ti4_baked_rt.
## Поле — синтетическое (tests/contracts/test_training_island_k3.gd), место — Онгудай из фикстур.

const K3 := preload("res://tests/contracts/test_training_island_k3.gd")
const ROOT := "user://ti4_baked_rt"
const SITE := "kayancha_south"
const START_LATLON := Vector2(50.78708, 86.23278)


class StubAtmo:
	extends RefCounted
	var field: Variant = null
	var calls := 0
	var blend := -1.0

	func set_air_field(f: Variant, b: float) -> void:
		field = f
		blend = b
		calls += 1


static func weather() -> Dictionary:
	return {
		"wind_from_deg": 150, "wind_speed_ms": 3.0, "start_hour": 12.0, "month": 7, "day": 15,
		"sky": "clear", "temperature_c": 25.0,
	}


var _c := {}


func _cond() -> Dictionary:
	return _c


## Узел AirRuntime на месте Онгудая, со стартом SITE и набором погоды в записи площадки.
func _runtime(atmo: Object, w: Dictionary) -> AirRuntime:
	var lw := TestAirPlace.load_detail("ongudai")
	var loc := TestAirPlace.load_loc("ongudai")
	loc.month = int(weather().month)
	loc.day = int(weather().day)
	var p := TerrainGeo.latlon_to_local(
		START_LATLON.x, START_LATLON.y, float(loc.center_lat), float(loc.center_lon)
	)
	var pos := Vector3(p.x, (lw[0] as HeightLayer).sample(p.x, p.y), p.y)
	var rt := AirRuntime.new()
	var place := {
		detail = lw[0], water = lw[1], loc = loc,
		start_sites = [{id = SITE, position = pos, weather = w}],
	}
	_c = AirBakedField.conditions_of(weather())
	rt.setup(atmo, place, _cond)
	rt.set_focus(null, pos)
	return rt


func _key(rt: AirRuntime, w: Dictionary) -> Dictionary:
	var loc: Dictionary = rt._place.loc
	var site: Dictionary = rt._place.start_sites[0]
	return AirBakedField.make_key(
		"ongudai", float(loc.center_lat), float(loc.center_lon), SITE, w, site.position,
		AirBakedField.place_hash(Locations.data_dir("ongudai")),
		Config.get_config("atmosphere").air_model.window_levels_m
	)


func _bake(rt: AirRuntime, key: Dictionary) -> void:
	var path := AirBakedField.path_of("ongudai", SITE, ROOT)
	var h := {"location": "ongudai", "site": SITE, "key": key, "model_hash": AirBakedField.model_hash()}
	check(AirBakedField.save(K3.synthetic_set(), h, path), "запись запечённого поля")


func _clean() -> void:
	AirBakedField.baked_root = "res://data/locations"
	var d := ROOT.path_join("ongudai").path_join("air")
	for f in DirAccess.get_files_at(d):
		DirAccess.remove_absolute(d.path_join(f))


func _node(rt: AirRuntime) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	tree.root.add_child(rt)


func test_baked_taken_when_key_matches() -> void:
	await Engine.get_main_loop().process_frame
	AirBakedField.baked_root = ROOT
	var atmo := StubAtmo.new()
	var rt := _runtime(atmo, weather())
	_node(rt)
	_bake(rt, _key(rt, weather()))
	check(rt.baked_ready(), "baked_ready: поле будет взято из файла")
	var ok: bool = await rt.load_field()
	check(ok, "load_field: поле есть (%s)" % rt.last_error)
	check(rt.last_info.get("baked", false) == true, "last_info.baked")
	check(atmo.calls == 1 and atmo.field is Array and (atmo.field as Array).size() == 3, "в атмосферу подано 3 уровня")
	check(atmo.blend == 0.0, "при загрузке — без подмены")
	check(not rt.busy(), "расчёт не запущен")
	check(
		AirRuntime.needs_recompute(rt.current_conditions(), _c, 15.0) == "",
		"поле старта сразу не пересчитывается: %s" % AirRuntime.needs_recompute(rt.current_conditions(), _c, 15.0)
	)
	check(is_equal_approx(rt.inflow_k, 0.85), "k притока взят из поля: %.3f" % rt.inflow_k)
	check(rt.applied_count == 1 and rt.failed_count == 0, "applied_count 1")
	# повторная загрузка тех же условий — поле уже в атмосфере
	var ok2: bool = await rt.load_field()
	check(ok2 and atmo.calls == 1, "те же место и условия — повторно не подаётся")
	rt.queue_free()
	_clean()


func test_baked_refused_on_key_mismatch() -> void:
	await Engine.get_main_loop().process_frame
	AirBakedField.baked_root = ROOT
	var atmo := StubAtmo.new()
	var rt := _runtime(atmo, weather())
	_node(rt)
	var other := weather()
	other.temperature_c = 30.0
	_bake(rt, _key(rt, other))  # файл запечён для другого набора
	check(not rt.baked_ready(), "key не совпал — baked_ready ложь")
	var look := rt.baked_lookup(_c)
	check(look.reason != "" and look.warn, "причина и предупреждение: %s" % look.reason)
	var ok: bool = await rt._load_baked(_c)
	check(not ok and atmo.field == null, "поле из файла не взято")
	check(not rt.last_info.has("baked"), "last_info без baked")
	rt.queue_free()
	_clean()


func test_baked_not_used_without_file_or_when_conditions_differ() -> void:
	await Engine.get_main_loop().process_frame
	AirBakedField.baked_root = ROOT
	var atmo := StubAtmo.new()
	var rt := _runtime(atmo, weather())
	_node(rt)
	check(not rt.baked_ready(), "нет файла")
	check(rt.baked_lookup(_c).reason.begins_with("нет файла"), "причина: нет файла")
	var ok: bool = await rt._load_baked(_c)
	check(not ok and atmo.field == null, "нет файла — обычный путь")
	_bake(rt, _key(rt, weather()))
	check(rt.baked_ready(), "файл появился — готово")
	_c.u10 = 4.0  # игрок сменил ветер — набор погоды не действует
	check(not rt.baked_ready() and not rt.baked_lookup(_c).warn, "условия не как в наборе — не берётся")
	_c = AirBakedField.conditions_of(weather())
	rt.baked_enabled = false
	check(not rt.baked_ready(), "baked_enabled = false")
	# старт без набора погоды (обычные места) — молча мимо
	var rt2 := _runtime(atmo, {})
	_node(rt2)
	check(not rt2.baked_ready() and rt2.baked_lookup(_c).reason == "у старта нет набора погоды", "нет weather")
	rt.queue_free()
	rt2.queue_free()
	_clean()
