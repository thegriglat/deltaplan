class_name PendulumTouchdown
extends RefCounted
## Оценка касания «Маятника» (PD-35): пилот встаёт на ноги. Своя обёртка над LandingJudge (пороги
## по вертикальной, крену и авария — его, flight.json → landing); по горизонтальной — ноги:
## - до stand_max_ms пилот встаёт на ноги (шаг-два);
## - до run_max_ms — пробегает: ноги гасят скорость с flight.json → landing.runout_decel_ms2 (тем же,
##   с которым модель гасит пробежку после касания), шаги — с периодом step_period_s;
## - быстрее — не выбегает: жёстко (падает вперёд, на колени, на трапецию).
## Касание не ступнями: трапеция раньше ступней — жёстко («на трапецию»), нос, консоль — авария (PD-К1).
## result — как у LandingJudge.evaluate (grade, vertical_speed_ms, horizontal_speed_ms, bank_deg) плюс
## touchdown ("stood" / "ran" / "hard" / "crash"), runout_m, steps.

var run_max: float = 5.0  ## наибольшая горизонтальная, которую пилот выбегает, м/с
var stand_max: float = 2.0  ## до этой горизонтальной пилот встаёт на ноги, м/с
var step_period: float = 0.33  ## период шага на пробежке, с


func setup(td: Dictionary) -> void:
	run_max = float(td.get("run_max_ms", run_max))
	stand_max = float(td.get("stand_max_ms", stand_max))
	step_period = float(td.get("step_period_s", step_period))


## velocity — скорость ЦМ пилота в момент касания (оси игры), normal — нормаль к земле, bank_deg —
## крен крыла, contact — "feet" | "bar" | "nose" | "wingtip"; lc — flight.json → landing.
func evaluate(velocity: Vector3, normal: Vector3, bank_deg: float, contact: String, lc: Dictionary) -> Dictionary:
	var r := LandingJudge.evaluate(velocity, normal, bank_deg, lc)
	var vn := float(r.vertical_speed_ms)
	var vt := float(r.horizontal_speed_ms)
	var grade := String(r.grade)
	if grade != "crash":
		if contact != "feet" and contact != "bar":
			grade = "crash"  # крыло в землю раньше ног
		elif (
			contact == "bar" or vn >= float(lc.hard_vertical_ms) or vt > run_max
			or absf(bank_deg) > float(lc.soft_bank_deg)
		):
			grade = "hard"
		else:
			grade = "soft"
	r["grade"] = grade
	r["contact"] = contact
	var decel := maxf(float(lc.runout_decel_ms2), 0.1)
	r["runout_m"] = 0.0 if grade == "crash" else vt * vt / (2.0 * decel)
	r["steps"] = 0 if grade == "crash" else roundi(vt / decel / step_period)
	if grade == "soft":
		r["touchdown"] = "stood" if vt <= stand_max else "ran"
	else:
		r["touchdown"] = grade
	return r
