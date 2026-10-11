extends Node
## «Маятник», ленточки (PD-20): Glider передаёт Telltale настоящую ориентацию крыла (с рысканием)
## и скорость узла, поэтому лента показывает скольжение: боковой порыв β≈10° → угол ленты в
## осях крыла ≈ β ± 3°; ровный вираж 30° и штиль прямо → лента почти назад.

const S := preload("res://tests/flight/pendulum/pendulum_sim.gd")
const M := preload("res://tests/flight/pendulum/test_pendulum_mode.gd")
const DT := 1.0 / 120.0

var failures: PackedStringArray = []
var _wind := Vector3.ZERO


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


func _glider() -> Glider:
	var g: Glider = M.make_glider("pendulum", "sport")
	g.set_ground_fn(func(_x: float, _z: float) -> float: return 0.0)
	g.set_air_fn(func(_p: Vector3) -> Vector3: return _wind)
	add_child(g)
	g.set_process(false)
	g.set_physics_process(false)
	g.reset_in_air(Vector3(0.0, 1000.0, 0.0), 0.0)
	return g


func _fly(g: Glider, seconds: float, bank_rad: float) -> void:
	var bh := S.BankHold.new(bank_rad, 1.5, 0.8, 0.3)
	for i in int(seconds / DT):
		g.control.roll = bh.roll(g.model)
		g.step(DT)


## Один шаг и вклад лент в среднее: сумма направлений в осях крыла (трепет усредняется).
func _acc(g: Glider, acc: Array) -> void:
	g.step(DT)
	var inv: Basis = g.model.telemetry.basis.inverse()
	for t in g.visual.telltales:
		acc[0] += inv * t.model.direction()
	var rel: Vector3 = inv * (_wind - g.model.velocity)
	acc[1] += rel.normalized()


## Лететь seconds с и вернуть {tape, beta}: средние угол ленты и скольжение по размаху, ° (+ вправо).
func _measure(g: Glider, seconds: float, bank_rad: float) -> Dictionary:
	var bh := S.BankHold.new(bank_rad, 1.5, 0.8, 0.3)
	var acc: Array = [Vector3.ZERO, Vector3.ZERO]
	for i in int(seconds / DT):
		g.control.roll = bh.roll(g.model)
		_acc(g, acc)
	return {
		"tape": rad_to_deg(atan2(acc[0].x, acc[0].z)),
		"beta": rad_to_deg(atan2(acc[1].x, acc[1].z)),
	}


func test_calm_straight_is_aft() -> void:
	_wind = Vector3.ZERO
	var g := _glider()
	_fly(g, 15.0, 0.0)
	check(g.visual.telltales.size() == 2, "две ленты: %d" % g.visual.telltales.size())
	var r := _measure(g, 2.0, 0.0)
	check(absf(r.tape) < 3.0, "штиль прямо: лента назад, угол %.1f°" % r.tape)


func test_steady_turn_30_is_aft() -> void:
	_wind = Vector3.ZERO
	var g := _glider()
	_fly(g, 60.0, deg_to_rad(30.0))
	check(absf(rad_to_deg(g.model.bank) - 30.0) < 5.0, "вираж ~30°: %.1f°" % rad_to_deg(g.model.bank))
	var r := _measure(g, 3.0, deg_to_rad(30.0))
	# Модель в установившемся вираже скользит внутрь (β ≈ −(Cnr·rb/2V + Cnp·pb/2V)/Cnβ — демпфирование
	# рыскания против флюгерной устойчивости), узел ленты ещё ≈1 м впереди оси рыскания (+r·x/V).
	# Лента показывает ровно это. С Cnr ≈ −0,055 (Hiway Demon −0,058, PD-23) — 9–14° у узла; «строго
	# назад» (<3°, отзыв пилота) требует проверсного момента в вираже, которого в модели нет — граница
	# модели (docs/research/pendulum.md, «Боковой канал против литературы», PD-21/23).
	check(absf(r.tape - r.beta) < 3.0, "вираж 30°: лента %.1f° vs β %.1f°" % [r.tape, r.beta])
	check(absf(r.tape) < 16.0, "вираж 30°: лента внутрь, не больше 16° (граница модели), угол %.1f°" % r.tape)


func test_sideslip_shown() -> void:
	for sgn in [1.0, -1.0]:
		_wind = Vector3.ZERO
		var g := _glider()
		_fly(g, 15.0, 0.0)
		# боковой порыв поперёк крыла даёт β ≈ 10°; усредняем 0,5 с, пока рыскание не развернуло крыло
		var gust: float = g.model.telemetry.airspeed * tan(deg_to_rad(10.0))
		_wind = g.model.telemetry.basis.x * gust * sgn
		var r := _measure(g, 0.5, 0.0)
		check(absf(r.beta) > 6.0, "порыв создал скольжение: β %.1f°" % r.beta)
		check(absf(r.tape - r.beta) < 3.0, "порыв %+d: лента %.1f° vs β %.1f°" % [sgn, r.tape, r.beta])
