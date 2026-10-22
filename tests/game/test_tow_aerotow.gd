extends Node
## Аэробуксировка в игре (TW-10b; docs/contracts/tow.md → TW-К5/К10, tow-trike.md → TT-К4): TowSession kind "aerotow" на Glider
## («Маятник», крыло sport, шаг 1/120 с, синтетическая ровная земля y = 0, без сети): пилот на тележке, Ан-2 впереди
## на длину троса, W, отрыв раньше буксировщика, набор, отцеп. Пилот-испытатель держит скорость (SpeedHold).

const Sim := preload("res://tests/flight/pendulum/pendulum_sim.gd")
const DT := 1.0 / 120.0
const CLIMB_K := 0.15
const CLIMB_KV := 0.3

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


class Run:
	extends RefCounted
	var g: Glider
	var s: TowSession
	var t := 0.0
	var w_at := 1.0
	var flat_fn := func(_x: float, _z: float) -> float: return 0.0
	## Первая секунда (с), когда: крыло в воздухе; буксировщик не на разбеге.
	var t_air := -1.0
	var t_climb := -1.0
	var h_max_ground_tug := 0.0  ## макс. высота дельтаплана, пока буксировщик на земле (slack/roll), м
	var tmax := 0.0

	func _init(host: Node, models := false) -> void:
		g = Glider.new()
		g.setup("sport", 0.0)
		g.model = Sim.make("sport")
		g.set_ground_fn(flat_fn)
		g.reset_on_ground(Vector3.ZERO, 0.0)
		s = TowSession.new()
		host.add_child(s)
		var site := {
			"start_pos": Vector3.ZERO,
			"end_pos": Vector3(0.0, 0.0, -300.0),
			"heading_deg": 0.0,
		}
		s.setup(g, flat_fn, site, "aerotow", models)

	func step(release := false) -> void:
		var w := t >= w_at
		var c := Sim.input(0.0, 0.0)
		if g.phase() == "flying":
			# Скорость задаёт трос; пилот держит высоту ≈3,5 м над колёсами Ан-2 (ПД по высоте и вертикальной скорости
			# относительно Ан-2): на разбеге — у земли, в наборе — следом за ним
			var h_t := s.tug.agl_m + 3.5
			var vz_rel: float = g.model.velocity.y - s.tug.vel.y
			c.pitch = clampf(CLIMB_K * (h_t - s.glider_agl_m()) - CLIMB_KV * vz_rel, -1.0, 1.0)
		g.set_input(c)
		s.step(DT, w, release)
		g.step(DT)
		t += DT
		tmax = maxf(tmax, g.model.link_tension_n)
		if t_air < 0.0 and g.phase() == "flying":
			t_air = t
		if s.tug.phase in ["slack", "roll"]:
			h_max_ground_tug = maxf(h_max_ground_tug, s.glider_agl_m())
		if t_climb < 0.0 and s.tug.phase == "climb":
			t_climb = t

	func dispose() -> void:
		s.queue_free()
		g.free()


func test_idle_before_w() -> void:
	# (1) до W 10 с: тележка и крыло стоят, натяжения нет, Ан-2 на месте впереди на длину троса
	var r := Run.new(self)
	r.w_at = 1.0e9
	check(r.g.phase() == "dolly" and r.g.dolly_attached(), "пилот на тележке: %s" % r.g.phase())
	var x0: Vector3 = r.g.model.pilot_position
	var tug0 := r.s.tug.pos
	check(Vector2(tug0.x, tug0.z + 80.0).length() < 0.05 and tug0.y > 0.3 and tug0.y < 1.2, "буксировщик (tow_hook) в 80 м впереди старта: %s" % tug0)
	for i in int(10.0 / DT):
		r.step()
	check(r.tmax == 0.0 and r.s.line.tension_n == 0.0, "до W натяжение 0: %.1f Н" % r.tmax)
	check(r.s.line.phase == "idle" and r.s.tug.phase == "idle", "фазы idle: %s %s" % [r.s.line.phase, r.s.tug.phase])
	check(r.g.model.pilot_position.distance_to(x0) < 0.05, "пилот на месте")
	check(r.s.tug.pos.distance_to(tug0) < 1.0e-6, "Ан-2 стоит")
	check(r.g.phase() == "dolly", "всё ещё на тележке")
	r.dispose()


