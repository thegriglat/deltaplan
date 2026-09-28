extends TestCase
## Другие пилоты в небе (BotPilots, configs/bots.json): ждут, пока игрок на земле; взлетают
## разбегом по одному через 30 с после его отрыва; полёт детерминирован; держат дистанцию
## друг от друга и от игрока; в одном термике кружат в одну сторону (задаёт первый — игрок);
## 0 — ботов нет. Мир — аналитический: вершина с ровной площадкой и склоном 20° на север,
## равнина 100 м, один термик; без узлов (visuals_enabled = false).

const DT := 1.0 / 120.0
const THERMAL := Vector2(0.0, -1500.0)
const START := Vector3(0.0, 300.0, -1.0)


static func hill(_x: float, z: float) -> float:
	if z >= 0.0:
		return 300.0
	return maxf(100.0, 300.0 + z * tan(deg_to_rad(20.0)))


## Встречный старту ветер 2,5 м/с (с севера) + термик 3,5 м/с (радиус ~120 м) + фон −0,3.
static func air(p: Vector3) -> Vector3:
	var r := Vector2(p.x, p.z).distance_to(THERMAL)
	var w := -0.3
	if p.y < 2000.0:
		w += 3.8 * exp(-pow(r / 120.0, 2.0))
	return Vector3(0.0, w, 2.5)


func make(count: int, seed_value: int = 0, air_share: float = 0.0) -> BotPilots:
	var b := BotPilots.new()
	b.visuals_enabled = false
	(
		b
		. setup(
			{
				"air_fn": air,
				"ground_fn": hill,
				"start": Vector3(START.x, hill(START.x, START.z), START.z),
				"heading_deg": 0.0,
				"count": count,
				"seed": seed_value,
				"airborne_share": air_share,
			}
		)
	)
	return b


func player(phase: String, pos: Vector3, vel: Vector3 = Vector3.ZERO) -> Telemetry:
	var t := Telemetry.new()
	t.phase = phase
	t.position = pos
	t.velocity = vel
	t.heading_deg = fposmod(rad_to_deg(atan2(vel.x, -vel.z)), 360.0)
	return t


func run(b: BotPilots, seconds: float, p: Telemetry) -> void:
	for i in int(seconds / DT):
		b.tick(DT, p)


func test_zero_bots() -> void:
	var b := make(0)
	check(b.agents.is_empty(), "0 — ботов нет")
	run(b, 5.0, player("flying", Vector3(0, 500, -600), Vector3(0, -1, -10)))
	check(b.get_child_count() == 0, "и узлов нет")
	b.free()


func test_wait_on_ground_then_interval() -> void:
	var b := make(3)
	check(b.agents.size() == 3, "3 бота")
	# Места ожидания: позади игрока (к югу, z > старта), не ближе 9 м, на ровном.
	for a in b.agents:
		check(a.spot.z > START.z + 5.0, "бот %d позади старта: z=%.1f" % [a.id, a.spot.z])
		check(absf(hill(a.spot.x, a.spot.z) - 300.0) < 0.5, "бот %d на ровной вершине" % a.id)
		for o in b.agents:
			if o != a:
				check(a.spot.distance_to(o.spot) >= 11.9, "боты не теснятся")
	var stand := player("standing", Vector3(START.x, 300.0, START.z))
	run(b, 90.0, stand)
	check(
		b.state_counts().get("wait", 0) == 3, "игрок стоит 90 с — все ждут: %s" % b.state_counts()
	)
	check(b.player_liftoff_s < 0.0, "отрыва не было")
	var t0 := b.sim_time_s
	var fly := player("flying", Vector3(0, 600, -1500), Vector3(0, -1, -10))
	run(b, 140.0, fly)
	approx(b.player_liftoff_s, t0 + DT, 0.02, "отрыв игрока замечен")
	for k in 3:
		var a := b.agents[k]
		approx(a.run_start_s - b.player_liftoff_s, 30.0 * (k + 1), 0.1, "разбег бота %d" % k)
		check(a.liftoff_s > a.run_start_s, "бот %d оторвался: %.1f" % [k, a.liftoff_s])
		check(a.liftoff_s - a.run_start_s < 10.0, "разбег %.1f с" % (a.liftoff_s - a.run_start_s))
		check(a.failed_runs == 0, "бот %d без срывов взлёта" % k)
		check(a.state >= BotAgent.State.FLY, "бот %d взлетел: %s" % [k, a.state_name()])
	b.free()


