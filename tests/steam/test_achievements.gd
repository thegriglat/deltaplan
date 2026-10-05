extends TestCase
## Трекер ачивок (ST-6) на синтетическом потоке S2: на каждую ачивку «открывается» и «не открывается
## на пороге − ε», накопительные переживают перезапуск, Steam — на подставном синглтоне.

const Tracker := preload("res://scripts/steam/achievements.gd")
const Service := preload("res://scripts/steam/steam_service.gd")
const Fake := preload("res://tests/steam/fake_steam_ach.gd")
const Continents := preload("res://scripts/steam/continents.gd")
const TMP := "user://test_achievements.json"


func _ctx(o: Dictionary = {}) -> Dictionary:
	var c := {"place_key": "alps/a", "wing": "w1", "net": false, "launch_pos": Vector3.ZERO,
			"launch_alt_msl": 1000.0, "wind_ms": 2.0, "wind_from_deg": 0.0, "lat": 47.0, "lon": 8.0,
			"temp_c": 15.0, "cb_chance": 0.1, "sky": "clear"}
	c.merge(o, true)
	return c


func _fin(o: Dictionary = {}) -> Dictionary:
	var f := {"kind": "landed", "grade": "soft", "vertical_speed_ms": 1.0, "horizontal_speed_ms": 5.0,
			"flight_time_s": 120.0, "distance_m": 1000.0, "height_gain_m": 50.0, "best_thermal_climb_ms": 1.0,
			"land_pos": Vector3(1000, 0, 0), "land_alt_msl": 900.0, "others_total": 0, "others_airborne": 0,
			"land_surface": "ground", "land_camp_m": NAN, "live_peers": 0}
	f.merge(o, true)
	return f


## n+1 сэмплов t = 0..n с 1 Гц; over — поля, общие для всех.
func _series(n: int, over: Dictionary = {}) -> Array:
	var out: Array = []
	for i in n + 1:
		var s := {"t": float(i), "pos": Vector3.ZERO, "alt_msl": 1050.0, "agl": 500.0, "vario": 0.0,
				"circling": false, "cloud_base_msl": NAN, "sun_elev_deg": 45.0, "others_airborne": 0,
				"eggs": {}, "near_climbing_live": 0}
		s.merge(over, true)
		out.append(s)
	return out


func _tracker(svc: Node = null, path: String = TMP) -> Node:
	var t := Tracker.new()
	t.progress_path = path
	t.service = svc
	t.start()
	return t


func _fly(t: Node, ctx: Dictionary, samples: Array, fin: Dictionary) -> void:
	t.on_flight_started(ctx)
	for s in samples:
		t.on_flight_sample(s)
	t.on_flight_finished(fin)


func _clean(path: String = TMP) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)


## Один полёт на чистом трекере: открылась ли ачивка.
func _opens(api: String, case: Dictionary) -> bool:
	_clean()
	var t := _tracker()
	_fly(t, _ctx(case.get("ctx", {})), case.get("samples", _series(10)), _fin(case.get("fin", {})))
	var r: bool = t.is_unlocked(api)
	t.free()
	_clean()
	return r


func _pair(api: String, pos: Dictionary, neg: Dictionary) -> void:
	check(_opens(api, pos), api + " открывается")
	check(not _opens(api, neg), api + " не открывается на пороге − ε")


