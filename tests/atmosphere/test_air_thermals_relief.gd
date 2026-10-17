extends TestCase
## FL-17: источники термиков поля и поля рельефа. Точка и сила источника (pick_fn →
## Terrain.thermal_source_strength_at) читают влажность ложбин из полей рельефа, которые Terrain
## считает в фоне и подменяет на главном потоке. Сборка до их готовности давала другое число
## источников (6994–6998 на одной точке между запусками), поэтому загрузка (Game) запускает сборку
## заранее только по готовым полям (Game.air_sources_ready). Здесь — на синтетике: готовность полей
## меняет итог (зачем ждать), гейт закрыт, пока поля считаются, и сборка по готовым полям
## воспроизводится бит-в-бит, в том числе из рабочего потока.

const T := preload("res://tests/atmosphere/test_air_thermals.gd")
const P := preload("res://tests/atmosphere/test_air_thermals_parallel.gd")


## Рельеф для источников: влажность ложбин — полоса вдоль z (сырые днища), без полей — 0,5
## (как Terrain.moisture_at); сила источника падает с влажностью, сырое — не источник (как вода).
class FakeTerrain:
	extends RefCounted
	var ready := false
	var busy := false

	func relief_busy() -> bool:
		return busy

	func moisture_at(x: float, z: float) -> float:
		if not ready:
			return 0.5
		return 0.95 if absf(sin(x * 0.004) * cos(z * 0.003)) > 0.6 else 0.3

	func strength(x: float, z: float) -> float:
		return clampf(1.0 - 1.25 * moisture_at(x, z), 0.0, 1.0)


func _cfg(f: WindField, t: FakeTerrain) -> Dictionary:
	var g := GroundField.new()
	g.set_functions(func(_x: float, _z: float) -> float: return T.GROUND, t.strength)
	var cfg := T._cfg()
	cfg["pick_fn"] = AirThermals.pick_in_column.bind(f, g, 11, 8)
	cfg["height_fn"] = func(_x: float, _z: float) -> float: return T.GROUND
	return cfg


static func _field() -> WindField:
	return T._flat(P._heat_var, T._conv_line, 2200.0, 0.0058, Vector2(3.0, 1.0))


## Готовность полей рельефа меняет источники: до них — нейтральная влажность, после — настоящая.
func test_relief_changes_sources() -> void:
	var f := _field()
	var t := FakeTerrain.new()
	var before := AirThermals.new()
	check(before.build(f, _cfg(f, t)), "сборка без полей рельефа")
	t.ready = true
	var after := AirThermals.new()
	check(after.build(f, _cfg(f, t)), "сборка по полям рельефа")
	check(before.count() > 0 and after.count() > 0, "источники есть: %d / %d" % [before.count(), after.count()])
	check(
		before.count() != after.count() or before.pos != after.pos,
		"итог зависит от готовности полей (%d → %d) — сборку нужно начинать после них" % [
			before.count(), after.count()
		]
	)


## Гейт загрузки: пока поля рельефа считаются — источники не собирать; без полей рельефа — можно.
func test_ready_gate() -> void:
	var t := FakeTerrain.new()
	t.busy = true
	check(not Game.air_sources_ready(t), "поля рельефа считаются — сборка источников ждёт")
	t.busy = false
	t.ready = true
	check(Game.air_sources_ready(t), "поля готовы — можно собирать")
	check(Game.air_sources_ready(RefCounted.new()), "рельеф без полей (нет relief_busy) — можно")
	check(Game.air_sources_ready(null), "рельефа нет — можно")


## По готовым полям сборка воспроизводится бит-в-бит: повтор, полосы, рабочий поток.
func test_ready_build_reproducible() -> void:
	var f := _field()
	var t := FakeTerrain.new()
	t.ready = true
	var cfg := _cfg(f, t)
	var ref := P._build(f, cfg, 1)
	check(ref.count() > 0, "источники есть (%d)" % ref.count())
	var again := P._build(f, _cfg(f, t), 0)
	check(P._dump(ref) == P._dump(again), "повторная сборка (полосами) — тот же итог")
	var s := AirThermals.new()
	var tid := WorkerThreadPool.add_task(func() -> void: s.build(f, cfg), false, "test FL-17")
	WorkerThreadPool.wait_for_task_completion(tid)
	check(P._dump(ref) == P._dump(s), "из рабочего потока — тот же итог")


## Сид мира — вход сборки (pick_fn: кандидаты точки по hash(сид, i, j)): тот же сид — тот же итог,
## другой — другие точки и число источников (вода — где ни один кандидат не греет). «Лететь» из
## меню без --seed берёт новый сид (main.gd) — разброс числа источников между такими запусками
## (FL-15: 6994–6998) — от сида, а не от сборки.
func test_seed_decides_sources() -> void:
	var f := _field()
	var t := FakeTerrain.new()
	t.ready = true
	var g := GroundField.new()
	g.set_functions(func(_x: float, _z: float) -> float: return T.GROUND, t.strength)
	var runs := {}
	for sd: int in [11, 11, 12]:
		var cfg := T._cfg()
		cfg["pick_fn"] = AirThermals.pick_in_column.bind(f, g, sd, 8)
		cfg["height_fn"] = func(_x: float, _z: float) -> float: return T.GROUND
		var s := AirThermals.new()
		s.build(f, cfg)
		if runs.has(sd):
			check(P._dump(runs[sd]) == P._dump(s), "сид %d дважды — тот же итог" % sd)
		else:
			runs[sd] = s
	var a: AirThermals = runs[11]
	var b: AirThermals = runs[12]
	check(a.pos != b.pos, "другой сид — другие точки (%d / %d источников)" % [a.count(), b.count()])
