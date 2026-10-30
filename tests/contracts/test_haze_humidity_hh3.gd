extends TestCase
## Контракт HH3 (docs/contracts/haze-humidity.md): густота дымки по влажности.


## haze_k_rh (формула и опорные значения 1,0 / 2,30 / 4,44) — в крейте, cargo weather_derive.rs;
## здесь — что игра получает haze_k из derive вместе с влажностью дня.
func _derive(hour: float) -> Dictionary:
	var ctx := Weather.reference_context()
	return Weather.derive({"sky": "clear"}, ctx, hour)


func test_derive_has_haze() -> void:
	for h in [NAN, 19.0]:
		var w := _derive(h)
		var dv: Dictionary = w._derived
		check(dv.has("rh"), "есть _derived.rh (час %s)" % str(h))
		check(is_finite(float(w.haze_k)) and float(w.haze_k) >= 1.0, "haze_k ≥ 1 (час %s): %f" % [str(h), w.haze_k])


func test_evening_not_thinner() -> void:
	var k15 := float(_derive(15.0).haze_k)
	var k19 := float(_derive(19.0).haze_k)
	check(k19 >= k15, "19 ч не реже 15 ч: %f >= %f" % [k19, k15])


func test_config_clean() -> void:
	var c := Weather.config()
	check(not (c.get("diurnal", {}) as Dictionary).has("evening_haze_k"), "нет diurnal.evening_haze_k")
	var sky: Dictionary = c.get("sky", {})
	for k in sky:
		if sky[k] is Dictionary:
			check(not (sky[k] as Dictionary).has("haze_k"), "нет sky.%s.haze_k" % k)
	check(c.has("haze_humidity"), "есть haze_humidity")
