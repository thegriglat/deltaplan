extends TestCase
## Напарник (WM-К1, BotPilots.wingmen): «типичный день» на аналитическом мире — как test_bots:
## вершина с площадкой и склоном 20° на север, равнина 100 м, ветер 2,5 м/с с севера, 5 термиков
## ~3,5 м/с (радиус ~120 м, потолок ~2000 м) вдоль линии от старта с шагом 1,5 км. Игрок —
## скрипт: кружит в термике 240 с (набор 1,5 м/с), переходит к следующему ~11 м/с со снижением
## ~1 м/с. Напарник (agents[0]) держится рядом; контроль — тот же сценарий без напарников.
## Варианты (пороги те же): основной; бот стартует с запада и выше игрока на 200 м; шаг термиков 1,2 км.

const DT := 1.0 / 120.0
const START := Vector3(0.0, 300.0, -1.0)
const STEP_Z := -1500.0
## Шаг термиков текущего прогона, м (вариант сценария; по умолчанию STEP_Z).
var step_z := STEP_Z
const N_THERMALS := 5
const CIRCLE_S := 240.0
const R := 60.0
const V := 11.0
const DAY_S := 1260.0


static func hill(_x: float, z: float) -> float:
	if z >= 0.0:
		return 300.0
	return maxf(100.0, 300.0 + z * tan(deg_to_rad(20.0)))


func centre(i: int) -> Vector2:
	return Vector2(0.0, step_z * (i + 1))


func air(p: Vector3) -> Vector3:
	var w := -0.3
	if p.y < 2000.0:
		for i in N_THERMALS:
			var r := Vector2(p.x, p.z).distance_to(centre(i))
			w += 3.5 * exp(-pow(r / 120.0, 2.0))
	return Vector3(0.0, w, 2.5)


func make(count: int, wingmen: int) -> BotPilots:
	var b := BotPilots.new()
	b.visuals_enabled = false
	b.wingmen = wingmen
	(
		b
		. setup(
			{
				"air_fn": air,
				"ground_fn": hill,
				"start": Vector3(START.x, hill(START.x, START.z), START.z),
				"heading_deg": 0.0,
				"count": count,
				"seed": 0,
				"airborne_share": 0.0,
			}
		)
	)
	return b


## Скриптовый игрок: состояние кружения/перехода (шаг dt).
class Pilot:
	var t := Telemetry.new()
	var idx := 0
	var circling := true
	var timer := 0.0
	var theta0 := 0.0
	var alt0 := 700.0
	var pos := Vector3.ZERO
	var step := STEP_Z

	func _c(i: int) -> Vector2:
		return Vector2(0.0, step * (i + 1))

	func _init(step_m: float = STEP_Z) -> void:
		step = step_m
		t.phase = "flying"
		_put_circle()

	func _put_circle() -> void:
		var c := _c(idx)
		var ang := theta0 - V / R * timer
		var off := Vector2(sin(ang), -cos(ang)) * R
		pos = Vector3(c.x + off.x, alt0 + 1.5 * timer, c.y + off.y)
		var tv := Vector2(-cos(ang), -sin(ang)) * V
		t.position = pos
		t.velocity = Vector3(tv.x, 1.5, tv.y)
		t.heading_deg = fposmod(rad_to_deg(atan2(tv.x, -tv.y)), 360.0)

	func advance(dt: float) -> void:
		timer += dt
		if circling:
			_put_circle()
			if timer >= CIRCLE_S and idx + 1 < N_THERMALS:
				circling = false
				timer = 0.0
			return
		var tgt := _c(idx + 1)
		var d := Vector2(tgt.x - pos.x, tgt.y - pos.z)
		if d.length() <= R:
			idx += 1
			var rel := Vector2(pos.x, pos.z) - tgt
			theta0 = atan2(rel.x, -rel.y)
			alt0 = pos.y
			circling = true
			timer = 0.0
			_put_circle()
			return
		var u := d.normalized()
		pos += Vector3(u.x * V * dt, -1.0 * dt, u.y * V * dt)
		t.position = pos
		t.velocity = Vector3(u.x * V, -1.0, u.y * V)
		t.heading_deg = fposmod(rad_to_deg(atan2(u.x, -u.y)), 360.0)


