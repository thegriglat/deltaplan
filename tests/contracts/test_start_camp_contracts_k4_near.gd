extends TestCase
## Контракт SC-K4 v2, игровая часть (docs/contracts/start-camp.md): EggPeople — ближе near_m
## экземпляры camp_pilot со скелетом (не больше max_skinned), дальше MultiMesh; гистерезис; скрытый
## в MultiMesh ⇔ показан скелетный; AnimationPlayer только у ближних; анимации по поведению.
## godot --headless --path . res://tests/run_tests.tscn -- --filter=start_camp_contracts_k4_near


class Place:
	extends EggPlace
	var tents: Array[Dictionary] = []

	func camp() -> Array[Dictionary]:
		return tents


func _cfg() -> Dictionary:
	return Config.get_config("easter_eggs").eggs.people


func _ctx() -> EggContext:
	var pl := Place.new()
	for k in 4:
		pl.tents.append(
			{
				"type": "tent",
				"position": Vector3(-9.0 + 6.0 * k, 0.0, 3.0 * (k % 2)),
				"basis": Basis.IDENTITY,
				"yaw": 0.0,
				"color": 0,
				"radius": 1.8,
			}
		)
	var c := EggContext.new()
	c.place = pl
	c.world_key = "P"
	c.sun_elev_deg = 40.0
	c.height_at = func(_x: float, _z: float) -> float: return 0.0
	c.pilot_pos = Vector3(0.0, 400.0, 0.0)
	return c


func _spawn(c: EggContext, cfg: Dictionary, seed_i: int) -> EggPeople:
	var e := EggPeople.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_i
	e.begin(c, cfg, rng, 0.0)
	e.update(c)
	return e


## Камера (= пилот) на расстоянии d от центра лагеря, на высоте 2 м; шаг времени 1 с.
func _step(e: EggPeople, c: EggContext, d: float) -> void:
	c.pilot_pos = Vector3(d, 2.0, 0.0)
	c.t += 1.0
	e._last_tick = -1.0e9
	e.update(c)


## Скрытый в MultiMesh ⇔ показан скелетный.
func _mm_hidden(e: EggPeople, i: int) -> bool:
	return e._is_hidden(i)  # в headless MultiMesh не хранит матрицы; флаг — то, что update пишет в нулевой масштаб


func _consistent(e: EggPeople, what: String) -> void:
	for i in e.person_count():
		check(_mm_hidden(e, i) == e.is_near(i), "%s: человек %d скрыт в MultiMesh ⇔ ближний" % [what, i])
	var pl := e.near_players()
	var on := 0
	for q in pl:
		var occupied: bool = int(q.person) >= 0
		on += 1 if occupied else 0
		check(bool(q.visible) == occupied, "%s: показан ⇔ занят" % what)
		check(bool(q.active) == occupied and bool(q.playing) == occupied, "%s: AnimationPlayer играет ⇔ ближний" % what)
		check(bool(q.disabled) == not occupied, "%s: у дальних process_mode выключен" % what)
	check(on == e.near_count(), "%s: занятых экземпляров %d = ближних %d" % [what, on, e.near_count()])


func test_lod_switch_and_hysteresis() -> void:
	var cfg := _cfg().duplicate()
	var near_m := float(cfg.near_m)
	var hy := float(cfg.near_hyst_m)
	var c := _ctx()
	var e := _spawn(c, cfg, 2)
	var n := e.person_count()
	check(n >= 3, "людей >= 3 (%d)" % n)
	_step(e, c, 400.0)
	check(e.near_count() == 0, "400 м: ближних нет")
	_consistent(e, "далеко")
	_step(e, c, near_m - 15.0)  # лагерь ~ 20 м в поперечнике: ближе near_m — все внутри круга
	check(e.near_count() == mini(n, int(cfg.max_skinned)), "ближе near_m: все ближние (%d из %d)" % [e.near_count(), n])
	_consistent(e, "вблизи")
	# гистерезис: чуть дальше near_m ближние остаются, за near_m + hyst уходят
	var held := e.near_count()
	_step(e, c, near_m + hy * 0.3 - 8.0)
	var inside := 0
	for i in n:
		if e.is_near(i):
			inside += 1
	check(inside >= 1 and inside <= held, "в зоне гистерезиса: ближние не мигают (%d)" % inside)
	_step(e, c, near_m + hy + 60.0)
	check(e.near_count() == 0, "за near_m + гистерезис: все дальние")
	_consistent(e, "ушли")
	# входят снова только ближе near_m
	_step(e, c, near_m + hy * 0.5 + 15.0)
	var any_in := false
	for i in n:
		any_in = any_in or e.is_near(i)
	check(not any_in, "между near_m и near_m + гистерезис дальние не входят (%s)" % any_in)
	_step(e, c, near_m - 20.0)
	check(e.near_count() > 0, "ближе near_m — снова ближние")
	_consistent(e, "снова")
	# за видимостью — никого
	_step(e, c, 5000.0)
	check(e.near_count() == 0, "за visibility: никого")
	for m in e._mmis:
		check(not m.visible, "за visibility: MultiMesh не рисуется")
	_consistent(e, "за видимостью")


func test_max_skinned_limit() -> void:
	var cfg := _cfg().duplicate()
	cfg.max_skinned = 2
	var c := _ctx()
	var e := _spawn(c, cfg, 4)
	_step(e, c, 20.0)
	check(e.person_count() > 2, "людей больше лимита (%d)" % e.person_count())
	check(e.near_count() == 2, "лимит max_skinned = 2: ближних %d" % e.near_count())
	check(e.near_players().size() <= 2, "экземпляров не больше лимита (%d)" % e.near_players().size())
	_consistent(e, "лимит")


func test_animations() -> void:
	var cfg := _cfg().duplicate()
	var c := _ctx()
	var e := _spawn(c, cfg, 2)
	_step(e, c, 25.0)  # высоко: pilot_pos.y = 2 — низко, машут; поднимем выше
	c.pilot_pos = Vector3(25.0, 400.0, 0.0)
	for k in 5:
		c.t += 1.0
		e._last_tick = -1.0e9
		e.update(c)
	var seen := {}
	for i in e.person_count():
		if e.is_near(i):
			seen[e.near_anim(i)] = true
	for a in seen:
		check(a == "idle" or a == "walk", "не реагирует: idle/walk, а не %s" % a)
	# низкий пролёт: все ближние машут (wave или wave_both)
	for k in 6:
		c.pilot_pos = Vector3(25.0, 5.0, 0.0)
		c.t += 1.0
		e._last_tick = -1.0e9
		e.update(c)
	for i in e.person_count():
		if e.is_near(i):
			check(e.near_anim(i).begins_with("wave"), "низкий пролёт: человек %d машет (%s)" % [i, e.near_anim(i)])
	# модель: 3714 треугольников на человека, куртка и штаны тонируются отдельно
	check(e.near_tris() > 3000 and e.near_tris() <= 4500, "треугольников на ближнего: %d" % e.near_tris())
	_consistent(e, "анимации")
