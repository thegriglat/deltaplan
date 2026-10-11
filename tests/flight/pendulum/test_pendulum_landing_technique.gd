extends TestCase
## Правильная посадка «Маятника» (PD-27): пилот-бот садится по Жеглову (1983, с. 115) и ответу
## пилота 11.10 — против ветра на полётной скорости; с ≈ 3 м выравнивание (предварительное), у
## земли выдерживание: «от себя» постепенно, чтобы снижаться всё медленнее, пока гаснет скорость;
## на ≈ 0,5 м (ступни) — отдача до упора. Касание ступнями → LandingJudge (пороги flight.json →
## landing не меняются). Правильная посадка мягкая на всех классах во встречный 3 м/с; ранняя
## отдача (2 м) и поздняя (0,1 м) — жёсткая; без переворотов. В штиль — сторож (граница модели,
## PD-30: 1,13–1,48 порога, docs/research/pendulum.md → «Посадка (PD-30)»).
## Переключатели для разбора (переменные окружения): PD27_TRACE=крыло,ветер,высота — ход по шагам;
## PD27_SWEEP=1 — сетка бота; PD27_PUSH — ход «от себя» у земли, м; PD27_HOLDMAX — предел «от себя»
## на выдерживании; PD29_DS=1/0 — запаздывание срыва вкл./выкл.; PD30_BOT=29 — бот «на скорости»; PD29_T=τ₁,τ₂; PD29_CNMAX; PD29_FMAX — предел
## силы рук; PD30_REACH=угол[,спад] — досягаемость рук стоя, ° (0 — без предела); PD29_VR — отдача на 0,5 м, когда скорость ≤ это × срыва по поляре (иначе по высоте).

const S := preload("res://tests/flight/pendulum/pendulum_sim.gd")
const WINGS := ["training", "apogee", "laminar", "sport"]
const ROUND_H := 3.0  ## ступни: начало выравнивания, м
## Выравнивание: снижение к −max(0,05; kh·(h − HOLD_H)) м/с — к 0,5 м пилот подходит почти
## горизонтально и гасит скорость до срыва.
const HOLD_H := 0.55
const HOLD_PITCH_MAX := 0.8  ## выдерживание — не до упора: упор оставлен на отдачу
## Пилот-бот на выдерживании: ПИ по вертикальной скорости + гашение скорости тангажа крыла.
## Бот PD-27 (выдерживание до срыва, по Жеглову); бот «на скорости» PD-29 — kh 0,8, HOLD_H 0,3,
## HOLD_PITCH_MAX 0,45 (PD30_BOT=29).
const GAINS := {"kp": 0.4, "ki": 0.6, "kq": 1.0, "kh": 0.4}