## Половина ботов (не меньше одного) к началу полёта уже в воздухе, остальные — в очереди.
func test_half_airborne() -> void:
	for c in [[1, 1], [3, 1], [4, 2]]:
		var b := make(c[0], 0, 0.5)
		var counts := b.state_counts()
		check(counts.get("fly", 0) == c[1], "%d ботов — в воздухе %d: %s" % [c[0], c[1], counts])
		check(counts.get("wait", 0) == c[0] - c[1], "остальные ждут: %s" % counts)
		for k in c[1]:
			var a := b.agents[k]
			var p := a.model.position
			check(p.z < START.z - 200.0, "бот %d впереди старта: z=%.0f" % [k, p.z])
			check(p.y > hill(p.x, p.z) + 150.0, "бот %d высоко над рельефом" % k)
		var t0 := b.sim_time_s
		run(b, 1.0, player("flying", Vector3(0, 600, -1500), Vector3(0, -1, -10)))
		run(b, 30.0 * (c[0] - c[1]) + 20.0, player("flying", Vector3(0, 600, -1500), Vector3(0, -1, -10)))
		for k in range(c[1], c[0]):
			var a := b.agents[k]
			approx(a.run_start_s - b.player_liftoff_s, 30.0 * (k - c[1] + 1), 0.1, "разбег бота %d" % k)
		check(b.sim_time_s > t0, "время шло")
		b.free()


func test_deterministic() -> void:
	var pos: Array = []
	for rep in 2:
		var b := make(3, 7)
		run(b, 1.0, player("standing", START))
		run(b, 130.0, player("flying", Vector3(0, 600, -1500), Vector3(0, -1, -10)))
		var s: Array = []
		for a in b.agents:
			s.append([a.wing_id, a.mass_kg, a.scheme, a.model.position])
		pos.append(s)
		b.free()
	check(pos[0] == pos[1], "тот же сид — тот же полёт")
	var other := make(3, 8)
	var same := true
	for i in 3:
		same = same and other.agents[i].wing_id == pos[0][i][0]
		same = same and is_equal_approx(other.agents[i].mass_kg, pos[0][i][1])
	check(not same, "другой сид — другие крылья или массы")
	other.free()


## Игрок кружит влево в термике первым; 4 бота рядом на разных высотах: кто кружит в этом
## термике — влево; дистанция друг от друга и от игрока держится.
func test_thermal_rule_and_separation() -> void:
	var b := make(4, 3)
	run(b, 0.5, player("standing", START))
	for i in 4:
		var ang := TAU * i / 4.0
		var p := THERMAL + Vector2(sin(ang), -cos(ang)) * 250.0
		b.agents[i].start_in_air(Vector3(p.x, 750.0 + 60.0 * i, p.y), rad_to_deg(ang) + 180.0, 0.0)
	var pt := player("flying", Vector3.ZERO)
	var total := 0
	var bad_pairs := 0
	var bad_player := 0
	var circling := 0
	var wrong_dir := 0
	var min_player := INF
	var t := 0.0
	var r := 60.0
	var v := 11.0
	while t < 360.0:
		# Игрок: круг влево (против часовой сверху) радиуса 60 м вокруг оси, набор 1,5 м/с.
		var ang := -v / r * t
		var off := Vector2(sin(ang), -cos(ang)) * r
		pt.position = Vector3(THERMAL.x + off.x, 700.0 + 1.5 * t, THERMAL.y + off.y)
		var tan_v := Vector2(-cos(ang), -sin(ang)) * v
		pt.velocity = Vector3(tan_v.x, 1.5, tan_v.y)
		pt.heading_deg = fposmod(rad_to_deg(atan2(tan_v.x, -tan_v.y)), 360.0)
		b.tick(DT, pt)
		t += DT
		if int(t / DT) % 60 != 0:
			continue
		for a in b.agents:
			if not a.is_airborne():
				continue
			var ta := a.telemetry()
			if ta.altitude_agl < 30.0:
				continue
			total += 1
			var dh := Vector2(ta.position.x - pt.position.x, ta.position.z - pt.position.z).length()
			var dv := absf(ta.position.y - pt.position.y)
			min_player = minf(min_player, Vector3(dh, dv, 0).length())
			if dh < 50.0 and dv < 15.0:
				bad_player += 1
			for o in b.agents:
				if o.id <= a.id or not o.is_airborne():
					continue
				var to := o.telemetry()
				var h := (
					Vector2(ta.position.x - to.position.x, ta.position.z - to.position.z).length()
				)
				if h < 50.0 and absf(ta.position.y - to.position.y) < 15.0:
					bad_pairs += 1
			if a.brain.is_circling() and a.brain.lift_center().distance_to(THERMAL) < 300.0:
				circling += 1
				if a.brain.circle_dir() > 0.0:
					wrong_dir += 1
	check(circling > 100, "боты кружат в термике: %d замеров" % circling)
	check(wrong_dir == 0, "все кружат влево, как игрок: не так %d из %d" % [wrong_dir, circling])
	# Новый бот, собравшийся кружить вправо в этом термике, повернёт влево; в новом — как хочет.
	check(b._circle_dir(THERMAL + Vector2(80, 0), 900.0, 1.0, 0) < 0.0, "в занятом — влево")
	check(b._circle_dir(THERMAL + Vector2(2000, 0), 900.0, 1.0, 0) > 0.0, "в свободном — своя")
	check(
		bad_player == 0, "к игроку ближе 50 м / 15 м: %d (мин. %.0f м)" % [bad_player, min_player]
	)
	check(bad_pairs <= total / 50, "ботов ближе 50 м / 15 м: %d из %d" % [bad_pairs, total])
	b.free()