func test_takeoff_before_tug_and_climb() -> void:
	# (2) W: слабину выбирает буксировщик, тележка с крылом катятся, отрыв раньше буксировщика, ≤ 6 м, пока он на земле;
	# (3) буксировщик взлетает, набор, натяжение ниже слабого звена
	var r := Run.new(self)
	var dolly_moved := 0.0
	for i in int(70.0 / DT):
		r.step()
		if r.t < r.w_at + 3.0:
			dolly_moved = maxf(dolly_moved, r.g.dolly_vel().length())
	print("    отрыв %.1f с, буксировщик climb %.1f с, высота при буксировщике на земле ≤ %.1f м, T max %.0f Н, фаза %s, высота пилота %.0f м, Ан-2 agl %.0f м"
		% [r.t_air, r.t_climb, r.h_max_ground_tug, r.tmax, r.s.tug.phase, r.g.model.pilot_position.y, r.s.tug.agl_m])
	check(r.s.line.phase != "idle", "после W трос пошёл")
	check(r.t_air > 0.0, "дельтаплан оторвался от тележки")
	check(r.t_climb < 0.0 or r.t_air < r.t_climb, "отрыв раньше, чем буксировщик ушёл с разбега: %.1f против %.1f" % [r.t_air, r.t_climb])
	check(r.h_max_ground_tug <= 6.0, "пока Ан-2 на земле, дельтаплан ≤ 6 м: %.1f" % r.h_max_ground_tug)
	check(r.s.tug.phase in ["climb", "circuit"], "буксировщик взлетел: %s" % r.s.tug.phase)
	check(r.g.model.pilot_position.y > 30.0, "набор высоты: %.0f м" % r.g.model.pilot_position.y)
	check(r.tmax < 1250.0, "T ниже слабого звена: %.0f Н" % r.tmax)
	check(r.s.is_attached(), "трос в силе")
	check(not r.g.dolly_attached(), "тележка осталась")
	r.dispose()


func test_release_tug_away_dolly_stays() -> void:
	# (4) отцеп: сила 0, Ан-2 → away, трос step_free, тележка стоит на полосе
	var r := Run.new(self)
	for i in int(50.0 / DT):
		r.step()
	var h0: float = r.g.model.pilot_position.y
	r.step(true)
	r.step()
	check(r.s.ended_reason == "pilot" and not r.s.is_attached(), "отцеп: %s" % r.s.ended_reason)
	check(r.g.model.link_tension_n == 0.0 and r.g.model.external_force_n == Vector3.ZERO, "сила снята")
	check(r.s.tug.phase == "away", "Ан-2 уходит: %s" % r.s.tug.phase)
	var end0 := r.s.line.end_pos
	for i in int(4.0 / DT):
		r.step()
	check(r.s.line.end_pos.distance_to(end0) > 0.1, "свободный трос движется")
	for i in int(20.0 / DT):
		r.step()
	check(r.s.tug.gone, "через away_s Ан-2 убран")
	check(not r.g.dolly_attached() and r.g.dolly_vel().length() < 1.0e-3, "тележка стоит: v=%.4f" % r.g.dolly_vel().length())
	check(r.g.dolly_pos().y == 0.0 and r.g.dolly_pos().z < 0.0, "тележка на полосе: %s" % r.g.dolly_pos())
	check(Sim.finite(r.g.model) and r.g.phase() == "flying", "полёт продолжается")
	check(r.g.model.pilot_position.y > h0 - 40.0, "высота не потеряна сразу: %.0f → %.0f" % [h0, r.g.model.pilot_position.y])
	r.dispose()


func test_release_on_dolly_and_reset() -> void:
	# отцеп до отрыва: тележка остаётся «dolly», останавливается; reset() — снова на старте, Ан-2 на месте
	var r := Run.new(self)
	for i in int(6.0 / DT):
		r.step()
	r.step(true)
	for i in int(30.0 / DT):
		r.step()
	check(r.g.phase() == "dolly" and r.g.dolly_vel().length() < 0.01, "отцеп на тележке: стоит, %s" % r.g.phase())
	r.s.reset()
	check(r.g.phase() == "dolly" and r.s.tug.phase == "idle" and r.s.is_attached() and r.s.line.phase == "idle", "reset: всё снова лежит")
	check(Vector2(r.s.tug.pos.x, r.s.tug.pos.z + 80.0).length() < 0.05, "буксировщик вернулся: %s" % r.s.tug.pos)
	r.dispose()


func test_models() -> void:
	# модели: Ан-2 из пасхалки (build_model), тележка, отцеп; у Ан-2 хвост в точке троса
	var r := Run.new(self, true)
	r.s._process(0.0)
	check(r.s.tug_node != null and r.s.dolly_node != null and r.s.release_node != null, "модели есть")
	check(r.s.winch_node == null and r.s.drogue_node == null, "лебёдки и купола нет")
	var pt: Vector3 = r.s.tug_node.transform * Vector3(0.0, EggAn2.GEAR_BOTTOM_Y + 1.5, EggAn2.TAIL_Z)
	check(pt.distance_to(r.s.tug.pos) < 0.01, "точка троса на хвосте: %s" % pt)
	check(r.s.dolly_node.transform.origin.distance_to(r.g.dolly_pos()) < 0.01, "тележка на земле под перекладиной")
	check(r.s.release_node.visible, "отцеп виден")
	r.dispose()
