extends TestCase
## Правильная посадка «Маятника» (PD-27): пилот-бот садится по Жеглову (1983, с. 115) и ответу
## пилота 11.10 — против ветра на полётной скорости; с ≈ 3 м выравнивание (предварительное), у
## земли выдерживание: «от себя» постепенно, чтобы снижаться всё медленнее, пока гаснет скорость;
## на ≈ 0,5 м (ступни) — отдача до упора (ход — до вытянутых рук, PD-35). Касание ступнями →
## PendulumTouchdown (PD-35): встал на ноги (гор. ≤ 2 м/с) / пробежал N шагов (≤ 5 м/с) / жёстко.
## Цель — правильная посадка мягкая на всех классах в штиль и во встречный 3 м/с, ранняя (2 м) и
## поздняя (0,1 м) — жёсткая. В квазистационарной модели мягкой правильной в штиль нет (гор. 5,9–7,1
## м/с > 5): правильная в штиль — сторож с фактическими числами, во встречный 3 м/с — мягко;
## поздняя и без отдачи — жёстко без переворотов; ранняя (отдача на скорости ≈ 1,3 срыва) — не мягко,
## laminar и sport встают на хвост (тангаж за 90°) — авария (docs/research/pendulum.md → «Посадка
## (PD-27)», «Посадка (PD-30)», «Посадка (PD-35)»).
## Переключатели для разбора (переменные окружения): PD27_TRACE=крыло,ветер,высота — ход по шагам;
## PD27_SWEEP=1 — сетка бота; PD27_PUSH — ход «от себя» у земли, м; PD27_HOLDMAX — предел «от себя»
## на выдерживании; PD33_DIAG=1 (с PD27_TRACE) — разбор по шагам 0,05 с: α киля и полос, тангаж, руки
## (цель, факт, сила), V крыла и пилота, стропа (натяжение, угол, сила на пилота), C_N/C_A/C_L/C_D
## крыла (PD-33, docs/research/pendulum.md → «Посадка (PD-33)»); PD29_DS=1/0 — запаздывание срыва вкл./выкл.; PD30_BOT=29 — бот «на скорости»; PD29_T=τ₁,τ₂; PD29_CNMAX; PD29_FMAX — предел
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
## Сильный встречный: на выдерживании путевая скорость пилота не ниже GS_MIN, м/с (снятие «от себя»
## GS_K в секунду на 1 м/с недобора).
const GS_MIN := 0.5
const GS_K := 1.0
const GAINS := {"kp": 0.4, "ki": 0.6, "kq": 1.0, "kh": 0.4}


