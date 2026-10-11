extends TestCase
## Поток движения на земле и через смены фаз (MR-К1 v2) и единицы srs в м/с² (MR-К2 v2): headless FlightModel.

const Sim := preload("res://tests/flight/flight_sim.gd")
const PendulumSim := preload("res://tests/flight/pendulum/pendulum_sim.gd")
const G := Units.G
const EVERY := 2  # 120 Гц физики / 2 = 60 пакетов/с, как MotionOutput по умолчанию


static func flat(_x: float, _z: float) -> float:
	return 100.0


## Склон, спускающийся на север (−Z), уклон 0,3 (~17°) — как в test_takeoff.
static func slope(_x: float, z: float) -> float:
	return 1000.0 + 0.3 * z


## Поток: шаги модели + push, sample() каждые EVERY шагов. Возвращает {vert: [srs vertical], heave: [],
## valid: [], phases: {фаза: n}, ground: [on_ground]}.
class Stream:
	var src := MotionSource.new()
	var vert: Array[float] = []
	var heave: Array[float] = []
	var valid: Array[bool] = []
	var ground: Array[bool] = []
	var phases := {}
	var n := 0

	func run(m: Variant, secs: float, inp: ControlInput, air_fn: Callable, ground_fn: Callable) -> void:
		for i in int(round(secs / Sim.DT)):
			m.step(Sim.DT, inp, air_fn, ground_fn)
			src.push(m.telemetry, Sim.DT)
			phases[m.phase()] = int(phases.get(m.phase(), 0)) + 1
			n += 1
			if n % EVERY == 0:
				var s := src.sample()
				var pk := MotionPacket.pack_srs(s, "T")
				vert.append(pk.decode_float(196))
				heave.append(s.heave)
				valid.append(s.valid)
				ground.append(s.on_ground)

	func mean(a: Array[float], from: int = 0) -> float:
		var t := 0.0
		for i in range(from, a.size()):
			t += a[i]
		return t / maxf(1.0, a.size() - from)

	func sd(a: Array[float], from: int = 0) -> float:
		var mu := mean(a, from)
		var t := 0.0
		for i in range(from, a.size()):
			t += (a[i] - mu) * (a[i] - mu)
		return sqrt(t / maxf(1.0, a.size() - from))

	func peak(a: Array[float]) -> float:
		var p := 0.0
		for v in a:
			p = maxf(p, absf(v))
		return p

	func invalid_after_first() -> int:
		var c := 0
		for i in range(1, valid.size()):
			if not valid[i]:
				c += 1
		return c


func test_srs_units_ms2() -> void:
	var s := MotionSample.new()
	s.sway = 1.5
	s.heave = G + 2.0
	s.surge = -3.0
	var b := MotionPacket.pack_srs(s, "x")
	approx(b.decode_float(192), 1.5, 1e-5, "lateral, м/с²")
	approx(b.decode_float(196), 2.0, 1e-5, "vertical = heave − G, м/с²")
	approx(b.decode_float(200), -3.0, 1e-5, "longitudinal, м/с²")
	b = MotionPacket.pack_srs(s, "x", {"heave": "inverse", "sway": "inverse", "surge": "inverse"})
	approx(b.decode_float(192), -1.5, 1e-5, "inverse lateral")
	approx(b.decode_float(196), -2.0, 1e-5, "inverse vertical = −(heave − G)")
	approx(b.decode_float(200), 3.0, 1e-5, "inverse longitudinal")


func test_standing_flat() -> void:
	var m := Sim.make("sport")
	m.reset_on_ground(Vector3(0, 100, 0), 0.0)
	var st := Stream.new()
	st.run(m, 5.0, Sim.input(), Callable(), flat)
	print("MR5 стоя ровно: vertical среднее %.4f СКО %.4f пик %.3f м/с², phase %s" % [st.mean(st.vert, 5), st.sd(st.vert, 5), st.peak(st.vert), m.phase()])
	check(st.ground[st.ground.size() - 1], "on_ground")
	approx(st.mean(st.vert, 5), 0.0, 0.3, "vertical стоя на ровном ≈ 0 м/с²")
	check(st.sd(st.vert, 5) < 0.5, "СКО стоя мало")


