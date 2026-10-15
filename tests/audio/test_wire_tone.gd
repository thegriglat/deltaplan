extends TestCase
## Эоловый тон тросов (SPF-К3): частоты f = St·V/d, спектральный пик fill(), тишина, плавность.

const RATE := 44100.0


func _tone(seed_value: int = 4242) -> WireTone:
	var t := WireTone.new()
	t.setup(Config.get_config("audio").flight.airflow.wire_tone, RATE, seed_value)
	return t


func _cfg() -> Dictionary:
	return Config.get_config("audio").flight.airflow.wire_tone


## Мощность на частоте f (Гц), Герцель.
func _power(x: PackedFloat32Array, f: float) -> float:
	var w := TAU * f / RATE
	var c := 2.0 * cos(w)
	var s1 := 0.0
	var s2 := 0.0
	for v in x:
		var s := v + c * s1 - s2
		s2 = s1
		s1 = s
	return s1 * s1 + s2 * s2 - c * s1 * s2


func _mono(frames: PackedVector2Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(frames.size())
	for i in frames.size():
		out[i] = 0.5 * (frames[i].x + frames[i].y)
	return out


## Пик в полосе 0,75–1,15 f_thick (там нет других тросов и гармоник).
func _peak_hz(t: WireTone, f_thick: float) -> float:
	var x := _mono(t.fill(int(RATE * 0.5)))
	var best_f := 0.0
	var best := -1.0
	var f := 0.75 * f_thick
	while f <= 1.15 * f_thick:
		var p := _power(x, f)
		if p > best:
			best = p
			best_f = f
		f += 0.004 * f_thick
	return best_f


func test_frequencies_strouhal() -> void:
	var cfg := _cfg()
	var st := float(cfg.strouhal)
	var d: Array = cfg.diameters_m
	var t := _tone()
	t.set_airspeed(15.0)
	for _i in 40:
		t.fill(1024)  # скорость сглажена, ждём установления
	var f := t.frequencies()
	check(f.size() == d.size(), "частот столько же, сколько тросов")
	for i in d.size():
		var want := st * 15.0 / float(d[i])
		check(absf(f[i] - want) < want * 0.01, "f[%d] = St·V/d: %.1f vs %.1f" % [i, f[i], want])
	check(f[0] > f[d.size() - 1], "тонкий трос звучит выше толстого")


func test_spectral_peak_follows_speed() -> void:
	var cfg := _cfg()
	var d_thick := float(cfg.diameters_m[cfg.diameters_m.size() - 1])
	var peaks := {}
	for kmh in [40.0, 80.0]:
		var t := _tone()
		t.set_airspeed(kmh / 3.6)
		for _i in 40:
			t.fill(2048)
		var want: float = float(cfg.strouhal) * kmh / 3.6 / d_thick
		var got := _peak_hz(t, want)
		peaks[kmh] = got
		check(absf(got - want) <= 0.05 * want, "%d км/ч: пик %.0f Гц, ждали %.0f ±5%%" % [kmh, got, want])
	check(
		absf(peaks[80.0] / peaks[40.0] - 2.0) < 0.12, "пик на 80 ≈ 2× пика на 40: %s" % [peaks]
	)


func test_bounded_and_silent_below_threshold() -> void:
	var t := _tone()
	t.set_airspeed(0.0)
	var quiet := t.fill(4096)
	var zeros := true
	for s in quiet:
		if s != Vector2.ZERO:
			zeros = false
	check(zeros, "ниже порога — нули")
	t.set_airspeed(25.0)
	var peak := 0.0
	for _i in 30:
		for s in t.fill(2048):
			peak = maxf(peak, maxf(absf(s.x), absf(s.y)))
	check(peak <= 1.0, "|сэмпл| ≤ 1 (пик %.3f)" % peak)
	check(peak > 0.1, "звук есть на 25 м/с (пик %.3f)" % peak)
	t.set_airspeed(0.0)
	for _i in 30:
		t.fill(2048)
	var tail := t.fill(512)
	var silent := true
	for s in tail:
		if s != Vector2.ZERO:
			silent = false
	check(silent, "после остановки снова тишина")


func test_speed_change_has_no_clicks() -> void:
	# Скачок скорости 12 → 30 м/с: максимальный скачок соседних сэмплов не больше,
	# чем у стационарного звука (нет щелчков), фаза непрерывна.
	var steady := _tone()
	steady.set_airspeed(30.0)
	for _i in 30:
		steady.fill(2048)
	var ref_jump := _max_jump(steady.fill(22050))
	var t := _tone()
	t.set_airspeed(12.0)
	for _i in 30:
		t.fill(2048)
	t.set_airspeed(30.0)
	var jump := _max_jump(t.fill(22050))
	check(jump <= ref_jump * 1.15 + 1e-3, "скачок %.3f против стационарного %.3f" % [jump, ref_jump])


func _max_jump(x: PackedVector2Array) -> float:
	var m := 0.0
	for i in range(1, x.size()):
		m = maxf(m, maxf(absf(x[i].x - x[i - 1].x), absf(x[i].y - x[i - 1].y)))
	return m


func test_too_high_frequency_muted() -> void:
	# Все тросы выше 0,45·mix_rate → тишина, без вылета за пределы.
	var t := WireTone.new()
	t.setup(_cfg(), 4000.0, 1)  # потолок 1800 Гц
	t.set_airspeed(200.0)  # f_min = 0,2·200/0,0048 ≈ 8,3 кГц
	var out := PackedVector2Array()
	for _i in 10:
		out = t.fill(512)
	var peak := 0.0
	for s in out:
		peak = maxf(peak, maxf(absf(s.x), absf(s.y)))
	check(peak == 0.0, "выше 0,45·mix_rate не звучит (пик %.3f)" % peak)


func test_fill_cost() -> void:
	# Синтез на 1 с звука при 22050 Гц должен укладываться в долю секунды (рабочий режим).
	var t := WireTone.new()
	t.setup(_cfg(), 22050.0, 3)
	t.set_airspeed(20.0)
	var t0 := Time.get_ticks_usec()
	t.fill(22050)
	var ms := (Time.get_ticks_usec() - t0) / 1000.0
	print("WireTone: 1 с звука за %.0f мс" % ms)
	check(ms < 400.0, "1 с звука за %.0f мс" % ms)
