extends Node
## PFT-2: отклик «Маятника» на ход штанги (прямой ввод control.roll/pitch, как после MouseBar в InputController).
## Запуск (без окна):
##   XDG_DATA_HOME=~/.cache/dp-xdg/$(basename "$PWD") godot --headless --path . \
##     res://tools/research/pilot-feedback-trim/mouse/mouse_response.tscn -- \
##     --out=tools/research/pilot-feedback-trim/mouse/response.json [--wings=sport,...]
## Штиль, плотность 1,225, эталонная масса крыла (S.make). Перед каждым опытом 20 с нейтрали (трим).
## (а) ступенька roll=r: скорость крена max, t63 до 63 % от скорости крена на 1,5 с? — см. _step;
## (б) перекладка ±A→∓A полным ходом (ступенька -1 от удержанного крена +A);
## (в) тангаж: установившаяся скорость при pitch = p.

const S := preload("res://tests/flight/pendulum/pendulum_sim.gd")
const DT := 1.0 / 120.0
const FRACS := [0.1, 0.3, 0.6, 1.0]
const ANGLES := [30.0, 45.0]
const PITCHES := [0.5, -0.3, -0.6, -1.0]

var _args := {"out": "tools/research/pilot-feedback-trim/mouse/response.json",
	"wings": "sport,moyes_litespeed_rx,ww_t2c,ww_u2,training"}


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--") and a.contains("="):
			var kv := a.substr(2).split("=", true, 1)
			_args[kv[0]] = kv[1]
	var res := {"args": _args, "wings": {}}
	for w in String(_args.wings).split(","):
		var r := {"group": Config.get_config("wings/" + w).group}
		r["trim_kmh"] = _settled(w).telemetry.airspeed * 3.6
		r["steps"] = []
		for f: float in FRACS:
			r.steps.append(_step(w, f))
		r["reversal"] = []
		for A: float in ANGLES:
			r.reversal.append(_reversal(w, A))
		r["pitch"] = []
		for p: float in PITCHES:
			r.pitch.append(_pitch(w, p))
		res.wings[w] = r
		print(w, " ", JSON.stringify(r))
	var fl := FileAccess.open(String(_args.out), FileAccess.WRITE)
	fl.store_string(JSON.stringify(res, " ", false))
	fl.close()
	get_tree().quit(0)


func _settled(w: String) -> PendulumModel:
	var m := S.make(w)
	S.reset(m)
	var c := S.input()
	for i in int(20.0 / DT):
		m.step(DT, c, Callable(), Callable())
	return m


## Ступенька roll=f 8 с: ряд ω(t) → пик, t63 (время до 63 % пика ω за первые 3 с), крен через 2/4/8 с.
func _step(w: String, f: float) -> Dictionary:
	var m := _settled(w)
	var c := S.input(0.0, f)
	var ts := PackedFloat32Array()
	var om := PackedFloat32Array()
	var bk := PackedFloat32Array()
	var out := {"frac": f}
	for i in int(8.0 / DT):
		m.step(DT, c, Callable(), Callable())
		ts.append((i + 1) * DT)
		om.append(rad_to_deg(m.roll_rate))
		bk.append(rad_to_deg(m.bank))
	var pk := 0.0
	var pk_t := 0.0
	for i in om.size():
		if ts[i] <= 3.0 and absf(om[i]) > absf(pk):
			pk = om[i]
			pk_t = ts[i]
	var t63 := NAN
	for i in om.size():
		if absf(om[i]) >= 0.63 * absf(pk):
			t63 = ts[i]
			break
	var t5 := NAN  # до 5° крена
	for i in bk.size():
		if absf(bk[i]) >= 5.0:
			t5 = ts[i]
			break
	out["peak_rate_dps"] = pk
	out["peak_t_s"] = pk_t
	out["t63_s"] = t63
	out["t_to_5deg_s"] = t5
	out["bank_2s"] = bk[int(2.0 / DT) - 1]
	out["bank_4s"] = bk[int(4.0 / DT) - 1]
	out["bank_8s"] = bk[int(8.0 / DT) - 1]
	out["rate_8s_dps"] = om[om.size() - 1]
	out["bank_abs_max"] = _absmax(bk)
	return out


func _absmax(a: PackedFloat32Array) -> float:
	var mx := 0.0
	for v in a:
		mx = maxf(mx, absf(v))
	return mx


## Удержание +A ПИД-ом BankHold (как пилот-испытатель) 25 с, затем roll = −1 (полный ход) до −A.
## Время: от снятия удержания до прохода 0, до −A; пик скорости крена. Плюс «от нейтрали до A» полным ходом.
func _reversal(w: String, A: float) -> Dictionary:
	var m := _settled(w)
	var hold := S.BankHold.new(deg_to_rad(A), 1.5, 0.8, 0.15)
	var c := S.input()
	for i in int(25.0 / DT):
		c.roll = hold.roll(m)
		m.step(DT, c, Callable(), Callable())
	var out := {"angle": A, "bank_at_release": rad_to_deg(m.bank), "hold_roll_in": c.roll}
	var peak := 0.0
	var t0 := -1.0
	var t_zero := NAN
	var t_neg := NAN
	var t_neg_half := NAN
	c.roll = -1.0
	for i in int(15.0 / DT):
		m.step(DT, c, Callable(), Callable())
		var t := (i + 1) * DT
		var b := rad_to_deg(m.bank)
		peak = minf(peak, rad_to_deg(m.roll_rate))
		if is_nan(t_zero) and b <= 0.0:
			t_zero = t
		if is_nan(t_neg) and b <= -A:
			t_neg = t
			break
	out["t_to_zero_s"] = t_zero
	out["t_reversal_s"] = t_neg
	out["peak_rate_dps"] = peak
	# то же, но «обратный ход» мышью на 20 % хода (малый обратный ход мыши): скорость крена на 1 с
	return out


## Установившаяся скорость при pitch=p (25 с рампы 6 с).
func _pitch(w: String, p: float) -> Dictionary:
	var m := _settled(w)
	var v0 := m.telemetry.airspeed
	var c := S.input()
	var t_ramp := 6.0
	var v10 := 0.0
	for i in int(40.0 / DT):
		var t := i * DT
		c.pitch = p * clampf(t / t_ramp, 0.0, 1.0)
		m.step(DT, c, Callable(), Callable())
		if i == int(10.0 / DT):
			v10 = m.telemetry.airspeed
	return {"pitch": p, "v_trim_kmh": v0 * 3.6, "v_10s_kmh": v10 * 3.6, "v_40s_kmh": m.telemetry.airspeed * 3.6}
