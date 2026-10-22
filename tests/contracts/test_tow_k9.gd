extends TestCase
## Контракт TW-К9 v2 (docs/contracts/tow.md): буксировщик TowTug - кинематика по траектории.

const DT := 1.0 / 120.0


func _tug(heading: float = 90.0) -> TowTug:
	var t := TowTug.new()
	t.setup(Vector3(10.0, 5.0, -20.0), heading, 80.0, func(_x: float, _z: float) -> float: return 5.0, {})
	return t


## Прогон: возвращает {max_jump} - наибольшее превышение |Δpos| над |vel|·dt (см).
func _run(t: TowTug, seconds: float, glider_agl: float, tension: float) -> float:
	var worst := 0.0
	for i in int(seconds / DT):
		var p0 := t.pos
		t.set_rope_tension(tension)
		t.step(DT, glider_agl)
		worst = maxf(worst, (t.pos - p0).length() - t.vel.length() * DT)
	return worst


func test_idle_and_placement() -> void:
	var t := _tug(90.0)
	check(t.phase == "idle", "idle до start()")
	var p := t.pos
	_run(t, 2.0, 0.0, 0.0)
	check(t.pos == p and t.vel == Vector3.ZERO, "до start() неподвижен")
	check(absf(t.pos.x - 90.0) < 1e-3 and absf(t.pos.z + 20.0) < 1e-3, "впереди начала на длину троса: %s" % t.pos)


func test_slack_then_roll_hold_climb() -> void:
	var t := _tug(90.0)
	var worst := 0.0
	t.start()
	check(t.phase == "slack", "start() - slack")
	worst = maxf(worst, _run(t, 3.0, 0.0, 0.0))
	check(t.phase == "slack" and absf(t.vel.length() - 1.0) < 1e-3, "slack: slack_speed_ms, фаза держится без натяжения")
	worst = maxf(worst, _run(t, 0.05, 0.0, 5.0))
	check(t.phase == "roll", "натяжение > 0 - roll")
	# дельтаплан не поднялся: остаёмся на земле на полной скорости
	worst = maxf(worst, _run(t, 30.0, 1.0, 50.0))
	check(t.phase == "roll" and t.agl_m == 0.0, "roll: на земле, пока дельтаплан ниже hold")
	approx(t.vel.length(), 60.0 / 3.6, 1e-3, "разгон до tow_speed_kmh")
	worst = maxf(worst, _run(t, 0.1, 3.5, 50.0))
	check(t.phase == "climb", "дельтаплан на 3 м - climb")
	worst = maxf(worst, _run(t, 5.0, 10.0, 50.0))
	approx(t.vel.length(), 60.0 / 3.6, 60.0 / 3.6 * 0.02, "скорость в climb ±2 %")
	approx(t.vel.y, 2.5, 2.5 * 0.05, "вертикальная скорость в climb ±5 %")
	check(t.agl_m > 5.0, "набрал высоту: %f" % t.agl_m)
	check(worst <= 0.01, "траектория непрерывна, избыток %f м" % worst)
	var fwd := -t.basis.z
	check(rad_to_deg(fwd.angle_to(t.vel.normalized())) < 1.0, "-Z basis вдоль vel")


func test_circuit_and_away() -> void:
	var t := _tug(0.0)
	t.start()
	_run(t, 0.1, 0.0, 5.0)
	_run(t, 30.0, 0.0, 50.0)
	var worst := _run(t, 0.1, 4.0, 50.0)
	check(t.phase == "climb", "climb")
	worst = maxf(worst, _run(t, 70.0, 50.0, 50.0))
	check(t.phase == "circuit", "circuit после circuit_start_agl_m (фаза %s)" % t.phase)
	approx(t.vel.length(), 60.0 / 3.6, 60.0 / 3.6 * 0.02, "скорость в circuit ±2 %")
	var h0 := atan2(t.vel.x, -t.vel.z)
	worst = maxf(worst, _run(t, 5.0, 50.0, 50.0))
	var h1 := atan2(t.vel.x, -t.vel.z)
	check(wrapf(h1 - h0, -PI, PI) < 0.0, "круг влево")
	check(t.basis.x.y > 0.0, "левый крен: правое крыло выше")
	check(worst <= 0.01, "непрерывность на кругах, избыток %f м" % worst)
	t.release()
	check(t.phase == "away", "release - away")
	var y0 := t.pos.y
	_run(t, 5.0, 50.0, 0.0)
	check(t.pos.y < y0 and t.vel.y < 0.0, "away: снижение")
	check(not t.gone, "ещё не убран")
	_run(t, 15.0, 50.0, 0.0)
	check(t.gone, "gone после away_s")


func test_release_on_roll_no_jump() -> void:
	var t := _tug(90.0)
	t.start()
	_run(t, 0.1, 0.0, 5.0)
	var worst := _run(t, 5.0, 0.0, 50.0)
	check(t.phase == "roll", "roll")
	var v0 := t.vel.length()
	t.release()
	check(t.phase == "away", "release на разбеге - away")
	worst = maxf(worst, _run(t, 1.0, 0.0, 0.0))
	check(t.vel.length() < v0 + 1.3, "скорость не скачет: %f -> %f" % [v0, t.vel.length()])
	worst = maxf(worst, _run(t, 20.0, 0.0, 0.0))
	check(worst <= 0.01, "траектория непрерывна, избыток %f м" % worst)
	check(t.agl_m > 0.0 or t.gone, "разбег закончился взлётом")
	_run(t, 20.0, 0.0, 0.0)
	check(t.gone, "gone после отрыва")
