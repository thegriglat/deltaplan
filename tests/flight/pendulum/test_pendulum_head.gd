extends TestCase
## «Маятник», голова (PD-6, R9): в болтанке σ 1 м/с (детерминированное поле reference.json, пилот
## мягко держит горизонт — как в test_pendulum_robust) голова качается поперёк в осях крыла.
## СКО в полосе 0,3–3 Гц — 0,5–2× прототипа (docs/research/pendulum.md → «Маятник и болтанка»:
## 2,2 / 3,6 / 2,7 см для training / laminar / sport). Отклик хаотичен — порядок величины, не точки.

const S := preload("res://tests/flight/pendulum/pendulum_sim.gd")
const PROTO_CM := {"training": 2.2, "laminar": 3.6, "sport": 2.7}
const BAND_HZ := Vector2(0.3, 3.0)
const T_S := 40.0
const SKIP_S := 10.0


## Голова поперёк (+X оси крыла) относительно подвески, м: ряд с шагом 1/120 с.
func _head_x(w: String) -> PackedFloat64Array:
	var dt := 1.0 / 120.0
	var m := S.make(w, 0.0, {}, true)
	var off := S.reset(m)
	var tb := S.Turbulence.new(S.ref().turbulence, off)
	var bh := S.BankHold.new(0.0, 1.5, 0.8, 0.3)
	var inp := S.input()
	var out: PackedFloat64Array = []
	for i in int(round(T_S / dt)):
		inp.roll = bh.roll(m)
		m.step(dt, inp, tb.air, Callable())
		if not S.finite(m):
			return PackedFloat64Array()
		if m.time_s > SKIP_S:
			out.append((m.telemetry.basis.inverse() * (m.head_position - m.hang_position)).x)
	return out


## СКО (м) составляющей ряда в полосе band (Гц): сумма мощности по бинам ДПФ k/T.
static func band_std(x: PackedFloat64Array, dt: float, band: Vector2) -> float:
	var n := x.size()
	var mean := 0.0
	for v in x:
		mean += v
	mean /= n
	var tt := n * dt
	var power := 0.0
	var k := int(ceil(band.x * tt))
	while k / tt <= band.y:
		var re := 0.0
		var im := 0.0
		var w := TAU * k / n
		for i in n:
			var v := x[i] - mean
			re += v * cos(w * i)
			im -= v * sin(w * i)
		power += 2.0 * (re * re + im * im) / (float(n) * n)
		k += 1
	return sqrt(power)


func test_head_in_turbulence_band() -> void:
	for w: String in ["training", "laminar", "sport"]:
		var x := _head_x(w)
		check(not x.is_empty(), "%s: без NaN" % w)
		if x.is_empty():
			continue
		var all := band_std(x, 1.0 / 120.0, Vector2(0.01, 30.0))
		var band := band_std(x, 1.0 / 120.0, BAND_HZ)
		var ref_cm: float = PROTO_CM[w]
		var k := band * 100.0 / ref_cm
		check(k > 0.5 and k < 2.0, "%s: голова поперёк в полосе 0,3–3 Гц %.1f см — 0,5–2× прототипа (%.1f см)" % [
			w, band * 100.0, ref_cm])
		print("    %s: голова поперёк СКО %.1f см (все частоты), в полосе 0,3–3 Гц %.1f см (прототип %.1f), ×%.2f" % [
			w, all * 100.0, band * 100.0, ref_cm, k])