## Заход с h0 м на триме курсом на север, встречный wind м/с; на ROUND_H — выравнивание и
## выдерживание (ПИ по вертикальной скорости ЦМ пилота к −max(0,05; kh·(h − 0,55)) м/с: держится над 0,5 м,
## пока хватает угла атаки),
## на push_h (ступни) — «от себя» до упора. push_h < 0 — без отдачи (выдерживание до касания).
## trace — печать хода от выравнивания. → {result, model, push_v (воздушная скорость на отдаче)}.
static func land(
	wing: String, wind: float, push_h: float, trace := false, h0 := 15.0, g := GAINS,
	hold_h := HOLD_H, v_ratio := 0.0
) -> Dictionary:
	var m := S.make(wing)
	var v_stall: float = float(Config.get_config("wings/" + wing).polar.points_kmh_ms[0][0]) / 3.6
	if OS.get_environment("PD27_PUSH") != "":
		m.arms.shift_x_push_flare = float(OS.get_environment("PD27_PUSH"))
	if OS.get_environment("PD29_CNMAX") != "":
		m.strips.dyn_cn_max = float(OS.get_environment("PD29_CNMAX"))
	if OS.get_environment("PD30_BOT") == "29":
		# бот PD-29: к 0,5 м на скорости ≈ 1,3 срыва (kh 0,8, к 0,3 м, «от себя» на выдерживании до 0,45)
		g = g.duplicate()
		g.kh = 0.8
		hold_h = 0.3
	if OS.get_environment("PD30_REACH") != "":
		var rr := OS.get_environment("PD30_REACH").split(",")
		m.arms.flare_reach = deg_to_rad(float(rr[0]))
		if rr.size() > 1:
			m.arms.flare_reach_soft = deg_to_rad(float(rr[1]))
	if OS.get_environment("PD29_FMAX") != "":
		m.arms.force_max = float(OS.get_environment("PD29_FMAX"))
	if OS.get_environment("PD29_DS") != "":
		m.strips.dyn_on = OS.get_environment("PD29_DS") == "1"
	if OS.get_environment("PD29_T") != "":
		var tt := OS.get_environment("PD29_T").split(",")
		m.strips.dyn_t1 = float(tt[0])
		m.strips.dyn_t2 = float(tt[1])
	var flat := func(_x: float, _z: float) -> float: return 0.0
	var w := Vector3(0.0, 0.0, wind)
	var air := func(_p: Vector3) -> Vector3: return w
	m.reset_in_air(Vector3(0.0, h0, 0.0), 0.0, 0.0, w)
	var inp := S.input()
	var t := 0.0
	var phase := 0  # 0 заход, 1 выдерживание, 2 отдача
	var pitch_i := 0.0
	var push_v := NAN
	var t_push := NAN
	var last_print := -1.0
	var hold_max := HOLD_PITCH_MAX
	if OS.get_environment("PD30_BOT") == "29":
		hold_max = 0.45
	if OS.get_environment("PD27_HOLDMAX") != "":
		hold_max = float(OS.get_environment("PD27_HOLDMAX"))
	var th_prev := NAN
	var h_bal := -INF  # наибольшая высота ступней после начала выдерживания (взмывание)
	var h_min_hold := INF
	var feet_prev := Vector3(NAN, NAN, NAN)
	var v_feet := Vector3.ZERO  # скорость ступней (ЦМ − 1 м по оси пилота) на последнем шаге
	while m.mode == FlightModel.Mode.AIR and t < 60.0:
		var feet := m.pilot_position - m.pilot_basis.y * 1.0
		if not is_nan(feet_prev.x):
			v_feet = (feet - feet_prev) / S.DT
		feet_prev = feet
		var hf := feet.y
		var vz := m.pilot_velocity.y
		if phase == 0 and hf < ROUND_H:
			phase = 1
		var slow := v_ratio > 0.0 and hf < push_h + 0.15 and m.telemetry.airspeed <= v_ratio * v_stall
		if phase == 1 and push_h >= 0.0 and (hf < push_h - (0.15 if v_ratio > 0.0 else 0.0) or slow):
			phase = 2
			push_v = m.telemetry.airspeed
			t_push = t
		var q := 0.0 if is_nan(th_prev) else (m.theta - th_prev) / S.DT
		th_prev = m.theta
		if phase == 1:
			var vz_cmd := -maxf(0.05, float(g.kh) * (hf - hold_h))
			var e := vz_cmd - vz  # > 0 — снижается быстрее заданного: «от себя»
			pitch_i = clampf(pitch_i + float(g.ki) * e * S.DT, -0.5, hold_max)
			inp.pitch = clampf(pitch_i + float(g.kp) * e - float(g.kq) * q, -0.5, hold_max)
			h_min_hold = minf(h_min_hold, hf)
			if h_min_hold < 1.5:
				h_bal = maxf(h_bal, hf - h_min_hold)
		elif phase == 2:
			inp.pitch = 1.0
		if trace and phase >= 1 and t - last_print >= 0.1 - 1.0e-6:
			last_print = t
			var rb := S.rel_b(m)
			print("      t %5.2f ф%d h %5.2f Vz %5.2f Vx %5.2f V %5.2f α %5.1f θ %5.1f срыв %.2f x %5.2f φ %4.1f/%4.1f F %5.0f p %4.2f" % [
				t, phase, hf, vz, -m.pilot_velocity.z, m.telemetry.airspeed, rad_to_deg(m.alpha),
				rad_to_deg(m.theta), m.stall_amount(), rb.x, rad_to_deg(m.arms.phi),
				rad_to_deg(m.arms.flare_reach), m.arms.force_b.x, inp.pitch])
		m.step(S.DT, inp, air, flat)
		t += S.DT
	return {"result": m.landing_result, "model": m, "push_v": push_v, "balloon": h_bal,
		"feet_v": Vector2(Vector2(v_feet.x, v_feet.z).length(), -v_feet.y),
		"t_touch": t - t_push if not is_nan(t_push) else NAN}


static func score(r: Dictionary) -> float:
	return maxf(float(r.get("vertical_speed_ms", 99.0)) / 5.0, float(r.get("horizontal_speed_ms", 99.0)) / 3.0)


