extends TestCase
## PH-К1, виджет: толщина рамки индикатора подвески от усилия рук — только толщина.

const W := preload("res://scripts/ui/pilot_shift_indicator.gd")


func _cfg() -> Dictionary:
	return Config.get_config("ui").pilot_shift


func test_width_zero_and_full() -> void:
	var cfg := _cfg()
	var d := 1080.0 * float(cfg.diameter_frac)
	var w0 := maxf(1.0, d * 0.015)
	approx(W.ring_width(d, 0.0, cfg), w0, 1e-4, "без усилия — прежняя толщина")
	var w_max := d * float(cfg.force_ring_max_frac)
	var f_full := float(cfg.force_full_n)
	approx(W.ring_width(d, f_full, cfg), w_max, 1e-4, "при F_full — w_max")
	approx(W.ring_width(d, 10.0 * f_full, cfg), w_max, 1e-4, "выше F_full — не растёт")
	approx(W.ring_width(d, 0.5 * f_full, cfg), 0.5 * (w0 + w_max), 1e-4, "линейно: половина — середина")
	approx(W.ring_width(d, -f_full, cfg), w_max, 1e-4, "знак не важен")
	check(w_max > w0 * 2.0, "полная толщина заметно больше прежней: %.2f vs %.2f" % [w_max, w0])


func test_width_monotonic_and_finite() -> void:
	var cfg := _cfg()
	var d := 97.0
	var prev := -1.0
	for f in [0.0, 10.0, 30.0, 60.0, 100.0, 120.0, 200.0, 300.0]:
		var w: float = W.ring_width(d, f, cfg)
		check(w >= prev, "монотонно: %.2f ≥ %.2f при %.0f Н" % [w, prev, f])
		prev = w
	approx(W.ring_width(d, NAN, cfg), W.ring_width(d, 0.0, cfg), 1e-6, "NaN — как без усилия")
	approx(W.ring_width(d, INF, cfg), W.ring_width(d, 0.0, cfg), 1e-6, "inf — как без усилия")
	check(is_equal_approx(W.ring_width(20.0, 0.0, {}), 1.0), "пустой конфиг: минимум 1 px")


func test_config_documented() -> void:
	var cfg := _cfg()
	for k in ["force_ring_max_frac", "force_full_n"]:
		check(cfg.has(k) and cfg.has(k + "_doc"), "%s с пояснением" % k)
