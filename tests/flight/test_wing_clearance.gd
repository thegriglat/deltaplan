extends Node
## Крыло не уходит в землю на старте (SF-4, docs/flight.md → «Поза крыла на земле»).
## Реальная модель крыла (вершины сеток под нодой Wing, с трапецией) в позе планера
## Transform3D(Telemetry.basis, ступни) — зазор до рельефа по вертикали
## (tools/flight/wing_clearance.gd). Штиль, крен 0 (A/D не нажаты, ветра нет):
##   ровно и склон 20° вниз по курсу — стоит (трапеция нейтрально и до упора в обе стороны),
##   шагом, разбег до отрыва (или срыва) — наименьший зазор ≥ MIN_CLEARANCE_M;
##   косой склон 15° — только фиксируем число (верхняя консоль близко к склону — так и есть).
## Таблица по всем стартам — tools/flight/wing_clearance_run.tscn.

const WC := preload("res://tools/flight/wing_clearance.gd")
const DT := 1.0 / 120.0
const SAMPLE_EVERY := 12
## Наименьший допустимый зазор, м. Сетка рельефа рисуется треугольниками по узлам (25 м), а ступни
## стоят на билинейной высоте: на старте altai/sinyukha_west рисуемая земля под крылом до 0,32 м
## выше билинейной (замер wing_clearance_run: clear_min − clear_rendered, до SF-4). Зазор 0,3 м
## на синтетическом рельефе — чтобы на настоящем крыло не уходило в рисуемую землю.
const MIN_CLEARANCE_M := 0.3

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


static func _ground(kind: String) -> Callable:
	match kind:
		"склон 20°":
			return func(_x: float, z: float) -> float: return 100.0 + tan(deg_to_rad(20.0)) * z
		"косой 15°":
			return func(x: float, _z: float) -> float: return 100.0 + tan(deg_to_rad(15.0)) * x
	return func(_x: float, _z: float) -> float: return 100.0


static func _ctl(pitch: float, run: bool, walk: float, roll: float = 0.0) -> ControlInput:
	var c := ControlInput.new()
	c.pitch = pitch
	c.roll = roll
	c.run = run
	c.walk = walk
	return c


## Наименьший зазор за фазу: {min, part, bank_deg (наибольший |крен|), theta_deg}.
func _phase(g: Glider, pts: Dictionary, gf: Callable, inp: ControlInput, secs: float) -> Dictionary:
	var m := g.model
	m.reset_on_ground(Vector3(0, gf.call(0.0, 0.0), 0), 0.0)
	var zero := func(_p: Vector3) -> Vector3: return Vector3.ZERO
	var res := {"min": INF, "part": "", "bank_deg": 0.0, "theta_deg": 0.0}
	var n := 0
	while n * DT < secs:
		m.step(DT, inp, zero, gf)
		n += 1
		if m.mode != FlightModel.Mode.GROUND:
			break
		res.bank_deg = maxf(res.bank_deg, absf(rad_to_deg(m.bank)))
		if n % SAMPLE_EVERY != 0:
			continue
		var c := WC.clearance(pts, WC.pose(m), gf)
		if c.min < res.min:
			res.min = c.min
			res.part = c.part
			res.theta_deg = rad_to_deg(m.theta)
	return res


func test_wing_above_ground_on_launch() -> void:
	var phases := {
		"стоит": [_ctl(0, false, 0), 3.0],
		"стоит, нос вверх до упора": [_ctl(1, false, 0), 3.0],
		"стоит, нос вниз до упора": [_ctl(-1, false, 0), 3.0],
		"шагом": [_ctl(0, false, 1), 4.0],
		"разбег": [_ctl(0, true, 0), 12.0],
		# SF-3: A/D на земле — только курс, крыло не кренит
		"стоит, A": [_ctl(0, false, 0, -1), 3.0],
		"стоит, D": [_ctl(0, false, 0, 1), 3.0],
		"разбег, A": [_ctl(0, true, 0, -1), 12.0],
	}
	for p in Config.list_configs("wings"):
		var w := String(p).get_file()
		var g := WC.make_glider(self, w)
		var pts := WC.wing_points(g.visual)
		check((pts.tips as PackedVector3Array).size() > 0, "%s: у модели найдены консоли" % w)
		for kind: String in ["ровно", "склон 20°", "косой 15°"]:
			var gf := _ground(kind)
			var worst := {"min": INF}
			for ph: String in phases:
				var r := _phase(g, pts, gf, phases[ph][0], phases[ph][1])
				# на косом склоне рука пилота держит крыло с пределом силы: у крупных тяжёлых крыльев
				# (размах > 10 м, 30+ кг — Cross Country, Crossover) на разбеге с A/D остаётся до ~0,7° —
				# незаметно; на ровном и склоне вниз — прежние 0,5°
				var bank_tol := 1.0 if kind == "косой 15°" else 0.5
				check(r.bank_deg < bank_tol, "%s %s %s: крен 0 (%.2f°)" % [w, kind, ph, r.bank_deg])
				# стоя с A/D на склоне пилот разворачивается поперёк склона — это уже косой склон
				# (верхняя консоль у земли — правда жизни), зазор только фиксируем
				var across := kind == "склон 20°" and ph.contains(",") and not ph.contains("нос")
				if kind != "косой 15°" and not across:
					check(
						r.min >= MIN_CLEARANCE_M,
						(
							"%s %s %s: зазор крыла %.2f м (%s, тангаж %.1f°) ≥ %.2f"
							% [w, kind, ph, r.min, r.part, r.theta_deg, MIN_CLEARANCE_M]
						)
					)
				if across:
					print("         %s %s %s: зазор %.2f м (%s)" % [w, kind, ph, r.min, r.part])
				if r.min < worst.min and not across:
					worst = r
					worst.phase = ph
			print(
				(
					"         %s %s: наименьший зазор %.2f м (%s, %s, тангаж %.1f°)"
					% [w, kind, worst.min, worst.part, worst.phase, worst.theta_deg]
				)
			)
			check(is_finite(worst.min), "%s %s: зазор измерен" % [w, kind])
		g.free()
