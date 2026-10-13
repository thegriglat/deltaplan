extends TestCase
## scene-look SL-8: скотные тропы с высоты, CPU-зеркало формул sl_trails (scene_look.gdshaderinc;
## правятся вместе): тон полки и подъёма по солнцу, контраст полосы на 300 м, затухание к среднему
## при следе пикселя больше шага.

const A := 0.6
const B := 0.95


static func _sl() -> Dictionary:
	return Config.get_config("world").get("scene_look", {})


## = sl_trail_riser
static func riser(fr: float, w: float) -> float:
	return smoothstep(A - w, A + w, fr) * (1.0 - smoothstep(B - w, B + w, fr))


## Множитель тона в фазе fr. fw — след пикселя в долях шага, az_gap — азимут солнца минус
## азимут падения склона (0 — солнце с низовой стороны), el — высота солнца, градусы.
static func tone(fr: float, fw: float, slope_deg: float, az_gap: float, el: float, sl: Dictionary) -> float:
	var k := smoothstep(float(sl.trails_deg[0]), float(sl.trails_deg[0]) + 5.0, slope_deg)
	k *= 1.0 - smoothstep(float(sl.trails_deg[1]) - 5.0, float(sl.trails_deg[1]), slope_deg)
	k *= 1.0 - smoothstep(0.3, 0.7, fw)
	var w := clampf(0.05 + fw, 0.05, 0.3)
	var rm := riser(fr, w)
	var down := Vector3(1.0, 0.0, 0.0)   # вниз по склону
	var e := deg_to_rad(el)
	var g := deg_to_rad(az_gap)
	var l := Vector3(cos(e) * cos(g), sin(e), cos(e) * sin(g))
	var nr := Vector3(down.x, 0.15, down.z).normalized()
	var amb := float(sl.trails_ambient)
	var e_t := (amb + maxf(l.y, 0.0)) * (1.0 + float(sl.trails_tread_light))
	var e_r := amb + maxf(nr.dot(l), 0.0)
	var wr := B - A
	var mean_e := (1.0 - wr) * e_t + wr * e_r
	var t := lerpf(e_t, e_r, rm) / maxf(mean_e, 1e-3)
	return lerpf(1.0, t, k * float(sl.trails_strength))


## Контраст полосы: (полка − подъём) / среднее по периоду
static func contrast(fw: float, az_gap: float, el: float, sl: Dictionary) -> float:
	var s := 0.0
	var lo := 1e9
	var hi := -1e9
	var n := 400
	for i in n:
		var t := tone((i + 0.5) / n, fw, 25.0, az_gap, el, sl)
		s += t
		lo = minf(lo, t)
		hi = maxf(hi, t)
	return (hi - lo) / (s / n)


func test_keys() -> void:
	var sl := _sl()
	check(bool(sl.trails_enabled), "trails_enabled")
	check(float(sl.trails_step_m[0]) >= 1.0 and float(sl.trails_step_m[1]) <= 3.0, "шаг 1–3 м")


func test_contrast_at_300m() -> void:
	var sl := _sl()
	# 300 м, пиксель при вертикальном обзоре 60° и 1080 строках ≈ 0,33 м; склон 25° (tg 0,47),
	# шаг 2 м → след в долях шага = 0,33 · 0,47 / 2 ≈ 0,08
	var fw := 0.33 * tan(deg_to_rad(25.0)) / 2.0
	var against := contrast(fw, 0.0, 40.0, sl)    # солнце с низовой стороны: подъём освещён
	var behind := contrast(fw, 180.0, 40.0, sl)   # солнце с верховой стороны: подъём в тени
	print("         контраст полосы на 300 м, солнце 40°: подъём в тени %.2f, подъём освещён %.2f" % [behind, against])
	check(behind > 0.12, "тень подъёма заметна: %.2f" % behind)
	check(behind > against, "тень подъёма по солнцу сильнее")
	# полка светлее среднего, подъём в тени темнее
	check(tone(0.3, fw, 25.0, 180.0, 40.0, sl) > 1.0, "полка светлее")
	check(tone(0.78, fw, 25.0, 180.0, 40.0, sl) < 1.0, "подъём в тени темнее")


func test_fade_to_mean() -> void:
	var sl := _sl()
	var prev := 1e9
	for fw in [0.1, 0.3, 0.5, 0.7, 1.0, 2.0]:
		var c := contrast(fw, 180.0, 40.0, sl)
		print("         след %.1f шага: контраст %.3f" % [fw, c])
		check(c <= prev + 1e-6, "монотонно гаснет при fw=%.1f" % fw)
		prev = c
	check(contrast(0.7, 180.0, 40.0, sl) < 1e-6, "при следе 0,7 шага — ровно среднее")
	# среднее по периоду при затухании: сохраняется (профиль нулевого среднего)
	var s := 0.0
	for i in 400:
		s += tone((i + 0.5) / 400.0, 0.1, 25.0, 180.0, 40.0, sl)
	approx(s / 400.0, 1.0, 0.03 * float(sl.trails_strength) * 2.0, "среднее тона ≈ 1")


func test_slope_window() -> void:
	var sl := _sl()
	approx(tone(0.78, 0.05, 8.0, 180.0, 40.0, sl), 1.0, 1e-6, "полого — нет")
	approx(tone(0.78, 0.05, 45.0, 180.0, 40.0, sl), 1.0, 1e-6, "круче 35° — нет (скалы)")
	check(tone(0.78, 0.05, 25.0, 180.0, 40.0, sl) < 0.9, "25° — есть")