func test_flight_rules_threshold_pairs() -> void:
	_pair("ACH_FIRST_FLIGHT", {"fin": {"grade": "hard"}}, {"fin": {"grade": "crash"}})
	_pair("ACH_SOFT_LANDING", {"fin": {"vertical_speed_ms": 0.49, "horizontal_speed_ms": 2.9}},
			{"fin": {"vertical_speed_ms": 0.5, "horizontal_speed_ms": 2.9}})
	_pair("ACH_SOFT_LANDING", {"fin": {"vertical_speed_ms": 0.1, "horizontal_speed_ms": 2.99}},
			{"fin": {"vertical_speed_ms": 0.1, "horizontal_speed_ms": 3.0}})
	_pair("ACH_TOP_LANDING", {"fin": {"flight_time_s": 300.0, "land_pos": Vector3(300, 0, 0), "land_alt_msl": 970.0}},
			{"fin": {"flight_time_s": 299.0, "land_pos": Vector3(300, 0, 0), "land_alt_msl": 970.0}})
	_pair("ACH_TOP_LANDING", {"fin": {"flight_time_s": 400.0, "land_pos": Vector3(0, 0, 300), "land_alt_msl": 970.0}},
			{"fin": {"flight_time_s": 400.0, "land_pos": Vector3(0, 0, 300.5), "land_alt_msl": 970.0}})
	_pair("ACH_TOP_LANDING", {"fin": {"flight_time_s": 400.0, "land_pos": Vector3(10, 0, 0), "land_alt_msl": 970.0}},
			{"fin": {"flight_time_s": 400.0, "land_pos": Vector3(10, 0, 0), "land_alt_msl": 969.0}})
	_pair("ACH_TOP_LANDING", {"fin": {"flight_time_s": 400.0, "land_pos": Vector3(10, 0, 0), "land_alt_msl": 1000.0, "grade": "hard"}},
			{"fin": {"flight_time_s": 400.0, "land_pos": Vector3(10, 0, 0), "land_alt_msl": 1000.0, "grade": "crash"}})
	_pair("ACH_ABOVE_LAUNCH", {"fin": {"height_gain_m": 100.0}}, {"fin": {"height_gain_m": 99.9}})
	_pair("ACH_KILOMETER_UP", {"fin": {"height_gain_m": 1000.0}}, {"fin": {"height_gain_m": 999.9}})
	_pair("ACH_STRONG_CLIMB", {"fin": {"best_thermal_climb_ms": 4.0}}, {"fin": {"best_thermal_climb_ms": 3.9}})
	_pair("ACH_SOARING_15", {"fin": {"flight_time_s": 900.0}}, {"fin": {"flight_time_s": 899.0}})
	_pair("ACH_HOURS_3", {"fin": {"flight_time_s": 10800.0}}, {"fin": {"flight_time_s": 10799.0}})
	_pair("ACH_HOUR", {"fin": {"flight_time_s": 3600.0}}, {"fin": {"flight_time_s": 3599.0}})
	_pair("ACH_XC_10", {"fin": {"distance_m": 10000.0}}, {"fin": {"distance_m": 9999.0}})
	_pair("ACH_XC_50", {"fin": {"distance_m": 50000.0}}, {"fin": {"distance_m": 49999.0}})
	_pair("ACH_XC_100", {"fin": {"distance_m": 100000.0}}, {"fin": {"distance_m": 99999.0}})
	_pair("ACH_HIGH_LAUNCH", {"ctx": {"launch_alt_msl": 3000.0}}, {"ctx": {"launch_alt_msl": 2999.0}})
	_pair("ACH_DESCENT_2000", {"ctx": {"launch_alt_msl": 3000.0}, "fin": {"land_alt_msl": 1000.0}},
			{"ctx": {"launch_alt_msl": 3000.0}, "fin": {"land_alt_msl": 1001.0}})
	_pair("ACH_STORM", {"ctx": {"cb_chance": 0.5}, "fin": {"flight_time_s": 600.0}},
			{"ctx": {"cb_chance": 0.49}, "fin": {"flight_time_s": 600.0}})
	_pair("ACH_STORM", {"ctx": {"cb_chance": 0.5}, "fin": {"flight_time_s": 600.0}},
			{"ctx": {"cb_chance": 0.5}, "fin": {"flight_time_s": 599.0}})
	_pair("ACH_STRONG_WIND", {"ctx": {"wind_ms": 10.0}}, {"ctx": {"wind_ms": 9.9}})
	_pair("ACH_OVERCAST", {"ctx": {"sky": "overcast"}, "fin": {"height_gain_m": 300.0}},
			{"ctx": {"sky": "overcast"}, "fin": {"height_gain_m": 299.0}})
	_pair("ACH_OVERCAST", {"ctx": {"sky": "overcast"}, "fin": {"height_gain_m": 300.0}},
			{"ctx": {"sky": "partly"}, "fin": {"height_gain_m": 300.0}})
	_pair("ACH_WINTER", {"ctx": {"temp_c": 0.0}, "fin": {"flight_time_s": 600.0}},
			{"ctx": {"temp_c": 0.1}, "fin": {"flight_time_s": 600.0}})
	_pair("ACH_WINTER", {"ctx": {"temp_c": -5.0}, "fin": {"flight_time_s": 600.0}},
			{"ctx": {"temp_c": -5.0}, "fin": {"flight_time_s": 599.0}})
	_pair("ACH_WATER_LANDING", {"fin": {"land_surface": "water"}}, {"fin": {"land_surface": "ground"}})
	_pair("ACH_CAMP_LANDING", {"fin": {"land_camp_m": 10.0}}, {"fin": {"land_camp_m": 10.1}})
	_pair("ACH_CAMP_LANDING", {"fin": {"land_camp_m": 0.0}}, {"fin": {"land_camp_m": NAN}})


