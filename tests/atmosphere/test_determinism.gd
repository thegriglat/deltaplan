extends TestCase
## Детерминизм мира для сетевой игры (NET-00, docs/plan/multiplayer.md → M0): атмосфера —
## чистая функция (место, дата, время старта, погода, сид, время зоны t). Отпечаток
## (AtmoFingerprint: термики, облака, воздух в 20 точках) в моменты 0 / 600 / 3600 с совпадает
## до 1e-3 у двух независимых прогонов, у «прыжка» сразу в t (Atmosphere.start_at) и у прогона,
## где пилот улетал далеко (набор термиков у пилота не зависит от его пути).
##
## Прогон до 600 с — шагом игры (1/120 с); до 3600 с — шагом 0,5 с: обновления атмосферы идут по
## сетке времени (refresh раз в 1 с, огибающие раз в 0,1 с — номер интервала от time_s), а всё
## остальное — функции t, поэтому шаг не влияет (это же проверяет сравнение шагов 1/120 и 0,5 с
## до 600 с).

## Оба мира строятся из одной строки — ключа мира (WorldKey): он задаёт мир целиком.
const KEY := AtmoFingerprint.DEFAULT_KEY
const TOL := 1.0e-3
const GAME_DT := 1.0 / 120.0


func _jump(t: float) -> Dictionary:
	var a := AtmoFingerprint.make_world(KEY)
	a.start_at(t)
	var fp := AtmoFingerprint.capture(a)
	a.free()
	return fp


func _same(a: Dictionary, b: Dictionary, what: String) -> void:
	var d := AtmoFingerprint.diff(a, b, TOL)
	check(d == "", "%s (t = %.0f):\n%s" % [what, float(a.t), d])


func test_runs_and_jump_match() -> void:
	var a := AtmoFingerprint.make_world(KEY)
	var b := AtmoFingerprint.make_world(KEY)
	var fa: Array[Dictionary] = []
	var fb: Array[Dictionary] = []
	var t0 := Time.get_ticks_msec()
	for t in [0.0, 600.0]:
		AtmoFingerprint.run_to(a, t, GAME_DT)
		AtmoFingerprint.run_to(b, t, 0.5)
		fa.append(AtmoFingerprint.capture(a))
		fb.append(AtmoFingerprint.capture(b))
	AtmoFingerprint.run_to(a, 3600.0, 0.5)
	AtmoFingerprint.run_to(b, 3600.0, 0.5)
	fa.append(AtmoFingerprint.capture(a))
	fb.append(AtmoFingerprint.capture(b))
	print("    determinism: прогоны %.1f с" % ((Time.get_ticks_msec() - t0) / 1000.0))
	check((fa[1].thermals as Array).size() > 5, "термики есть (%d)" % (fa[1].thermals as Array).size())
	check((fa[2].clouds as Array).size() > 2, "облака есть (%d)" % (fa[2].clouds as Array).size())
	for i in fa.size():
		_same(fa[i], fb[i], "два прогона (шаг 1/120 и 0,5 с)")
		_same(fa[i], _jump(float(fa[i].t)), "прыжок в t против прогона от 0")
	a.free()
	b.free()


func test_other_seed_differs() -> void:
	var a := AtmoFingerprint.make_world(KEY)
	var b := AtmoFingerprint.make_world(KEY.replace("seed=4242", "seed=4243"))
	a.start_at(600.0)
	b.start_at(600.0)
	var d := AtmoFingerprint.diff(AtmoFingerprint.capture(a), AtmoFingerprint.capture(b), TOL)
	check(d != "", "другой сид — другой мир")
	a.free()
	b.free()


func test_pilot_path_does_not_matter() -> void:
	# Пилот улетает на 15 км и возвращается: у центра те же термики, что у того, кто стоял там.
	var a := AtmoFingerprint.make_world(KEY)
	var t := 0.0
	while t < 1800.0:
		t += 1.0
		var ang := t / 1800.0 * TAU
		a.set_focus(AtmoFingerprint.CENTER + Vector3(sin(ang), 0.0, 1.0 - cos(ang)) * 7500.0)
		a.step(1.0)
	a.set_focus(AtmoFingerprint.CENTER)
	a.time_s = 1800.0
	a.refresh_now()
	_same(AtmoFingerprint.capture(a), _jump(1800.0), "пилот летал далеко")
	a.free()
