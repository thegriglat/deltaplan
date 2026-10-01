extends TestCase
## Отрыв — только физика (К3 v3, отзыв пилота: «взлёт — когда крыло набрало скорость, 0 м в
## сильный ветер, ~10 м в штиль»): подъёмная сила от воздушной скорости (бег + ветер) против
## веса. Срывов и переходов по времени нет: без бега и ветра крыло не отрывается, в штиль пилот
## бежит, сколько нужно; бросил бежать — снова стоит.

const Sim := preload("res://tests/flight/flight_sim.gd")
## Трапеция на разбеге в штиль, (б): крыло → pitch. «Славутич» на 8° в штиль не взлетает ни с
## нейтральным носом (выходит на 7,15 м/с при N/W ≈ 0,02: L чуть меньше W), ни с α 19° (сопротивление
## больше — 6,52 м/с при V_отр 6,75) — упор в предел ног и поляру, не порог; поэтому здесь
## учебное и «спорт».
const PITCH := {"training": 0.15, "sport": 0.0}


static func ground_for(slope_deg: float) -> Callable:
	var k := tan(deg_to_rad(slope_deg))
	return func(_x: float, z: float) -> float: return 1000.0 + k * z  # вниз на север (−Z)


static func calm() -> Callable:
	return func(_p: Vector3) -> Vector3: return Vector3.ZERO


## (а) Штиль, без бега 10 с — стоя, нос нейтрально и «от себя» до упора, ровно и склон 17°.
func test_no_liftoff_without_run_or_wind() -> void:
	for w in ["slavutich_ut", "training", "sport"]:
		for slope in [0.0, 17.0]:
			for pitch in [0.0, 1.0]:
				var m := Sim.make(w)
				m.reset_on_ground(Vector3.ZERO, 0.0)
				Sim.run_for(m, 10.0, Sim.input(pitch), calm(), ground_for(slope))
				print(
					"    %s склон %.0f° pitch %+.0f, 10 с стоя: %s, сдвиг %.2f м"
					% [w, slope, pitch, m.phase(), Vector2(m.position.x, m.position.z).length()]
				)
				check(m.mode == FlightModel.Mode.GROUND, "%s %.0f° %+.0f: стоит (%s)" % [w, slope, pitch, m.phase()])


## Воздушная скорость, при которой вертикальная сила крыла = весу при текущем α и уклоне γ:
## L_верт = q·S·(C_L·cosγ + C_D·sin|γ|) (под горку поток снизу-спереди, сопротивление тоже
## поднимает) ⇒ V = √(2W / (ρ·S·(C_L·cosγ + C_D·sin|γ|))). Плоская формула — C_D = 0, γ = 0.
static func v_liftoff(m: FlightModel, slope_deg: float, flat_formula: bool) -> float:
	var c := m.aero_coefs(0.0)
	var g := deg_to_rad(slope_deg)
	var k := c.x if flat_formula else c.x * cos(g) + c.y * sin(g)
	return sqrt(2.0 * m.mass * Units.G / (m.rho * m.area * k))


## (б) Штиль, бег: отрыв, когда воздушная скорость дошла до V_отр (L = W); время — следствие
## уклона, а не порог.
func test_liftoff_at_lift_equals_weight() -> void:
	for w: String in PITCH:
		var times := []
		for slope in [8.0, 17.0]:
			var m := Sim.make(w)
			m.reset_on_ground(Vector3.ZERO, 0.0)
			var inp := Sim.input(float(PITCH[w]), 0.0, true)
			var gf := ground_for(slope)
			var t := 0.0
			var v_prev := 0.0
			while t < 30.0 and m.mode == FlightModel.Mode.GROUND:
				v_prev = m.velocity.length()  # скорость, с которой посчитана сила шага отрыва
				m.step(Sim.DT, inp, calm(), gf)
				t += Sim.DT
			var took := m.mode == FlightModel.Mode.AIR
			var v_need := v_liftoff(m, slope, false)
			var v_flat := v_liftoff(m, slope, true)
			var d := Vector2(m.position.x, m.position.z).length()
			print(
				(
					"    %s склон %.0f°: отрыв %s за %.2f с, %.1f м; V %.2f м/с, V_отр (L_верт = W) %.2f, "
					+ "√(2W/ρSC_L) %.2f, α %.1f°"
				)
				% [w, slope, took, t, d, v_prev, v_need, v_flat, rad_to_deg(m.alpha)]
			)
			check(took, "%s %.0f°: в штиль бегом — отрыв" % [w, slope])
			check(
				absf(v_prev - v_need) < 0.03 * v_need,
				"%s %.0f°: отрыв при V ≈ V_отр: %.2f vs %.2f" % [w, slope, v_prev, v_need]
			)
			times.append(t)
		check(absf(times[0] - times[1]) > 0.2, "%s: время отрыва зависит от уклона: %s" % [w, times])