func test_upwind() -> void:
	# Ветер с востока (90°): «против ветра» — на восток, +X.
	var ctx := {"wind_ms": 4.0, "wind_from_deg": 90.0}
	_pair("ACH_UPWIND", {"ctx": ctx, "fin": {"land_pos": Vector3(5000, 0, 3000)}},
			{"ctx": ctx, "fin": {"land_pos": Vector3(4999, 0, 3000)}})
	_pair("ACH_UPWIND", {"ctx": ctx, "fin": {"land_pos": Vector3(5000, 0, 0)}},
			{"ctx": {"wind_ms": 3.9, "wind_from_deg": 90.0}, "fin": {"land_pos": Vector3(5000, 0, 0)}})
	_pair("ACH_UPWIND", {"ctx": {"wind_ms": 6.0, "wind_from_deg": 0.0}, "fin": {"land_pos": Vector3(0, 0, -5000)}},
			{"ctx": {"wind_ms": 6.0, "wind_from_deg": 0.0}, "fin": {"land_pos": Vector3(0, 0, 5000)}})
	_pair("ACH_UPWIND", {"ctx": ctx, "fin": {"land_pos": Vector3(6000, 0, 0)}},
			{"ctx": {"wind_ms": NAN, "wind_from_deg": 90.0}, "fin": {"land_pos": Vector3(6000, 0, 0)}})


func test_sample_rules() -> void:
	_pair("ACH_CLOUDBASE", {"samples": _series(5, {"cloud_base_msl": 2000.0, "alt_msl": 1900.0})},
			{"samples": _series(5, {"cloud_base_msl": 2000.0, "alt_msl": 1899.0})})
	_pair("ACH_CLOUDBASE", {"samples": _series(5, {"cloud_base_msl": 2000.0, "alt_msl": 1900.0})},
			{"samples": _series(5, {"cloud_base_msl": NAN, "alt_msl": 9000.0})})
	_pair("ACH_ALT_5000", {"samples": _series(5, {"alt_msl": 5000.0})}, {"samples": _series(5, {"alt_msl": 4999.0})})
	_pair("ACH_RIDGE_LOW", {"samples": _series(600, {"agl": 300.0})}, {"samples": _series(599, {"agl": 300.0})})
	_pair("ACH_RIDGE_LOW", {"samples": _series(600, {"agl": 300.0})}, {"samples": _series(600, {"agl": 300.5})})
	# Разрыв серии сбрасывает счёт: 2 × 300 с с подъёмом выше 300 м посередине — не открывает.
	var broken := _series(300, {"agl": 100.0}) + _series(1, {"agl": 500.0}) + _series(300, {"agl": 100.0})
	for i in broken.size():
		broken[i].t = float(i)
	check(not _opens("ACH_RIDGE_LOW", {"samples": broken}), "ridge: разрыв сбрасывает серию")
	_pair("ACH_EVENING", {"samples": _series(1200, {"sun_elev_deg": 9.9})},
			{"samples": _series(1199, {"sun_elev_deg": 9.9})})
	_pair("ACH_EVENING", {"samples": _series(1200, {"sun_elev_deg": 9.9})},
			{"samples": _series(1200, {"sun_elev_deg": 10.0})})
	_pair("ACH_EVENING", {"samples": _series(1200, {"sun_elev_deg": 9.9})},
			{"samples": _series(1200, {"sun_elev_deg": NAN})})
	var gaggle := {"circling": true, "vario": 0.6, "near_climbing_live": 1}
	_pair("ACH_GAGGLE", {"ctx": {"net": true}, "samples": _series(60, gaggle)},
			{"ctx": {"net": true}, "samples": _series(59, gaggle)})
	_pair("ACH_GAGGLE", {"ctx": {"net": true}, "samples": _series(60, gaggle)},
			{"ctx": {"net": true}, "samples": _series(60, {"circling": true, "vario": 0.5, "near_climbing_live": 1})})
	_pair("ACH_GAGGLE", {"ctx": {"net": true}, "samples": _series(60, gaggle)},
			{"ctx": {"net": false}, "samples": _series(60, gaggle)})
	_pair("ACH_GAGGLE", {"ctx": {"net": true}, "samples": _series(60, gaggle)},
			{"ctx": {"net": true}, "samples": _series(60, {"circling": true, "vario": 0.6, "near_climbing_live": 0})})


