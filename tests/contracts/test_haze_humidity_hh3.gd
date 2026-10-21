extends TestCase
## Контракт HH3 (docs/contracts/haze-humidity.md): густота дымки по влажности.

const EPS := 0.01


## Td по Магнусу для заданных T и RH.
func _td_for(t_c: float, rh: float) -> float:
	var g := log(rh) + 17.625 * t_c / (t_c + 243.04)
	return 243.04 * g / (17.625 - g)


func test_reference_values() -> void:
	check(is_equal_approx(WeatherModel.haze_k_rh(25.0, _td_for(25.0, 0.3)), 1.0), "RH 0,3 → 1,0")
	check(is_equal_approx(WeatherModel.haze_k_rh(25.0, _td_for(25.0, 0.40)), 1.0), "RH 0,40 → 1,0")
	var k85 := WeatherModel.haze_k_rh(20.0, _td_for(20.0, 0.85))
	check(absf(k85 - 2.30) <= EPS, "RH 0,85 → 2,30, получено %f" % k85)
	var kw := WeatherModel.haze_k_rh(10.0, 15.0)
	check(absf(kw - 4.44) <= EPS, "Td > T → 4,44, получено %f" % kw)


func _derive(hour: float) -> Dictionary:
	var ctx := WeatherModel.reference_context()
	var f := {"sky": "clear"}
	return WeatherModel.derive(f, ctx, {}, hour)


func test_derive_matches() -> void:
	for h in [NAN, 19.0]:
		var w := _derive(h)
		var dv: Dictionary = w._derived
		check(dv.has("rh"), "есть _derived.rh (час %s)" % str(h))
		var want := WeatherModel.haze_k_rh(float(dv.temperature_c), float(dv.dew_point_c))
		check(is_equal_approx(float(w.haze_k), want), "haze_k == haze_k_rh (час %s): %f / %f" % [str(h), w.haze_k, want])


func test_evening_not_thinner() -> void:
	var k15 := float(_derive(15.0).haze_k)
	var k19 := float(_derive(19.0).haze_k)
	check(k19 >= k15, "19 ч не реже 15 ч: %f >= %f" % [k19, k15])


func test_config_clean() -> void:
	var c := WeatherModel.config()
	check(not (c.get("diurnal", {}) as Dictionary).has("evening_haze_k"), "нет diurnal.evening_haze_k")
	var sky: Dictionary = c.get("sky", {})
	for k in sky:
		if sky[k] is Dictionary:
			check(not (sky[k] as Dictionary).has("haze_k"), "нет sky.%s.haze_k" % k)
	check(c.has("haze_humidity"), "есть haze_humidity")