## Заход с h0 м на триме курсом на север, встречный wind м/с; на ROUND_H — выравнивание и
## выдерживание (ПИ по вертикальной скорости ЦМ пилота к −max(0,05; kh·(h − 0,55)) м/с: держится над 0,5 м,
## пока хватает угла атаки),
## на push_h (ступни) — «от себя» до упора. push_h < 0 — без отдачи (выдерживание до касания).
## trace — печать хода от выравнивания. → {result, model, push_v (воздушная скорость на отдаче)}.
static func land(
	wing: String, wind: float, push_h: float, trace := false, h0 := 15.0, g := GAINS,
	hold_h := HOLD_H, v_ratio := 0.0, round_h := ROUND_H
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
	var diag := not OS.get_environment("PD33_DIAG").is_empty() and trace
	var last_diag := -1.0
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
		if phase == 0 and hf < round_h:
			phase = 1
		var slow := v_ratio > 0.0 and hf < push_h + 0.15 and m.telemetry.airspeed <= v_ratio * v_stall
		if phase == 0 and round_h <= 0.0 and push_h >= 0.0 and hf < push_h:
			phase = 2  # без выравнивания: отдача прямо с захода
			push_v = m.telemetry.airspeed
			t_push = t
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
			# сильный встречный (PD-33): скорость гасится относительно земли — не медленнее
			# GS_MIN над землёй (иначе крыло на минимальной скорости пятится назад)
			var gs := -m.pilot_velocity.z
			if gs < GS_MIN:
				pitch_i -= GS_K * (GS_MIN - gs) * S.DT
				inp.pitch = minf(inp.pitch, pitch_i)
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
		if diag and (phase >= 1 or round_h <= 0.0) and hf < 2.0 and t - last_diag >= 0.05 - 1.0e-6:
			last_diag = t
			print(diag_line(m, t - (t_push if not is_nan(t_push) else t), phase, hf, inp.pitch))
		m.step(S.DT, inp, air, flat)
		t += S.DT
	if diag:
		print(diag_line(m, t - t_push, 3, 0.0, inp.pitch))
	# пробег после касания: ЦМ пилота по земле, пока скорость > 0,3 м/с (не дольше 5 с)
	var runout := 0.0
	if m.mode == FlightModel.Mode.LANDED and m.landing_result.get("grade", "") != "crash":
		var p0 := m.pilot_position
		var t_run := 0.0
		var stop := ControlInput.new()
		while t_run < 5.0 and m.mode == FlightModel.Mode.LANDED:
			m.step(S.DT, stop, air, flat)
			t_run += S.DT
			var vg := Vector2(m.pilot_velocity.x, m.pilot_velocity.z).length()
			runout = Vector2(m.pilot_position.x - p0.x, m.pilot_position.z - p0.z).length()
			if vg < 0.3:
				break
	return {"runout": runout, "result": m.landing_result, "model": m, "push_v": push_v, "balloon": h_bal,
		"feet_v": Vector2(Vector2(v_feet.x, v_feet.z).length(), -v_feet.y),
		"t_touch": t - t_push if not is_nan(t_push) else NAN}


## Строка разбора посадки (PD33_DIAG вместе с PD27_TRACE): t от отдачи, с; h ступней; α киля, α полос
## (корень/середина/конец, от нулевой подъёмной); θ; руки: цель и факт x пилота от подвески в осях
## крыла (вперёд +), сила рук по x на пилота; V крыла и пилота (вперёд, вверх); стропа: натяжение и
## угол к вертикали (пилот впереди подвески +); горизонтальные силы на пилота: стропа, руки;
## C_N, C_A (оси крыла), C_L, C_D (по потоку) крыла; q крыла, °/с; моменты по тангажу около ЦМ крыла:
## аэродинамика и руки, Н·м (+ — на кабрирование).
static func diag_line(m: PendulumModel, t: float, phase: int, hf: float, pitch: float) -> String:
	var R: Basis = m._R
	var Rt := R.transposed()
	var va: Vector3 = m._vel - m._air_c
	var V := va.length()
	var q := 0.5 * m.rho * V * V * m.area
	var fb: Vector3 = m._aero_f_b
	var fw := R * fb
	var u := va / maxf(V, 1.0e-6)
	var D := -fw.dot(u)
	var lv := fw + u * D
	var L := lv.length() * (1.0 if lv.z < 0.0 else -1.0)
	var H: Vector3 = m._pos + R * m._r_hang_b
	var xp: Vector3 = m.chain.pilot()
	var rel := Rt * (xp - H)
	var d := xp - H
	var strap_ang := rad_to_deg(atan2(d.x, d.z))
	var a: PackedFloat64Array = m.strips.alpha_s
	var nh := m.strips.n / 2
	var arm_m: float = m._r_bar_b.cross(Vector3(-m.arms.force_b.x, 0.0, 0.0)).y
	var vp := m.pilot_velocity
	return "  D t %5.2f ф%d h %5.2f p %4.2f | α %5.1f αп %5.1f/%5.1f/%5.1f θ %5.1f q %6.1f | цель %5.2f факт %5.2f Fр %5.0f | Vк %5.2f/%5.2f Vп %5.2f/%5.2f | T %5.0f φ %5.1f Fстр %5.0f Fрук %5.0f | CN %5.2f CA %5.2f CL %5.2f CD %5.2f | Mаэ %6.0f Mрук %6.0f" % [
		t, phase, hf, pitch, rad_to_deg(m.alpha), rad_to_deg(a[0]), rad_to_deg(a[nh / 2]),
		rad_to_deg(a[nh - 1]), rad_to_deg(m.theta), rad_to_deg((Rt * m._w).y),
		m.arms.target_b.x, rel.x, m.arms.force_b.x,
		m._vel.x, -m._vel.z, -vp.z, vp.y,
		m.chain.tension, strap_ang, m.chain.pilot_force.x, m._hands_p.x,
		-fb.z / q, -fb.x / q, L / q, D / q, m._aero_m_b.y, arm_m]


## Оценка для таблиц: max(верт/5, гор/5) — порог PendulumTouchdown (вертикальная — LandingJudge
## hard_vertical_ms, горизонтальная — touchdown.run_max_ms); мягкая < 1.
static func score(r: Dictionary) -> float:
	return maxf(float(r.get("vertical_speed_ms", 99.0)) / 5.0, float(r.get("horizontal_speed_ms", 99.0)) / 5.0)


static func fmt(a: Dictionary) -> String:
	var r: Dictionary = a.result
	return "%s %s %d шаг. %.2f: верт %.2f, гор %.2f м/с, крен %.0f°, %s; ступни гор %.2f верт %.2f; V на отдаче %.1f, от отдачи до касания %.2f с, пробег %.1f м" % [
		r.get("grade", "?"), r.get("touchdown", "?"), int(r.get("steps", -1)), score(r), r.get("vertical_speed_ms", NAN),
		r.get("horizontal_speed_ms", NAN), r.get("bank_deg", NAN), r.get("contact", "?"),
		a.feet_v.x, a.feet_v.y, a.push_v, a.t_touch, a.runout]


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


## Правильная посадка (PD-35): в штиль — сторож границы модели (жёстко, гор. 6,10 / 5,90 / 6,13 /
## 7,14 м/с у training / apogee / laminar / sport: не выбегает), не быстрее CALM_H_GUARD по
## горизонтальной, касание ступнями, без переворота; во встречный 3 м/с — мягко (пробежал 3–4 шага).
const CALM_H_GUARD := 7.6


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
			check(r.get("contact", "") == "feet", "%s, ветер %.0f: касание ступнями (%s)" % [w, wind, fmt(a)])
			if wind > 0.0:
				check(r.get("grade", "") == "soft", "%s, ветер %.0f: мягко (%s)" % [w, wind, fmt(a)])
			else:
				check(float(r.get("horizontal_speed_ms", 99.0)) < CALM_H_GUARD,
					"%s, штиль: сторож гор. < %.1f м/с (%s)" % [w, CALM_H_GUARD, fmt(a)])


## Ранняя (2 м) и поздняя (0,1 м, без отдачи) — не мягкая хотя бы у трёх из четырёх крыльев. Поздняя и
## без отдачи — без переворота; ранняя — отдача на скорости, laminar и sport встают на хвост (авария).
func test_wrong_timing_hard() -> void:
	if not OS.get_environment("PD27_TRACE").is_empty() or not OS.get_environment("PD27_SWEEP").is_empty():
		return  # разбор: только ход
	for ph: float in [2.0, 0.1, -1.0]:
		var hard := 0
		for w: String in WINGS:
			var a := land(w, 0.0, ph)
			print("    отдача с %.1f м %s — %s" % [ph, w, fmt(a)])
			if a.result.get("grade", "") != "soft":
				hard += 1
			if ph < 1.0:
				check(absf(float(a.result.get("bank_deg", 180.0))) < 60.0, "отдача с %.1f м %s: без переворота (%s)" % [ph, w, fmt(a)])
		check(hard >= 3, "отдача с %.1f м: жёсткая у %d из 4 (нужно ≥ 3)" % [ph, hard])



## Сильный встречный 8–10 м/с (пилот, ответ по сборке 4): лететь на минимальной высоте, гасить
## скорость, ручку резко не отдавать — мягко, пробег ≤ 5 м. Бот: выдерживание до касания, путевая
## скорость не ниже GS_MIN.
func test_strong_wind_soft() -> void:
	if not OS.get_environment("PD27_TRACE").is_empty() or not OS.get_environment("PD27_SWEEP").is_empty():
		return
	for wind: float in [8.0, 10.0]:
		for w: String in WINGS:
			var a := land(w, wind, -1.0)
			print("    встречный %.0f, без отдачи %s — %s" % [wind, w, fmt(a)])
			check(a.result.get("grade", "") == "soft", "встречный %.0f %s: мягко (%s)" % [wind, w, fmt(a)])
			check(float(a.runout) <= 5.0, "встречный %.0f %s: пробег ≤ 5 м (%s)" % [wind, w, fmt(a)])


## Без выравнивания (заход на триме до земли; с отдачей на 0,5 м и без неё) — жёстко у всех.
func test_no_roundout_hard() -> void:
	if not OS.get_environment("PD27_TRACE").is_empty() or not OS.get_environment("PD27_SWEEP").is_empty():
		return
	for ph: float in [0.5, -1.0]:
		for w: String in WINGS:
			var a := land(w, 0.0, ph, false, 15.0, GAINS, HOLD_H, 0.0, 0.0)
			print("    без выравнивания, отдача с %.1f м %s — %s" % [ph, w, fmt(a)])
			check(a.result.get("grade", "") != "soft", "без выравнивания, отдача с %.1f м %s: не мягко (%s)" % [ph, w, fmt(a)])