func test_eggs() -> void:
	_pair("ACH_EAGLE", {"samples": _series(3, {"eggs": {"eagle": 100.0}})}, {"samples": _series(3, {"eggs": {"eagle": 100.5}})})
	_pair("ACH_EAGLE", {"samples": _series(3, {"eggs": {"eagle": 50.0}})}, {"samples": _series(3, {"eggs": {"balloon": 10.0}})})
	_pair("ACH_BALLOONS", {"samples": _series(3, {"eggs": {"balloon": 150.0}})}, {"samples": _series(3, {"eggs": {"balloon": 151.0}})})
	_pair("ACH_BALLOONS", {"samples": _series(3, {"eggs": {"balloon_festival": 20.0}})}, {"samples": _series(3, {"eggs": {"eagle": 20.0}})})
	_pair("ACH_GLORIA", {"samples": _series(3, {"eggs": {"gloria": 0}})}, {"samples": _series(3, {"eggs": {}})})
	# Одно приближение за полёт достаточно, даже если в других сэмплах пасхалки нет.
	var s := _series(5)
	s[2].eggs = {"eagle": 80.0}
	check(_opens("ACH_EAGLE", {"samples": s}), "орёл в одном сэмпле")


func test_together_and_last_down() -> void:
	_pair("ACH_TOGETHER", {"ctx": {"net": true}, "fin": {"live_peers": 1}}, {"ctx": {"net": true}, "fin": {"live_peers": 0}})
	_pair("ACH_TOGETHER", {"ctx": {"net": true}, "fin": {"live_peers": 1}}, {"ctx": {"net": false}, "fin": {"live_peers": 1}})
	var ld := {"flight_time_s": 600.0, "others_total": 3, "others_airborne": 0}
	_pair("ACH_LAST_DOWN", {"fin": ld}, {"fin": {"flight_time_s": 599.0, "others_total": 3, "others_airborne": 0}})
	_pair("ACH_LAST_DOWN", {"fin": ld}, {"fin": {"flight_time_s": 600.0, "others_total": 2, "others_airborne": 0}})
	_pair("ACH_LAST_DOWN", {"fin": ld}, {"fin": {"flight_time_s": 600.0, "others_total": 3, "others_airborne": 1}})


func test_not_landed_counts_nothing() -> void:
	_clean()
	var t := _tracker()
	_fly(t, _ctx({"launch_alt_msl": 4000.0}), _series(5, {"alt_msl": 3999.0}), _fin({"kind": "takeoff_failed"}))
	check(t.unlocked_count() == 0 and t.progress().flights == 0, "неудачный взлёт не засчитывается")
	# Вызовы без flight_started игнорируются.
	t.on_flight_sample(_series(1)[0])
	t.on_flight_finished(_fin())
	check(t.unlocked_count() == 0, "finished без started")
	t.free()
	_clean()