static func fmt(a: Dictionary) -> String:
	var r: Dictionary = a.result
	return "%s %.2f: верт %.2f, гор %.2f м/с, крен %.0f°, %s; ступни гор %.2f верт %.2f; V на отдаче %.1f, от отдачи до касания %.2f с" % [
		r.get("grade", "?"), score(r), r.get("vertical_speed_ms", NAN),
		r.get("horizontal_speed_ms", NAN), r.get("bank_deg", NAN), r.get("contact", "?"),
		a.feet_v.x, a.feet_v.y, a.push_v, a.t_touch]


## Ход посадки по шагам (PD27_TRACE=крыло[,ветер[,высота отдачи]]): для разбора, не проверка.
func test_trace() -> void:
	var spec := OS.get_environment("PD27_TRACE")
	if spec.is_empty():
		return
	var p := spec.split(",")
	var wind := float(p[1]) if p.size() > 1 else 0.0
	var ph := float(p[2]) if p.size() > 2 else 0.5
	print("    ход %s, ветер %.0f, отдача с %.2f м" % [p[0], wind, ph])
	var a := land(p[0], wind, ph, true)
	print("    → " + fmt(a))


## Подбор пилота-бота (PD27_SWEEP=1): штиль, все крылья, сетка коэффициентов.
func test_sweep() -> void:
	if OS.get_environment("PD27_SWEEP").is_empty():
		return
	for kp: float in [0.2, 0.4]:
		for ki: float in [0.3, 0.6]:
			for kq: float in [0.5, 1.0, 2.0]:
				for kh: float in [0.4, 0.6]:
					var line := "kp %.1f ki %.1f kq %.1f kh %.1f |" % [kp, ki, kq, kh]
					for w: String in WINGS:
						var a := land(w, 0.0, 0.5, false, 15.0, {"kp": kp, "ki": ki, "kq": kq, "kh": kh})
						line += " %s V %.1f взм %.2f %.2f |" % [w.substr(0, 3), a.push_v, a.balloon, score(a.result)]
					print("    " + line)


## Правильная посадка: мягкая у всех во встречный 3 м/с; в штиль — сторож границы модели
## (PD-30: 1,41 / 1,45 / 1,13 / 1,48 у training / apogee / laminar / sport — жёстко по горизонтальной
## 3,4–4,4 м/с): не хуже CALM_GUARD и без переворота.
const CALM_GUARD := 1.7


func test_correct_landing_soft() -> void:
	if not OS.get_environment("PD27_TRACE").is_empty() or not OS.get_environment("PD27_SWEEP").is_empty():
		return  # разбор: только ход
	for wind: float in [0.0, 3.0]:
		for w: String in WINGS:
			var ph := 0.5 if OS.get_environment("PD29_PUSH_H") == "" else float(OS.get_environment("PD29_PUSH_H"))
			var vr := 0.0 if OS.get_environment("PD29_VR") == "" else float(OS.get_environment("PD29_VR"))
			var a := land(w, wind, ph, false, 15.0, GAINS, 0.55 if vr > 0.0 else HOLD_H, vr)
			print("    правильная %s, ветер %.0f — %s" % [w, wind, fmt(a)])
			var r: Dictionary = a.result
			check(absf(float(r.get("bank_deg", 180.0))) < 60.0, "%s, ветер %.0f: без переворота (%s)" % [w, wind, fmt(a)])
			if wind > 0.0:
				check(r.get("grade", "") == "soft", "%s, ветер %.0f: правильная посадка мягкая (%s)" % [w, wind, fmt(a)])
			else:
				check(score(r) < CALM_GUARD, "%s, штиль: сторож %.2f < %.1f (%s)" % [w, score(r), CALM_GUARD, fmt(a)])


## Ранняя (2 м) и поздняя (0,1 м, без отдачи) — жёсткая хотя бы у трёх из четырёх крыльев.
func test_wrong_timing_hard() -> void:
	if not OS.get_environment("PD27_TRACE").is_empty() or not OS.get_environment("PD27_SWEEP").is_empty():
		return  # разбор: только ход
	for ph: float in [2.0, 0.1, -1.0]:
		var hard := 0
		for w: String in WINGS:
			var a := land(w, 0.0, ph)
			var sc := score(a.result)
			print("    отдача с %.1f м %s — %s" % [ph, w, fmt(a)])
			if sc >= 1.0:
				hard += 1
			check(absf(float(a.result.get("bank_deg", 180.0))) < 60.0, "отдача с %.1f м %s: без переворота (%s)" % [ph, w, fmt(a)])
		check(hard >= 3, "отдача с %.1f м: жёсткая у %d из 4 (нужно ≥ 3)" % [ph, hard])