## (в) Бег, затем отпустить Shift до отрыва — срыва нет, пилот снова стоит.
func test_stop_running_is_not_failure() -> void:
	var m := Sim.make("sport")
	m.reset_on_ground(Vector3.ZERO, 0.0)
	var gf := ground_for(17.0)
	Sim.run_for(m, 1.0, Sim.input(0.0, 0.0, true), calm(), gf)
	check(m.phase() == "running", "бежит: " + m.phase())
	Sim.run_for(m, 5.0, Sim.input(), calm(), gf)
	print("    бег 1 с, отпустил Shift на 5 с: %s, скорость %.2f м/с" % [m.phase(), m.velocity.length()])
	check(m.mode == FlightModel.Mode.GROUND, "бросил бежать — без срыва: %s %s" % [m.phase(), m.takeoff_failure])
	check(m.phase() == "standing", "снова стоит: " + m.phase())
	# и снова можно разбежаться
	Sim.run_for(m, 8.0, Sim.input(0.1, 0.0, true), calm(), gf)
	check(m.mode == FlightModel.Mode.AIR, "после остановки снова разбег и отрыв: " + m.phase())


## Время отрыва — следствие физики: разное на склонах 8° и 17° и при ветре 0/3/6 м/с («спорт»,
## нейтральный нос, только Shift); в сильный ветер — почти сразу.
func test_liftoff_time_from_physics() -> void:
	var table := {}
	for slope in [8.0, 17.0]:
		for wind in [0.0, 3.0, 6.0]:
			var m := Sim.make("sport")
			m.reset_on_ground(Vector3.ZERO, 0.0)
			var af := func(_p: Vector3) -> Vector3: return Vector3(0, 0, wind)
			var t := 0.0
			while t < 30.0 and m.mode == FlightModel.Mode.GROUND:
				m.step(Sim.DT, Sim.input(0.0, 0.0, true), af, ground_for(slope))
				t += Sim.DT
			var d := Vector2(m.position.x, m.position.z).length()
			print("    sport склон %.0f° ветер %.0f: %s за %.2f с, %.1f м" % [slope, wind, m.phase(), t, d])
			check(m.mode == FlightModel.Mode.AIR, "склон %.0f° ветер %.0f: взлёт" % [slope, wind])
			table[Vector2(slope, wind)] = t
	for wind in [0.0, 3.0]:
		check(
			table[Vector2(8.0, wind)] > table[Vector2(17.0, wind)],
			"ветер %.0f: на пологом склоне дольше" % wind
		)
	for slope in [8.0, 17.0]:
		check(
			table[Vector2(slope, 0.0)] > table[Vector2(slope, 3.0)] and table[Vector2(slope, 3.0)] > table[Vector2(slope, 6.0)],
			"склон %.0f°: сильнее ветер — короче разбег" % slope
		)


## В условиях старта и взлёта нет сравнений с константой времени (К3 v3): в GroundRun ни одно
## условие if/elif/while не использует *_time / *_s; в FlightModel нет прежних таймеров старта
## (_air_time, grace_s, fail_time_s, weak_run, max_run_time).
func test_no_time_thresholds_in_launch_code() -> void:
	var any_time := RegEx.create_from_string("^\\s*(if|elif|while)\\b.*(_time\\b|\\w+_s\\b)")
	var launch := RegEx.create_from_string("(_air_time|grace_s|fail_time_s|weak_run|max_run_time)")
	var gr := FileAccess.get_file_as_string("res://scripts/flight/ground_run.gd").split("\n")
	for i in gr.size():
		check(any_time.search(gr[i]) == null, "ground_run.gd:%d — условие по времени: %s" % [i + 1, gr[i].strip_edges()])
	var fm := FileAccess.get_file_as_string("res://scripts/flight/flight_model.gd").split("\n")
	for i in fm.size():
		check(launch.search(fm[i]) == null, "flight_model.gd:%d — таймер старта: %s" % [i + 1, fm[i].strip_edges()])