func test_accumulators_do_not_leak_between_flights() -> void:
	_clean()
	var t := _tracker()
	_fly(t, _ctx(), _series(599, {"agl": 100.0}), _fin())
	_fly(t, _ctx(), _series(599, {"agl": 100.0}), _fin())
	check(not t.is_unlocked("ACH_RIDGE_LOW"), "серия не переходит в следующий полёт")
	t.free()
	_clean()


func _fly_n(t: Node, ctx: Dictionary, fin: Dictionary = {}) -> void:
	_fly(t, _ctx(ctx), _series(2), _fin(fin))


func test_places_persist_across_restart() -> void:
	_clean()
	var t := _tracker()
	for i in 4:
		_fly_n(t, {"place_key": "loc/s%d" % i})
	_fly_n(t, {"place_key": "loc/s0"})  # повтор не считается
	check(not t.is_unlocked("ACH_PLACES_5") and t.progress().places.size() == 4, "4 места")
	t.free()
	var t2 := _tracker()  # перезапуск
	check(t2.progress().places.size() == 4 and t2.progress().flights == 5, "прогресс прочитан")
	_fly_n(t2, {"place_key": "loc/s4"})
	check(t2.is_unlocked("ACH_PLACES_5"), "5 мест — после перезапуска")
	check(not t2.is_unlocked("ACH_PLACES_10"), "10 мест рано")
	t2.free()
	var t3 := _tracker()
	check(t3.is_unlocked("ACH_PLACES_5"), "разблокировка сохранена")
	for i in range(5, 25):
		_fly_n(t3, {"place_key": "loc/s%d" % i})
	check(t3.is_unlocked("ACH_PLACES_10") and t3.is_unlocked("ACH_PLACES_25"), "10 и 25 мест")
	t3.free()
	_clean()


func test_continents_and_wings_airtime() -> void:
	_clean()
	var t := _tracker()
	_fly_n(t, {"lat": 47.0, "lon": 8.0})
	_fly_n(t, {"lat": 50.0, "lon": 87.0})
	check(not t.is_unlocked("ACH_CONTINENTS_3"), "два континента")
	_fly_n(t, {"lat": 19.2, "lon": -100.1})
	check(t.is_unlocked("ACH_CONTINENTS_3") and not t.is_unlocked("ACH_CONTINENTS_ALL"), "три континента")
	_fly_n(t, {"lat": -22.9, "lon": -43.2})
	_fly_n(t, {"lat": -30.75, "lon": 150.7})
	check(not t.is_unlocked("ACH_CONTINENTS_ALL"), "пять континентов")
	_fly_n(t, {"lat": -33.9, "lon": 18.4})
	check(t.is_unlocked("ACH_CONTINENTS_ALL"), "все шесть")
	_fly_n(t, {"lat": NAN, "lon": NAN})  # неизвестная точка ничего не ломает
	t.free()
	_clean()
	t = _tracker()
	for i in 4:
		_fly_n(t, {"wing": "wings/w%d" % i})
	check(not t.is_unlocked("ACH_WINGS_5"), "4 крыла")
	_fly_n(t, {"wing": "wings/w4"})
	check(t.is_unlocked("ACH_WINGS_5"), "5 крыльев")
	t.free()
	_clean()
	t = _tracker()
	_fly_n(t, {}, {"flight_time_s": 35000.0})
	check(not t.is_unlocked("ACH_AIRTIME_10H"), "налёт 35000 с")
	t.free()
	t = _tracker()
	_fly_n(t, {}, {"flight_time_s": 1000.0})
	check(t.is_unlocked("ACH_AIRTIME_10H") and absf(t.progress().airtime_s - 36000.0) < 0.01, "налёт 36000 с после перезапуска")
	t.free()
	_clean()


