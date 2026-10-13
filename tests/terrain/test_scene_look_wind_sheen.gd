extends TestCase
## scene-look SL-15: блеск волн ветра по траве с высоты, CPU-зеркало sl_wind_sheen_sign / sl_wind_sheen
## (scene_look.gdshaderinc; правятся вместе). Знак — по азимуту ветра относительно солнца и взгляда.

static func _sl() -> Dictionary:
	return Config.get_config("world").get("scene_look", {})


## = sl_wind_sheen_sign
static func sign_of(wind: Vector2, l: Vector3, v: Vector3) -> float:
	var spd := wind.length()
	if spd < 1e-3:
		return 0.0
	var h := (l + v).normalized()
	return clampf(-(wind / spd).dot(Vector2(h.x, h.z)) / maxf(h.length(), 1e-3) * 1.6, -1.0, 1.0)


## = sl_wind_sheen (яркость и тон), base — wind_far_shade
static func tone(c: Color, s: float, far: float, base: float, sl: Dictionary) -> Color:
	var luma := c.r * 0.2126 + c.g * 0.7152 + c.b * 0.0722
	var c0 := Vector3(c.r, c.g, c.b) / (1.0 + base * far)
	var lum := Vector3(luma, luma, luma)
	var lit := c0.lerp(lum * Vector3(1.04, 1.0, 0.9) + (c0 - lum) * 0.5, 0.5)
	var dark := c0 * Vector3(0.92, 1.0, 0.9)
	var a := clampf(absf(s) * far * float(sl.grass_wind_sheen_tint), 0.0, 1.0)
	var r := c0.lerp(lit if s > 0.0 else dark, a) * (1.0 + float(sl.grass_wind_sheen_gain) * s * far)
	return Color(r.x, r.y, r.z)


func test_keys() -> void:
	var sl := _sl()
	check(sl.has("grass_wind_sheen_enabled") and sl.has("grass_wind_sheen_gain") and sl.has("grass_wind_sheen_tint"), "ключи")


func test_sign_by_sun_and_view() -> void:
	var sun := Vector3(0.0, 0.7, 0.7).normalized()   # солнце на +z, высота 45°
	var toward_cam := Vector3(0.0, 0.5, -0.87).normalized()   # камера с -z: смотрит в солнце (контровой)
	var from_sun := Vector3(0.0, 0.5, 0.87).normalized()      # камера у солнца за спиной
	# ветер к солнцу (+z): стебли наклонены к солнцу, поверхность обращена от солнца и вверх
	var a := sign_of(Vector2(0, 5), sun, from_sun)
	var b := sign_of(Vector2(0, -5), sun, from_sun)
	print("         ветер к солнцу %.2f, ветер от солнца %.2f (камера за спиной у солнца)" % [a, b])
	check(a < -0.2 and b > 0.2, "знак меняется с направлением ветра")
	approx(a, -b, 1e-5, "антисимметрия")
	var c := sign_of(Vector2(5, 0), sun, from_sun)
	approx(c, 0.0, 1e-5, "поперёк плоскости солнца и взгляда — ноль")
	var d := sign_of(Vector2(0, 5), sun, toward_cam)
	check(absf(d) <= 1.0, "в допуске")
	approx(sign_of(Vector2.ZERO, sun, from_sun), 0.0, 1e-9, "штиль")
	approx(sign_of(Vector2(3, 4), Vector3.UP, Vector3.UP), 0.0, 1e-5, "солнце и камера в зените — ноль")


func test_tone_sign_and_tint() -> void:
	var sl := _sl()
	var g := Color(0.06, 0.12, 0.04)
	var base := 0.14
	var up := tone(g, 1.0, 1.0, base, sl)
	var dn := tone(g, -1.0, 1.0, base, sl)
	var lg := up.r * 0.2126 + up.g * 0.7152 + up.b * 0.0722
	var ld := dn.r * 0.2126 + dn.g * 0.7152 + dn.b * 0.0722
	var l0 := g.r * 0.2126 + g.g * 0.7152 + g.b * 0.0722
	print("         яркость: по солнцу ×%.3f, против ×%.3f; тон G/R: база %.2f, светлая %.2f, тёмная %.2f" % [lg / l0, ld / l0, g.g / g.r, up.g / up.r, dn.g / dn.r])
	check(lg / l0 > 1.15 and lg / l0 < 1.4, "светлая полоса в допуске")
	check(ld / l0 < 0.85 and ld / l0 > 0.6, "тёмная полоса в допуске")
	# оттенок меняется, а не только яркость: отношение каналов отличается
	check(absf(up.g / up.r - g.g / g.r) > 0.05, "оттенок светлой сдвинут")
	check(absf(dn.b / dn.g - g.b / g.g) > 0.01, "оттенок тёмной сдвинут")
	# сатурация не растёт: светлая полоса менее насыщена
	check((up.g - up.r) / maxf(up.g, 1e-6) < (g.g - g.r) / g.g, "светлая не насыщеннее")
	# far = 0 → прежний цвет
	var z := tone(g, 1.0, 0.0, base, sl)
	approx(z.g, g.g, 1e-6, "far=0 — цвет не меняется")
