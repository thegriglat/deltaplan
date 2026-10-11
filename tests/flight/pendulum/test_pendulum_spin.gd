extends TestCase
## «Маятник» (PD-22): сваливание на крыло и штопор по полосам (Жеглов 1983, с. 28, 64, 112–114, 122).
## Вираж 30° вправо на малой скорости: пилот держит крен, медленно «от себя» (0 → 1 за 10 с) и, не
## заметив срыва, дожимает до упора, руки по крену замерли. Срыв начинается на внутренней (правой)
## консоли, крыло сваливается на неё: крен растёт, рыскание внутрь быстрее виража, проседание —
## штопор (авторотация: наклон C_L полосы за срывом отрицательный, Viterna & Corrigan). Выход по
## Жеглову (с. 122): «на себя» до упора и смещение против вращения, пока не кончится вращение и срыв,
## затем ручка плавно к нейтрали по скорости (без «свечи»), крен к нулю. Выход — срыва нет, |крен| < 15°, вращения нет
## (|dψ/dt| < 20°/с) 3 с подряд; 20 с после — без переворота и без нового штопора.
## PD35_SPINTRACE=крыло — ход выхода (каждые 0,25 с): крен, рыскание, срыв полос, V, α полос (PD-35).

const S := preload("res://tests/flight/pendulum/pendulum_sim.gd")
const WINGS := ["training", "sport"]
const RAMP_S := 10.0
const AFTER_S := 6.0
## Выход: не дольше, с (от начала «на себя»), и потеря высоты от первого срыва, м — сторож
const RECOVER_MAX_S := 15.0
const LOSS_MAX_M := 150.0


func _yaw_rate(m: PendulumModel, prev: float) -> float:
	return wrapf(m.heading - prev, -PI, PI) / S.DT


func _run(w: String) -> Dictionary:
	var m := S.make(w)
	S.reset(m)
	var v_trim := S.airspeed(m) * 3.6
	var hb := S.BankHold.new(deg_to_rad(30.0), 6.0, 2.5, 1.0)
	var inp := S.input()
	for i in int(round(14.0 / S.DT)):
		inp.roll = hb.roll(m)
		m.step(S.DT, inp, Callable(), Callable())
	var h := m.strips.n / 2
	var t0 := m.time_s
	var hd := m.heading
	var o := {"first": "", "bank0": 0.0, "bank_max": -INF, "yaw_turn": 0.0, "yaw_mean": 0.0, "sink_turn": 0.0,
		"sink_max": 0.0, "recover_s": NAN, "loss_m": NAN, "after_bank_max": 0.0, "after_stall_s": 0.0,
		"finite": true}
	# установившийся вираж: скорость рыскания и снижение
	var yaw_turn := 0.0
	var phase := 0
	var t_st := 0.0
	var roll_frz := 0.0
	var h0 := 0.0
	var yaw_sum := 0.0
	var n_yaw := 0
	var t_rec0 := 0.0
	var pulling := true
	var rec_since := NAN
	var h_rec := 0.0
	var t_done := NAN
	var yr_prev := 0.0
	for i in int(round(90.0 / S.DT)):
		var t := m.time_s - t0
		if phase == 0:
			inp.pitch = clampf(t / RAMP_S, 0.0, 1.0)
			inp.roll = hb.roll(m)
		elif phase == 1:
			inp.pitch = clampf(t / RAMP_S, 0.0, 1.0)
			inp.roll = roll_frz
		else:
			hb.target = 0.0
			inp.roll = hb.roll(m)
			if pulling:
				inp.pitch = -1.0
				# смещение против вращения — в сторону, противоположную свалившейся консоли (крен Эйлера
				# на крутом пикировании штопора скачет и сторону не показывает)
				inp.roll = -signf(yr_prev)
			else:
				# ручка к нейтрали по скорости: «на себя», пока V выше трима (−1 при V ≥ 1,5 трима)
				inp.pitch = clampf(-2.0 * (S.airspeed(m) * 3.6 - v_trim) / v_trim, -1.0, 0.0)
		m.step(S.DT, inp, Callable(), Callable())
		if not S.finite(m):
			o.finite = false
			break
		var yr := _yaw_rate(m, hd)
		yr_prev = yr
		hd = m.heading
		var nr := 0
		var nl := 0
		for j in h:
			if m.strips.blend[j] > 0.01:
				nr += 1
			if m.strips.blend[j + h] > 0.01:
				nl += 1
		if phase == 0:
			if t > 1.0 and t < 2.0:
				yaw_turn += yr * S.DT
				o.sink_turn = maxf(o.sink_turn, -m.velocity.y)
			if nr + nl > 0:
				phase = 1
				t_st = t
				roll_frz = inp.roll
				h0 = m.position.y
				o.first = "обе" if nr > 0 and nl > 0 else ("внутренняя" if nr > 0 else "внешняя")
				o.bank0 = rad_to_deg(m.bank)
				o.yaw_turn = rad_to_deg(yaw_turn)
				o.pitch_at_stall = inp.pitch
		elif phase == 1:
			o.bank_max = maxf(o.bank_max, rad_to_deg(m.bank))
			o.sink_max = maxf(o.sink_max, -m.velocity.y)
			yaw_sum += yr
			n_yaw += 1
			if t - t_st >= AFTER_S:
				phase = 2
				t_rec0 = m.time_s
				o.yaw_mean = rad_to_deg(yaw_sum / n_yaw)
		elif phase == 2:
			var tr := m.time_s - t_rec0
			if OS.get_environment("PD35_SPINTRACE") == w and i % 30 == 0:
				var ms := ""
				for j in m.strips.n:
					ms += "%4.0f" % rad_to_deg(m.strips.alpha_s[j])
				print("      mode %d h %7.1f tr %5.2f крен %6.1f yr %6.1f срыв %d/%d V %5.1f p %5.2f θ %6.1f | α полос %s" % [
					m.mode, m.position.y, tr, rad_to_deg(m.bank), rad_to_deg(yr), nr, nl, S.airspeed(m) * 3.6, inp.pitch, rad_to_deg(m.theta), ms])
			if pulling and tr >= 1.0 and (tr >= 10.0 or (nr + nl == 0 and absf(yr) < deg_to_rad(45.0))):
				pulling = false
				o.pull_s = tr
			if absf(rad_to_deg(m.bank)) < 15.0 and absf(rad_to_deg(yr)) < 20.0 and nr + nl == 0:
				if is_nan(rec_since):
					rec_since = m.time_s
					h_rec = m.position.y
				elif m.time_s - rec_since >= 3.0:
					o.recover_s = rec_since - t_rec0
					o.loss_m = h0 - h_rec
					t_done = m.time_s
					phase = 3
			else:
				rec_since = NAN
		else:
			# 20 с после выхода: ни переворота, ни нового штопора
			o.after_bank_max = maxf(o.after_bank_max, absf(rad_to_deg(m.bank)))
			if nr + nl > h:
				o.after_stall_s += S.DT
			if m.time_s - t_done >= 20.0:
				break
	return o


