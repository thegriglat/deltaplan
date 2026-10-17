extends TestCase
## Вечнозелёный полог (RV-К5): SeasonLook.state отдаёт canopy_autumn/canopy_bare = × (1 − evergreen).
## Запуск: godot --headless --path . res://tests/run_tests.tscn -- --filter=test_evergreen


func test_zero_is_as_before() -> void:
	for d in [100.0, 196.0, 274.0, 300.0]:
		var s := SeasonLook.state(d, 51.0, 1000.0, {"evergreen": 0.0})
		var s0 := SeasonLook.state(d, 51.0, 1000.0, {})
		check(is_equal_approx(float(s.canopy_autumn), float(s.autumn)), "doy %.0f: canopy_autumn = autumn" % d)
		check(is_equal_approx(float(s.canopy_bare), float(s.bare)), "doy %.0f: canopy_bare = bare" % d)
		for k in ["green", "dry", "autumn", "bare", "rel", "snow_fresh"]:
			check(is_equal_approx(float(s[k]), float(s0[k])), "%s без ключа = 0" % k)


func test_one_october() -> void:
	var s0 := SeasonLook.state(274.0, 51.0, 1000.0, {})
	var s := SeasonLook.state(274.0, 51.0, 1000.0, {"evergreen": 1.0})
	check(float(s0.canopy_autumn) > 0.0, "контроль: осень есть без evergreen")
	check(float(s.canopy_autumn) == 0.0, "canopy_autumn = 0")
	check(float(s.canopy_bare) == 0.0, "canopy_bare = 0")
	for k in ["green", "dry", "autumn", "bare", "snow_fresh", "snow_line_m"]:
		check(is_equal_approx(float(s[k]), float(s0[k])), "%s не меняется" % k)


func test_half_and_disabled() -> void:
	var s0 := SeasonLook.state(300.0, 51.0, 0.0, {})
	var s := SeasonLook.state(300.0, 51.0, 0.0, {"evergreen": 0.5})
	check(is_equal_approx(float(s.canopy_bare), 0.5 * float(s0.bare)), "0.5 -> половина")
	var off := SeasonLook.state(300.0, 51.0, 0.0, {"season_enabled": false, "evergreen": 1.0})
	check(float(off.canopy_autumn) == 0.0 and float(off.canopy_bare) == 0.0, "сезон выключен")