func test_standing_slope() -> void:
	var m := Sim.make("sport")
	m.reset_on_ground(Vector3(0, 1000, 0), 0.0)
	var st := Stream.new()
	st.run(m, 5.0, Sim.input(), Callable(), slope)
	print("MR5 стоя на склоне: vertical среднее %.4f СКО %.4f пик %.3f м/с², pitch %.2f" % [st.mean(st.vert, 30), st.sd(st.vert, 30), st.peak(st.vert), m.telemetry.pitch_deg])
	check(st.valid[st.valid.size() - 1], "поток идёт")
	check(st.peak(st.vert) < 25.0, "нет выбросов на склоне")


func test_takeoff_stream_no_gaps() -> void:
	var m := Sim.make("sport")
	m.reset_on_ground(Vector3.ZERO, 0.0)
	var st := Stream.new()
	var af := func(_p: Vector3) -> Vector3: return Vector3(0, 0, 4.0)
	st.run(m, 3.0, Sim.input(), af, slope)  # стоит
	var stand_n := st.vert.size()
	st.run(m, 12.0, Sim.input(0.0, 0.0, true), af, slope)  # разбег → отрыв
	st.run(m, 3.0, Sim.input(), af, slope)
	var gnd_end := st.ground.rfind(true)
	var run_v := st.vert.slice(stand_n, gnd_end + 1)
	var run_h := st.heave.slice(stand_n, gnd_end + 1)
	var stand_h := st.heave.slice(10, stand_n)
	var fly_v := st.vert.slice(gnd_end + 20)
	print("MR5 разбег: фазы %s; СКО heave стоя %.4f, на разбеге %.4f м/с²; vertical в полёте среднее %.4f; пик на земле %.3f; разрывов (защита 50 g) %d" % [
		st.phases, st.sd(stand_h), st.sd(run_h), st.mean(fly_v), st.peak(run_v), st.invalid_after_first()])
	check(st.phases.has("standing") and st.phases.has("flying"), "фазы стоя и полёт были: %s" % [st.phases])
	check(st.invalid_after_first() == 0, "ни одного разрыва на смене фаз")


func test_steady_flight_srs() -> void:
	var m := Sim.make("sport")
	m.reset_in_air(Vector3(0, 3000, 0), 0.0)
	var st := Stream.new()
	st.run(m, 20.0, Sim.input(), Callable(), Callable())
	print("MR5 полёт: vertical среднее %.4f СКО %.4f м/с²" % [st.mean(st.vert, 600), st.sd(st.vert, 600)])
	approx(st.mean(st.vert, 600), 0.0, 0.5, "vertical в установившемся полёте ≈ 0 м/с²")


func test_landing_stream() -> void:
	var m := Sim.make("sport")
	m.reset_in_air(Vector3(0, 100.5, 0), 0.0)
	m.velocity = Vector3(0, -3.5, -2.0)
	var st := Stream.new()
	st.run(m, 3.0, Sim.input(), Callable(), flat)
	print("MR5 посадка: фаза %s; пик vertical %.2f м/с², invalid %d" % [m.phase(), st.peak(st.vert), st.invalid_after_first()])
	check(m.phase() == "landed", "приземлился")
	check(st.invalid_after_first() == 0, "касание без разрыва потока")


## Маятник (PD-К1): pilot_* заполняются и на земле, разбег и отрыв — без разрывов потока.
func test_pendulum_ground_stream() -> void:
	var m := PendulumSim.make("sport")
	m.reset_on_ground(Vector3.ZERO, 0.0)
	var st := Stream.new()
	var af := func(_p: Vector3) -> Vector3: return Vector3(0, 0, 4.0)
	st.run(m, 3.0, Sim.input(), af, slope)
	var stand_n := st.vert.size()
	st.run(m, 10.0, Sim.input(0.0, 0.0, true), af, slope)
	var gnd_end := st.ground.rfind(true)
	print("MR5 маятник: фазы %s; vertical стоя среднее %.3f СКО heave стоя %.3f, на разбеге %.3f; пик %.2f; разрывов %d" % [
		st.phases, st.mean(st.vert.slice(20, stand_n)), st.sd(st.heave.slice(20, stand_n)),
		st.sd(st.heave.slice(stand_n, gnd_end + 1)), st.peak(st.vert), st.invalid_after_first()])
	check(m.telemetry.pilot_velocity != Vector3.ZERO, "pilot_* заполнены")
	check(st.invalid_after_first() == 0, "маятник: поток без разрывов")
