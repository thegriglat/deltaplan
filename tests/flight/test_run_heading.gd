extends TestCase
## Курс на разбеге без управления курсом (Онгудай: склон ≈ 17°, встречный ветер у земли).

const Sim := preload("res://tests/flight/flight_sim.gd")
const SLOPE := 0.3  ## уклон 17° (старт Онгудая), вниз на север (−Z)


static func ground(_x: float, z: float) -> float:
	return 1000.0 + SLOPE * z


## Ветер: встречный head м/с + порывы и турбулентность у земли (вертикальная и боковая
## составляющие меняются по размаху и во времени), amp м/с.
static func gusty(head: float, amp: float, t_ref: Array) -> Callable:
	return func(p: Vector3) -> Vector3:
		var t: float = t_ref[0]
		return Vector3(
			amp * sin(1.7 * t + 0.9 * p.x),
			amp * sin(2.3 * t + 1.3 * p.x + 0.4),
			head + amp * sin(1.1 * t + 0.5 * p.x)
		)


## Разбег с места до отрыва с постоянным roll; → {took_off, dh_deg (макс. отклонение курса), t}.
static func run(wing: String, head: float, amp: float, roll: float) -> Dictionary:
	var m := Sim.make(wing)
	m.reset_on_ground(Vector3.ZERO, 0.0)
	var t_ref := [0.0]
	var af := gusty(head, amp, t_ref)
	var inp := Sim.input(0.0, roll, true)
	var out := {"took_off": false, "dh_deg": 0.0, "t": 0.0}
	while t_ref[0] < 12.0:
		m.step(Sim.DT, inp, af, ground)
		t_ref[0] += Sim.DT
		out.dh_deg = maxf(out.dh_deg, absf(rad_to_deg(m.heading)))
		if m.mode == FlightModel.Mode.AIR:
			out.took_off = true
			break
		if m.mode == FlightModel.Mode.FAILED:
			break
	out.t = t_ref[0]
	return out


## Допуск 3°: без руля курс уводит только крен от порывов (g·sinφ/v при разгруженных ногах);
## в замерах игры (нейросеть ветра, Онгудай, 0–6 м/с) — до 0,6°; синтетические порывы 1 м/с (сильнее реальных у земли) — до 2,8°. Заметный поворот (>3°) за
## разбег ≈ 10 м — уже руль (несколько метров вбок).
const TOL_DEG := 3.0


func test_no_roll_keeps_heading() -> void:
	for p in Config.list_configs("wings"):
		var w := String(p).get_file()
		for head in [0.0, 3.0, 6.0]:
			for amp in [0.0, 0.5, 1.0]:
				var r := run(w, head, amp, 0.0)
				print("    %s v=%.0f gust=%.1f: dh=%.2f° t=%.1f" % [w, head, amp, r.dh_deg, r.t])
				check(r.dh_deg <= TOL_DEG, "%s ветер %.0f порыв %.1f: курс ушёл на %.2f°" % [w, head, amp, r.dh_deg])


func test_roll_sensitivity_report() -> void:
	for roll in [0.02, 0.05, 0.1, 0.3, 1.0]:
		var r := run("sport", 3.0, 0.0, roll)
		print("    ручка крена %.2f (%.1f°): курс за разбег %.1f°, t=%.1f" % [roll, roll * 15.0, r.dh_deg, r.t])


## Залипший толчок мыши по крену на земле гаснет (bar_ground_roll_return_per_s), в воздухе — нет.
func test_ground_mouse_roll_returns() -> void:
	var ic := InputController.new()
	ic.reload_config()
	ic.on_ground = true
	ic._mouse_offset = Vector2(0.1, 0.1)
	for i in 240:  # 2 с
		ic.update(Sim.DT)
	check(absf(ic._mouse_offset.x) < 0.001, "на земле крен мыши вернулся: %.3f" % ic._mouse_offset.x)
	check(absf(ic._mouse_offset.y - 0.1) < 0.001, "нос мыши не трогается: %.3f" % ic._mouse_offset.y)
	ic.on_ground = false
	ic._mouse_offset = Vector2(0.1, 0.1)
	for i in 240:
		ic.update(Sim.DT)
	check(absf(ic._mouse_offset.x - 0.1) < 0.001, "в воздухе трапеция держит: %.3f" % ic._mouse_offset.x)
	ic.free()
