extends TestCase
## Затенение земли крылом (PH-8, контракт PH-К7): формула, инварианты, переход в ноль выше h_max.

const AREA := 13.5
const CFG := {"gain": 1.6, "sky_share": 0.4, "h_max_m": 12.0}


func test_sky_shade_monotonic_in_height() -> void:
	var prev := 2.0
	for h in [0.5, 1.0, 2.0, 3.0, 5.0, 8.0, 11.0]:
		var d := SkyShade.darkening(0.0, h, AREA, CFG)
		check(d < prev, "darkening(0, %.1f) = %.4f убывает по h (пред. %.4f)" % [h, d, prev])
		check(d >= 0.0 and d <= 1.0, "в [0, 1]: %.4f" % d)
		prev = d


func test_sky_shade_zero_above_h_max() -> void:
	approx(SkyShade.darkening(0.0, 12.0, AREA, CFG), 0.0, 1e-6, "ровно h_max")
	approx(SkyShade.darkening(0.0, 30.0, AREA, CFG), 0.0, 1e-6, "выше h_max")
	# плавно: у 0,95·h_max много меньше, чем у 0,5·h_max
	var lo := SkyShade.darkening(0.0, 6.0, AREA, CFG)
	var hi := SkyShade.darkening(0.0, 11.4, AREA, CFG)
	check(hi < 0.2 * lo, "затухание у h_max: %.4f vs %.4f" % [hi, lo])


func test_sky_shade_spot_radius_grows_with_height() -> void:
	var prev := 0.0
	for h in [1.0, 2.0, 4.0, 7.0]:
		var d0 := SkyShade.darkening(0.0, h, AREA, CFG)
		var r := 0.0
		while SkyShade.darkening(r, h, AREA, CFG) > 0.1 * d0 and r < 60.0:
			r += 0.05
		check(r > prev, "радиус по 0,1·центр при h=%.0f: %.2f > %.2f" % [h, r, prev])
		prev = r


func test_sky_shade_formula_matches_disc() -> void:
	# на оси F = R²/(h²+R²); далеко от диска ≈ (R²/ (2 r²))·(h/r)... — проверяем ось и симметрию спада по r
	var radius := SkyShade.disc_radius(AREA)
	var h := 3.0
	var f0 := SkyShade.view_factor(0.0, h, radius)
	approx(f0, radius * radius / (h * h + radius * radius), 1e-6, "F на оси")
	check(SkyShade.view_factor(2.0, h, radius) < f0, "вбок слабее")
	check(SkyShade.view_factor(0.0, 0.05, radius) > 0.99, "у земли под диском F → 1")
	check(SkyShade.darkening(0.0, 0.0, AREA, {"gain": 2.0, "sky_share": 1.0, "h_max_m": 12.0}) <= 1.0, "≤ 1")


func test_sky_shade_gain_clamped_and_share_scales() -> void:
	var a := SkyShade.darkening(0.0, 3.0, AREA, {"gain": 9.0, "sky_share": 0.4, "h_max_m": 12.0})
	var b := SkyShade.darkening(0.0, 3.0, AREA, {"gain": 2.0, "sky_share": 0.4, "h_max_m": 12.0})
	approx(a, b, 1e-6, "gain ≤ 2")
	var clear := SkyShade.darkening(0.0, 3.0, AREA, {"gain": 1.6, "sky_share": 0.15, "h_max_m": 12.0})
	var cloudy := SkyShade.darkening(0.0, 3.0, AREA, {"gain": 1.6, "sky_share": 0.9, "h_max_m": 12.0})
	check(cloudy > 4.0 * clear, "пасмурно заметнее, чем ясно: %.3f vs %.3f" % [cloudy, clear])


func test_sky_shade_share_from_environment() -> void:
	var cfg := {"sky_share_min": 0.15, "sky_share_max": 0.9}
	var clear := SkyShade.share_from_env(0.56, 1.0, cfg)
	var overcast := SkyShade.share_from_env(0.56, 0.05, cfg)
	check(overcast > clear, "пасмурно доля неба больше")
	check(clear >= 0.15 and overcast <= 0.9, "в границах конфига")


func test_sky_shade_touchdown_covers_feet() -> void:
	# при касании (центр паруса ~2,5–3 м над землёй) пятно охватывает ноги: центр пятна сдвинут вперёд
	# не больше h, ноги — в пределах 1,5 м от центра пятна; там затемнение > 0,1·центр
	var cfg: Dictionary = Config.get_config("flight").visual.sky_shade
	var c := {"gain": cfg.gain, "sky_share": 0.3, "h_max_m": cfg.h_max_m}
	for h in [2.0, 2.5, 3.0]:
		var d0 := SkyShade.darkening(0.0, h, AREA, c)
		var shift: float = float(cfg.shift_k) * h
		check(shift <= h, "сдвиг ≤ h")
		var d_feet := SkyShade.darkening(shift + 0.5, h, AREA, c)
		check(d_feet > 0.1 * d0, "ноги в пятне при h=%.1f: %.3f vs центр %.3f" % [h, d_feet, d0])
		check(d0 > 0.05, "у касания пятно заметно (%.3f)" % d0)


func test_sky_shade_config_present() -> void:
	var cfg: Dictionary = Config.get_config("flight").visual.sky_shade
	for k in ["gain", "sky_share", "h_max_m", "shift_k", "stretch", "vertical_m"]:
		check(cfg.has(k) and cfg.has(k + "_doc"), "конфиг sky_shade.%s с пояснением" % k)
	check(float(cfg.gain) >= 1.0 and float(cfg.gain) <= 2.0, "gain в 1..2")
	check(float(cfg.shift_k) <= 1.0, "сдвиг ≤ h")