func test_inner_wing_drop_spin_and_recovery() -> void:
	for w: String in WINGS:
		var o := _run(w)
		check(o.finite, "%s: без NaN" % w)
		check(o.first == "внутренняя", "%s: первой срывается внутренняя консоль (%s)" % [w, o.first])
		check(o.bank_max - o.bank0 >= 15.0, "%s: крыло валится внутрь — крен %.0f° → %.0f°" % [w, o.bank0, o.bank_max])
		check(o.yaw_mean >= 1.5 * o.yaw_turn, "%s: рыскание внутрь быстрее виража (%.0f против %.0f °/с)" % [
			w, o.yaw_mean, o.yaw_turn])
		check(o.sink_max >= 3.0 * o.sink_turn, "%s: проседание — снижение до %.1f м/с (в вираже %.1f)" % [
			w, o.sink_max, o.sink_turn])
		check(o.recover_s <= RECOVER_MAX_S, "%s: выход за %.1f с (≤ %.0f)" % [w, o.recover_s, RECOVER_MAX_S])
		check(o.loss_m <= LOSS_MAX_M, "%s: потеря высоты %.0f м (≤ %.0f)" % [w, o.loss_m, LOSS_MAX_M])
		check(o.after_bank_max < 90.0, "%s: после выхода без переворота (|крен| до %.0f°)" % [w, o.after_bank_max])
		check(o.after_stall_s < 2.0, "%s: после выхода без нового штопора (срыв > половины полос %.1f с)" % [
			w, o.after_stall_s])
		print("    %s: срыв при «от себя» %.2f, первой %s; крен %.0f° → %.0f°, рыскание %.0f °/с (вираж %.0f), "
			% [w, o.get("pitch_at_stall", NAN), o.first, o.bank0, o.bank_max, o.yaw_mean, o.yaw_turn]
			+ "снижение до %.1f м/с (вираж %.1f); выход %.1f с («на себя» %.1f с), потеря %.0f м; после |крен| до %.0f°"
			% [o.sink_max, o.sink_turn, o.recover_s, o.get("pull_s", NAN), o.loss_m, o.after_bank_max])