## Сутки сценария: возвращает {med, share, end_air, close, n, min_d} по замерам agents[0].
## Старт бота: dx — смещение к востоку от игрока (отрицательное — к западу), м; dy — по высоте.
## step_m — шаг термиков, м (отрицательное z — вдоль линии от старта).
func scenario(wingmen: int, dx := 500.0, dy := -60.0, step_m := STEP_Z) -> Dictionary:
	step_z = step_m
	var b := make(4, wingmen)
	var pl := Pilot.new(step_m)
	var a := b.agents[0]
	# Бот в воздухе в |dx| м от игрока, курс на него.
	var p0 := Vector3(pl.pos.x + dx, pl.pos.y + dy, pl.pos.z)
	a.start_in_air(p0, 270.0 if dx > 0.0 else 90.0, 0.0)
	var dist: Array[float] = []
	var close := 0
	var min_d := INF
	var t := 0.0
	var next := 0.0
	while t < DAY_S:
		pl.advance(DT)
		b.tick(DT, pl.t)
		t += DT
		if t < next:
			continue
		next += 0.5
		if t < 120.0:
			continue
		# Не в воздухе (сел) — замер «далеко», а не пропуск.
		if not a.is_airborne():
			dist.append(INF)
			continue
		var ta := a.telemetry()
		if ta.altitude_agl < 30.0:
			continue
		var dh := Vector2(ta.position.x - pl.pos.x, ta.position.z - pl.pos.z).length()
		var dv := absf(ta.position.y - pl.pos.y)
		dist.append(dh)
		min_d = minf(min_d, Vector2(dh, dv).length())
		if dh < 50.0 and dv < 15.0:
			close += 1
	var res := {"n": dist.size(), "close": close, "min_d": min_d, "end_air": a.is_airborne()}
	dist.sort()
	res["med"] = dist[dist.size() / 2] if not dist.is_empty() else INF
	var within := 0
	for d in dist:
		within += 1 if d <= 1000.0 else 0
	res["share"] = float(within) / maxf(dist.size(), 1)
	b.free()
	return res


## Пороги одного варианта сценария; контроль (без напарника) — только на основном.
func _check_variant(
	name: String, dx: float, dy: float, step_m: float, with_control: bool
) -> void:
	var w := scenario(1, dx, dy, step_m)
	var msg := (
		"[%s] напарник: медиана %.0f м, доля ≤1000 м %.2f, замеров %d, мин. %.0f м, близких %d"
		% [name, w.med, w.share, w.n, w.min_d, w.close]
	)
	var c := {}
	if with_control:
		c = scenario(0, dx, dy, step_m)
		msg += "; контроль: медиана %.0f м, доля %.2f" % [c.med, c.share]
	print("wingman ", msg)
	check(w.n > 1000, "замеров достаточно: %s" % msg)
	check(w.med <= 600.0, "медиана дистанции ≤ 600 м: %s" % msg)
	check(w.share >= 0.75, "доля замеров ≤ 1000 м ≥ 0,75: %s" % msg)
	check(w.end_air, "напарник в воздухе в конце: %s" % msg)
	check(w.close == 0, "ближе 50 м / 15 м замеров %d: %s" % [w.close, msg])
	if with_control:
		check(c.med >= 1.5 * w.med, "контроль (без напарника) дальше в 1,5 раза: %s" % msg)


func test_wingman_stays_near() -> void:
	_check_variant("основной", 500.0, -60.0, STEP_Z, true)


## Напарник стартует к западу от игрока и выше него на 200 м.
func test_wingman_west_above() -> void:
	_check_variant("запад +200 м", -500.0, 200.0, STEP_Z, false)


## Шаг термиков 1,2 км и 2 км.
func test_wingman_step_1200() -> void:
	_check_variant("шаг 1,2 км", 500.0, -60.0, -1200.0, false)


## Границы модели (не проверка): термики через 1,8 и 2 км при старте бота на 60 м ниже игрока.
## Игрок уходит из термика на ~1060 м, бот — на ~400 м: за 2 км по 8:1 он теряет ~240 м и садится
## или отстаёт на один термик. Числа — в отчёте задачи WMN-4.
func test_wingman_wide_steps_info() -> void:
	for st in [-1800.0, -2000.0]:
		var w := scenario(1, 500.0, -60.0, st)
		print(
			"wingman [инфо, шаг %.0f м] медиана %.0f м, доля ≤1000 м %.2f, в воздухе в конце %s"
			% [-st, w.med, w.share, w.end_air]
		)


## Игрок на земле — ведущего нет, напарник летает как обычный бот.
func test_standing_player_no_lead() -> void:
	var b := make(2, 1)
	var a := b.agents[0]
	a.start_in_air(Vector3(0.0, 700.0, -600.0), 0.0, 0.0)
	var st := Telemetry.new()
	st.phase = "standing"
	st.position = Vector3(START.x, 300.0, START.z)
	for i in int(60.0 / DT):
		b.tick(DT, st)
	check(not a.brain.lead_active, "игрок стоит — lead_active false")
	check(a.wingman, "это напарник")
	check(a.is_airborne(), "напарник летает")
	b.free()
