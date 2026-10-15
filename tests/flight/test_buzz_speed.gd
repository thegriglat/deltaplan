extends Node
## SPF-2 / SPF-К1 v2: частоты тряски кабины ∝ V/V_трим, фаза непрерывна, амплитуда — без множителя
## скорости, в спокойном воздухе тряски нет.

const DT := 1.0 / 60.0

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func _glider() -> Glider:
	var g := Glider.new()
	g.wing_id = "sport"
	add_child(g)
	return g


func _run(g: Glider, v: float, turb: float, n: int, skip: int = 0) -> Dictionary:
	var crossings := 0
	var peak := 0.0
	var prev := 0.0
	for i in n:
		g.visual.set_flight(v, 0.0, turb)
		g.visual.set_pose(0.0, 0.0, true, DT)
		if i < skip:
			continue
		var y: float = g.visual.buzz.y
		peak = maxf(peak, g.visual.buzz.length())
		if prev != 0.0 and signf(y) != signf(prev):
			crossings += 1
		prev = y
	return {"cross": crossings, "peak": peak}


func test_calm_zero() -> void:
	var g := _glider()
	var vt: float = g.model.trim_speed()
	for v in [Units.kmh(30.0), Units.kmh(80.0), vt]:
		var r := _run(g, v, 0.0, 120)
		check(g.visual.buzz.is_zero_approx(), "спокойный воздух, %.1f м/с: buzz = 0 (%s)" % [v, g.visual.buzz])
		check(r.peak < 1e-5, "спокойный воздух: пик %.6f" % r.peak)
	g.free()


func test_frequency_scales_with_speed() -> void:
	var g := _glider()
	var vt: float = g.model.trim_speed()
	var n := 1200
	var base := _run(g, vt, 1.0, n, 120)
	var fast := _run(g, vt * 1.6, 1.0, n, 120)
	var slow := _run(g, vt * 0.8, 1.0, n, 120)
	var r_fast := float(fast.cross) / maxf(float(base.cross), 1.0)
	var r_slow := float(slow.cross) / maxf(float(base.cross), 1.0)
	print("         пересечений нуля: V_трим %d, 1,6× %d, 0,8× %d" % [base.cross, fast.cross, slow.cross])
	check(absf(r_fast - 1.6) < 0.25, "частота при 1,6·V_трим в ~1,6 раза выше (%.2f)" % r_fast)
	check(absf(r_slow - 0.8) < 0.15, "частота при 0,8·V_трим в ~0,8 раза (%.2f)" % r_slow)
	var mx := float(Config.get_config("flight").visual.buzz.max_m)
	check(fast.peak <= mx + 1e-6 and base.peak <= mx + 1e-6, "max_m сохраняется")
	# предел множителя: 5·V_трим ведёт себя как 2·V_трим
	var huge := _run(g, vt * 5.0, 1.0, n, 120)
	var two := _run(g, vt * 2.0, 1.0, n, 120)
	check(absf(float(huge.cross) - float(two.cross)) <= 0.1 * float(two.cross) + 2.0, "r_f ограничен сверху (%d vs %d)" % [huge.cross, two.cross])
	g.free()


func test_amplitude_not_scaled() -> void:
	var g := _glider()
	var vt: float = g.model.trim_speed()
	var a := _run(g, vt, 1.0, 900, 300)
	var b := _run(g, vt * 1.6, 1.0, 900, 300)
	check(absf(float(a.peak) - float(b.peak)) < 0.004, "амплитуда от скорости не множится (%.4f vs %.4f)" % [a.peak, b.peak])
	g.free()


func test_phase_continuous() -> void:
	var g := _glider()
	var vt: float = g.model.trim_speed()
	_run(g, vt, 1.0, 300)
	var maxd := 0.0
	var prev: Vector3 = g.visual.buzz
	for i in 120:
		g.visual.set_flight(vt, 0.0, 1.0)
		g.visual.set_pose(0.0, 0.0, true, DT)
		maxd = maxf(maxd, g.visual.buzz.distance_to(prev))
		prev = g.visual.buzz
	var sw := 0.0
	for i in 120:
		g.visual.set_flight(vt * 2.0, 0.0, 1.0)
		g.visual.set_pose(0.0, 0.0, true, DT)
		if i < 3:
			sw = maxf(sw, g.visual.buzz.distance_to(prev))
		prev = g.visual.buzz
	check(sw <= maxd * 2.2 + 1e-4, "смена скорости не даёт скачка (шаг %.5f, обычно до %.5f)" % [sw, maxd])
	g.free()
