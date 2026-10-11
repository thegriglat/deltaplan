extends TestCase
## Отклик в полёте «до/после» (PD-35, по заданию: управление 1.5.5 — эталон). Замер, не проверка:
## включается PD35_FEEL=1; «до» — PD35_SWEEPNORM=0 PD35_CPREV=0 (физика 1.5.5, pendulum_sim.gd →
## pd35_env; ход рук у земли и оценка касания выше 5 м над землёй не действуют). Печатает строку
## «FEEL крыло метрика значение» на замер: трим, снижение, крен через 2 с полного смещения, перекладка
## 45→45, самовыход из 30° (крен через 5/10/20 с), усилие рук и скорость «на себя» (100 % и 50 %).
## Таблица — tools/research/pendulum/pd35/feel_table.py.

const S := preload("res://tests/flight/pendulum/pendulum_sim.gd")
const WINGS := ["training", "laminar", "sport"]


static func make(w: String) -> PendulumModel:
	var m := S.make(w)
	S.reset(m)
	return m


static func run(m: PendulumModel, inp: ControlInput, sec: float) -> void:
	for i in int(round(sec / S.DT)):
		m.step(S.DT, inp, Callable(), Callable())


func test_feel() -> void:
	if OS.get_environment("PD35_FEEL").is_empty():
		return
	for w: String in WINGS:
		# трим
		var m := make(w)
		run(m, S.input(), 20.0)
		print("FEEL %s trim_kmh %.3f" % [w, S.airspeed(m) * 3.6])
		print("FEEL %s sink_ms %.4f" % [w, -m.velocity.y])
		# крен через 2 с полного смещения
		m = make(w)
		run(m, S.input(), 3.0)
		run(m, S.input(0.0, 1.0), 2.0)
		print("FEEL %s bank_2s_deg %.3f" % [w, rad_to_deg(m.bank)])
		# перекладка 45→45 (как test_reversal_45)
		var r := S.scenario("reversal", w)
		m = make(w)
		var bh := S.BankHold.new(deg_to_rad(float(r.bank_deg)), 6.0, 2.5, 1.0)
		var inp := S.input()
		for i in int(round(float(r.hold_s) / S.DT)):
			inp.roll = bh.roll(m)
			m.step(S.DT, inp, Callable(), Callable())
		var t0 := m.time_s
		inp.roll = -1.0
		var t_rev := NAN
		for i in int(round(12.0 / S.DT)):
			m.step(S.DT, inp, Callable(), Callable())
			if is_nan(t_rev) and m.bank <= deg_to_rad(-float(r.bank_deg)):
				t_rev = m.time_s - t0
		print("FEEL %s reversal_s %.3f" % [w, t_rev])
		# самовыход из 30°: держать 30° 8 с, затем руки в нейтраль
		m = make(w)
		bh = S.BankHold.new(deg_to_rad(30.0), 6.0, 2.5, 1.0)
		inp = S.input()
		for i in int(round(8.0 / S.DT)):
			inp.roll = bh.roll(m)
			m.step(S.DT, inp, Callable(), Callable())
		inp.roll = 0.0
		var marks := [5.0, 10.0, 20.0]
		var tt := 0.0
		for mk: float in marks:
			run(m, inp, mk - tt)
			tt = mk
			print("FEEL %s recover_%.0fs_deg %.3f" % [w, mk, rad_to_deg(m.bank)])
		# усилие «на себя»: 100 % и 50 %, среднее за 8–12 с
		for p: float in [-1.0, -0.5]:
			m = make(w)
			run(m, S.input(), 3.0)
			run(m, S.input(p), 8.0)
			var fsum := 0.0
			var vsum := 0.0
			var n := int(round(4.0 / S.DT))
			for i in n:
				m.step(S.DT, S.input(p), Callable(), Callable())
				fsum += m.arms.force_b.x
				vsum += S.airspeed(m)
			print("FEEL %s pull%.0f_force_n %.3f" % [w, -p * 100.0, fsum / n])
			print("FEEL %s pull%.0f_kmh %.3f" % [w, -p * 100.0, vsum / n * 3.6])
		check(S.finite(m), "%s: без NaN" % w)