func test_continent_control_points() -> void:
	var pts := {"europe": [[46.5, 8.0], [48.0, 11.5], [37.0, 15.0]], "asia": [[50.0, 87.0], [35.7, 139.7], [14.6, 121.0], [28.6, 77.2]],
			"africa": [[-33.9, 18.4], [30.0, 31.0], [-1.3, 36.8]], "north_america": [[19.2, -100.1], [40.7, -74.0], [64.0, -150.0]],
			"south_america": [[-22.9, -43.2], [-34.6, -58.4], [4.7, -74.1]], "oceania": [[-30.75, 150.7], [-41.3, 174.8], [21.3, -157.8]]}
	for c: String in pts:
		for p: Array in pts[c]:
			check(Continents.of(p[0], p[1]) == c, "%s: %s → %s" % [c, p, Continents.of(p[0], p[1])])
	check(Continents.of(-80.0, 0.0) == "" and Continents.of(NAN, 8.0) == "", "Антарктида и NAN — нет")


func test_no_duplicate_unlock_and_no_error_without_steam() -> void:
	_clean()
	var t := _tracker()
	var got := []
	t.unlocked.connect(func(api: String) -> void: got.append(api))
	_fly_n(t, {})
	check(got == ["ACH_FIRST_FLIGHT"], "событие unlocked один раз: %s" % [got])
	_fly_n(t, {})
	check(got.size() == 1, "повторно не открывается")
	t.free()
	_clean()


func _active_service(fake: Object) -> Node:
	var svc := Service.new()
	svc.configure(["--steam"], [], true, fake)
	return svc


func test_steam_unlock_and_sync() -> void:
	_clean()
	var fake := Fake.new()
	var svc := _active_service(fake)
	check(svc.is_active(), "подставной Steam активен")
	var t := _tracker(svc)
	_fly_n(t, {})
	check(fake.set_calls == ["ACH_FIRST_FLIGHT"] and fake.store_calls == 1, "setAchievement + storeStats: %s/%d" % [fake.set_calls, fake.store_calls])
	t.free()
	# Старт игры: локально открытое, которого в Steam нет, отправляется; уже отправленное — нет.
	var fake2 := Fake.new()
	var svc2 := _active_service(fake2)
	var t2 := _tracker(svc2)
	check(fake2.set_calls == ["ACH_FIRST_FLIGHT"] and fake2.store_calls == 1, "синхронизация на старте")
	t2.sync_steam()
	check(fake2.set_calls.size() == 1 and fake2.store_calls == 1, "идемпотентно")
	t2.free()
	svc.free()
	svc2.free()
	fake.free()
	fake2.free()
	_clean()


func test_steam_activates_after_start() -> void:
	_clean()
	var fake := Fake.new()
	var svc := Service.new()
	svc.configure([], [], false, fake)  # неактивен
	var t := _tracker(svc)
	_fly_n(t, {})
	check(fake.set_calls.is_empty(), "неактивный Steam не трогаем")
	svc.configure(["--steam"], [], true, fake)  # активация шлёт activated
	check(fake.set_calls == ["ACH_FIRST_FLIGHT"], "активация → синхронизация")
	t.free()
	svc.free()
	fake.free()
	_clean()


## S6 v2: условия по сэмплам и времени в воздухе открываются сразу в полёте (до flight_finished).
func _live_opens(api: String, ctx: Dictionary, samples: Array) -> bool:
	_clean()
	var t := _tracker()
	t.on_flight_started(_ctx(ctx))
	for s in samples:
		t.on_flight_sample(s)
	var r: bool = t.is_unlocked(api)
	t.free()
	_clean()
	return r


