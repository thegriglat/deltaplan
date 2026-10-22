extends Node
## Связка буксировщик-дельталёт + дельтаплан (TT-К4 «Связка», docs/contracts/tow-trike.md): Glider «sport» в «Маятнике» на
## тележке (TW-К10), TowLine aerotow (TW-К5), TowTug (TT-К4), без ветра, ровная земля y = 0, до 300 м. Пилот держит тангаж
## простым регулятором. Числа печатаются строкой TT_CLIMB (шлюз модуля, в отчёт; не подгонять).

const Sim := preload("res://tests/flight/pendulum/pendulum_sim.gd")
const DT := 1.0 / 120.0
const CLIMB_K := 0.15
const CLIMB_KV := 0.3
const BANK_K := 1.5  ## целевой крен на рад ошибки курса
const BANK_MAX := 0.35
const ROLL_KP := 3.0
const ROLL_KD := 0.8
const TOP_AGL := 300.0
const SETTLE_S := 5.0  ## после выхода в climb режим считается установившимся через это время
const WINDOW_S := 10.0  ## минимум окна осреднения, с

var failures: PackedStringArray = []


func check(cond: bool, msg: String = "") -> void:
	if not cond:
		failures.append("check failed: " + msg)


class Run:
	extends RefCounted
	var g: Glider
	var s: TowSession
	var th0 := 0.0
	var t := 0.0
	var flat_fn := func(_x: float, _z: float) -> float: return 0.0
	var tmax := 0.0
	var x_liftoff := -1.0  ## разбег буксировщика до agl > 0,5 м от места старта (по оси полосы), м
	var t_climb := -1.0
	var win_t0 := -1.0
	var win_h0 := 0.0
	var win_t1 := -1.0
	var win_h1 := 0.0
	var v_sum := 0.0
	var v_n := 0
	var start_z := 0.0

	func _init(host: Node) -> void:
		var ref := Sim.make("sport")
		Sim.reset(ref)
		th0 = ref.theta
		g = Glider.new()
		g.setup("sport", 0.0)
		g.model = Sim.make("sport")
		g.set_ground_fn(flat_fn)
		g.reset_on_ground(Vector3.ZERO, 0.0)
		s = TowSession.new()
		host.add_child(s)
		var site := {"start_pos": Vector3.ZERO, "end_pos": Vector3(0.0, 0.0, -400.0), "heading_deg": 0.0}
		s.setup(g, flat_fn, site, "aerotow", false)
		start_z = s.tug.pos.z

	func step(w: bool, release := false) -> void:
		var c := Sim.input(0.0, 0.0)
		if g.phase() == "flying":
			# пилот держит высоту ≈3,5 м над колёсами буксировщика (ПД по высоте и вертикальной скорости относительно него)
			var h_t := s.tug.agl_m + 3.5
			var vz_rel: float = g.model.velocity.y - s.tug.vel.y
			c.pitch = clampf(CLIMB_K * (h_t - s.glider_agl_m()) - CLIMB_KV * vz_rel, -1.0, 1.0)
			# крен: следует за буксировщиком (курс на хвост буксировщика) - на кругах (circuit) без этого трос уводит вбок
			var to_tug: Vector3 = s.tug.pos - g.model.pilot_position
			var brg := Vector2(to_tug.x, -to_tug.z).angle_to(Vector2(0.0, 1.0))
			var he := wrapf(brg - g.model.heading, -PI, PI)
			var bank_tgt := clampf(BANK_K * he, -BANK_MAX, BANK_MAX)
			c.roll = clampf(ROLL_KP * (bank_tgt - g.model.bank) - ROLL_KD * g.model.roll_rate, -1.0, 1.0)
		g.set_input(c)
		s.step(DT, w, release)
		g.step(DT)
		t += DT
		tmax = maxf(tmax, g.model.link_tension_n)
		var tg := s.tug
		if x_liftoff < 0.0 and tg.agl_m > 0.5:
			x_liftoff = absf(tg.pos.z - start_z)
		if tg.phase == "climb":
			if t_climb < 0.0:
				t_climb = t
			if win_t0 < 0.0 and t - t_climb >= SETTLE_S:
				win_t0 = t
				win_h0 = tg.agl_m
			if win_t0 > 0.0 and tg.agl_m < float(Config.get_config("tow_tug").tow.power_reduce_agl_m):
				win_t1 = t
				win_h1 = tg.agl_m
				v_sum += tg.airspeed_ms
				v_n += 1

	func dispose() -> void:
		s.queue_free()
		g.free()


func test_climb() -> void:
	var r := Run.new(self)
	var steps := int(240.0 / DT)
	for i in steps:
		r.step(r.t >= 1.0)
		if r.s.tug.agl_m >= TOP_AGL:
			break
	var dur := r.win_t1 - r.win_t0
	var climb := (r.win_h1 - r.win_h0) / dur if dur > 0.0 else 0.0
	var speed := r.v_sum / maxf(float(r.v_n), 1.0) * 3.6
	print("    TT_CLIMB climb_ms=%.2f speed_kmh=%.1f liftoff_m=%.0f tmax_dan=%.1f" % [climb, speed, r.x_liftoff, r.tmax / 10.0])
	print("    окно %.1f с, t=%.0f с, tug agl %.0f м, фаза %s, glider agl %.0f м" % [dur, r.t, r.s.tug.agl_m, r.s.tug.phase, r.s.glider_agl_m()])
	var runway := float(Config.get_config("tow").aerotow.runway_length_m)
	check(Sim.finite(r.g.model) and Sim.finite(r.s.tug.model), "модели конечны")
	check(r.s.tug.phase in ["climb", "circuit"], "буксировщик взлетел: %s" % r.s.tug.phase)
	check(r.x_liftoff > 0.0 and r.x_liftoff <= runway, "отрыв буксировщика в пределах полосы: %.0f м из %.0f" % [r.x_liftoff, runway])
	check(dur >= WINDOW_S, "окно осреднения ≥ %.0f с: %.1f" % [WINDOW_S, dur])
	check(speed >= 55.0 and speed <= 65.0, "воздушная скорость буксировщика 55-65 км/ч: %.1f" % speed)
	check(climb >= 2.54, "вертикальная ≥ 2,54 м/с (BHPA 500 фт/мин): %.2f" % climb)
	check(r.tmax < float(Config.get_config("tow").aerotow_rope.weak_link_daN) * 10.0, "натяжение < слабого звена: %.0f Н" % r.tmax)
	r.dispose()