func test_live_unlock_in_flight() -> void:
	var cb := {"cloud_base_msl": 2000.0}
	check(_live_opens("ACH_CLOUDBASE", {}, _series(2, {"cloud_base_msl": 2000.0, "alt_msl": 1900.0})), "облака сразу")
	check(not _live_opens("ACH_CLOUDBASE", {}, _series(2, {"cloud_base_msl": 2000.0, "alt_msl": 1899.0})), "облака − ε")
	check(_live_opens("ACH_ALT_5000", {}, _series(2, {"alt_msl": 5000.0})), "5000 сразу")
	check(not _live_opens("ACH_ALT_5000", {}, _series(2, {"alt_msl": 4999.0})), "5000 − ε")
	check(_live_opens("ACH_EAGLE", {}, _series(2, {"eggs": {"eagle": 99.0}})), "орёл сразу")
	check(_live_opens("ACH_GLORIA", {}, _series(2, {"eggs": {"gloria": 0}})), "глория сразу")
	check(_live_opens("ACH_RIDGE_LOW", {}, _series(600, {"agl": 100.0})), "склон сразу")
	check(not _live_opens("ACH_RIDGE_LOW", {}, _series(599, {"agl": 100.0})), "склон − ε")
	check(_live_opens("ACH_EVENING", {}, _series(1200, {"sun_elev_deg": 5.0})), "вечер сразу")
	var g := {"circling": true, "vario": 1.0, "near_climbing_live": 1}
	check(_live_opens("ACH_GAGGLE", {"net": true}, _series(60, g)), "поток сразу")
	check(not _live_opens("ACH_GAGGLE", {"net": true}, _series(59, g)), "поток − ε")
	check(_live_opens("ACH_SOARING_15", {}, _series(900)), "15 минут сразу")
	check(not _live_opens("ACH_SOARING_15", {}, _series(899)), "15 минут − ε")
	check(_live_opens("ACH_HOUR", {}, _series(3600)) and not _live_opens("ACH_HOUR", {}, _series(3599)), "час")
	check(_live_opens("ACH_HOURS_3", {}, _series(10800)) and not _live_opens("ACH_HOURS_3", {}, _series(10799)), "три часа")
	check(_live_opens("ACH_WINTER", {"temp_c": 0.0}, _series(600)), "мороз сразу")
	check(not _live_opens("ACH_WINTER", {"temp_c": 0.1}, _series(600)), "мороз: тепло")
	check(not _live_opens("ACH_WINTER", {"temp_c": 0.0}, _series(599)), "мороз − ε")
	check(_live_opens("ACH_ABOVE_LAUNCH", {}, _series(2, {"alt_msl": 1100.0})), "выше старта сразу")
	check(not _live_opens("ACH_ABOVE_LAUNCH", {}, _series(2, {"alt_msl": 1099.9})), "выше старта − ε")
	check(_live_opens("ACH_KILOMETER_UP", {}, _series(2, {"alt_msl": 2000.0})), "километр сразу")
	check(not _live_opens("ACH_KILOMETER_UP", {}, _series(2, {"alt_msl": 1999.0})), "километр − ε")
	check(_live_opens("ACH_OVERCAST", {"sky": "overcast"}, _series(2, {"alt_msl": 1300.0})), "серый день сразу")
	check(not _live_opens("ACH_OVERCAST", {"sky": "clear"}, _series(2, {"alt_msl": 1300.0})), "серый день: ясно")
	# Посадочные и итоговые — только после посадки.
	check(not _live_opens("ACH_FIRST_FLIGHT", {}, _series(5)) and not _live_opens("ACH_XC_10", {}, _series(5)), "посадочные не в полёте")
	cb.clear()


func test_live_unlock_survives_non_landed_end() -> void:
	_clean()
	var t := _tracker()
	var got := []
	t.unlocked.connect(func(api: String) -> void: got.append(api))
	_fly(t, _ctx(), _series(2, {"alt_msl": 5100.0}), _fin({"kind": "takeoff_failed"}))
	check(got.has("ACH_ALT_5000") and not got.has("ACH_FIRST_FLIGHT"), "открылось в полёте: %s" % [got])
	t.free()
	var t2 := _tracker()
	check(t2.is_unlocked("ACH_ALT_5000"), "сохранено на диск сразу")
	t2.free()
	_clean()


func test_live_unlock_goes_to_steam_in_flight() -> void:
	_clean()
	var fake := Fake.new()
	var svc := _active_service(fake)
	var t := _tracker(svc)
	t.on_flight_started(_ctx())
	t.on_flight_sample(_series(0, {"alt_msl": 6000.0})[0])
	check(fake.set_calls.has("ACH_ALT_5000") and fake.store_calls == 1, "setAchievement в полёте")
	t.on_flight_sample(_series(0, {"alt_msl": 6000.0, "t": 1.0})[0])
	check(fake.store_calls == 1, "повторно не шлётся")
	t.free()
	svc.free()
	fake.free()
	_clean()
