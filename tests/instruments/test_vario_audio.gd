extends TestCase
## Звук вариометра: пороги, частота и темп, гудение, отсутствие щелчков и разрывов.
## Если задана переменная окружения VARIO_WAV_DIR — пишет примеры WAV в эту папку.


func _cfg(preset: String = "xctracer") -> Dictionary:
	return VarioSynth.resolve_preset(Config.get_config("audio").vario_audio, preset)


func _synth(cfg: Dictionary = {}) -> VarioSynth:
	var s := VarioSynth.new()
	s.setup(_cfg() if cfg.is_empty() else cfg)
	return s


## Сигнал при постоянном вариометре, seconds секунд.
func _render(s: VarioSynth, vario: float, seconds: float) -> PackedFloat32Array:
	s.jump_to(vario)
	return s.generate(int(seconds * s.mix_rate_hz))


## Анализ: число писков (начало звука после паузы ≥ 5 мс), средняя частота звучащих участков.
func _analyze(sig: PackedFloat32Array, rate: float, amp: float) -> Dictionary:
	var quiet := amp * 0.01
	var gap_need := int(rate * 0.005)
	var quiet_run := gap_need  # считаем, что до начала была тишина
	var onsets := 0
	var sounding := 0
	var crossings := 0
	var prev := 0.0
	for i in sig.size():
		var x := sig[i]
		if absf(x) < quiet:
			quiet_run += 1
		else:
			if quiet_run >= gap_need:
				onsets += 1
			quiet_run = 0
		if quiet_run < gap_need:
			sounding += 1
			if prev <= 0.0 and x > 0.0:
				crossings += 1
		prev = x
	var dur := float(sig.size()) / rate
	return {
		"beeps_per_s": float(onsets) / dur,
		"freq_hz": float(crossings) / maxf(float(sounding) / rate, 1e-6),
		"sounding_frac": float(sounding) / float(sig.size()),
		"onsets": onsets,
	}


func test_tone_table_monotonic() -> void:
	var s := _synth()
	var a := s.tone_for(0.5)
	var b := s.tone_for(2.0)
	var c := s.tone_for(5.0)
	check(a.mode == VarioSynth.MODE_CLIMB and b.mode == VarioSynth.MODE_CLIMB, "подъём — писк")
	check(b.freq_hz > a.freq_hz and c.freq_hz > b.freq_hz, "частота растёт с подъёмом")
	check(b.period_s < a.period_s and c.period_s < b.period_s, "темп растёт с подъёмом")
	check(s.tone_for(0.05).mode == VarioSynth.MODE_SILENT, "ниже порога 0,1 — тишина")
	check(s.tone_for(-2.0).mode == VarioSynth.MODE_SILENT, "−2 — тишина")
	var d := s.tone_for(-3.0)
	var e := s.tone_for(-6.0)
	check(d.mode == VarioSynth.MODE_SINK, "−3 — гудение")
	check(e.freq_hz < d.freq_hz, "гудение ниже при сильном снижении")
	check(d.duty >= 1.0, "гудение непрерывное")


func test_climb_beeps_faster_and_higher() -> void:
	var s1 := _synth()
	var r1 := _analyze(_render(s1, 0.5, 6.0), s1.mix_rate_hz, s1.amplitude)
	var s2 := _synth()
	var r2 := _analyze(_render(s2, 2.0, 6.0), s2.mix_rate_hz, s2.amplitude)
	var s3 := _synth()
	var r3 := _analyze(_render(s3, 6.0, 6.0), s3.mix_rate_hz, s3.amplitude)
	check(
		r2.freq_hz > r1.freq_hz * 1.2,
		"частота +2 (%.0f) выше +0,5 (%.0f)" % [r2.freq_hz, r1.freq_hz]
	)
	check(
		r2.beeps_per_s > r1.beeps_per_s,
		"темп +2 (%.2f/с) выше +0,5 (%.2f/с)" % [r2.beeps_per_s, r1.beeps_per_s]
	)
	check(r3.beeps_per_s > r2.beeps_per_s * 1.3, "темп +6 (%.2f/с) заметно выше" % r3.beeps_per_s)
	# Сверка с таблицей: частота (с учётом лёгкого «чирпа») и темп.
	var t2 := s2.tone_for(2.0)
	approx(r2.freq_hz, t2.freq_hz, t2.freq_hz * 0.06, "частота при +2")
	approx(r2.beeps_per_s, 1.0 / t2.period_s, 0.2, "писков в секунду при +2")
	check(
		r2.sounding_frac > 0.4 and r2.sounding_frac < 0.7,
		"скважность ~55 %% (%.2f)" % r2.sounding_frac
	)


func test_silence_below_threshold() -> void:
	for v in [0.05, 0.0, -1.0, -2.4]:
		var s := _synth()
		var sig := _render(s, v, 1.0)
		var peak := 0.0
		for x in sig:
			peak = maxf(peak, absf(x))
		check(peak == 0.0, "тишина при %.2f м/с (пик %.4f)" % [v, peak])


func test_sink_tone_continuous() -> void:
	var s := _synth()
	var sig := _render(s, -3.0, 2.0)
	var r := _analyze(sig, s.mix_rate_hz, s.amplitude)
	check(r.onsets == 1, "одно непрерывное гудение, начал: %d" % r.onsets)
	check(r.sounding_frac > 0.99, "звучит всё время (%.3f)" % r.sounding_frac)
	var t := s.tone_for(-3.0)
	approx(r.freq_hz, t.freq_hz, t.freq_hz * 0.03, "частота гудения")
	var s6 := _synth()
	var r6 := _analyze(_render(s6, -6.0, 1.0), s6.mix_rate_hz, s6.amplitude)
	check(r6.freq_hz < r.freq_hz, "при −6 гудение ниже (%.0f < %.0f)" % [r6.freq_hz, r.freq_hz])


func test_thresholds_configurable() -> void:
	var cfg := _cfg()
	cfg.climb_on_ms = 0.5
	cfg.sink_on_ms = -1.5
	var s := _synth(cfg)
	check(s.tone_for(0.3).mode == VarioSynth.MODE_SILENT, "новый порог подъёма 0,5")
	check(s.tone_for(-2.0).mode == VarioSynth.MODE_SINK, "новый порог снижения −1,5")


func test_hysteresis() -> void:
	var s := _synth()
	check(
		s.tone_for(0.07, VarioSynth.MODE_CLIMB).mode == VarioSynth.MODE_CLIMB,
		"уже пищит — держится до 0,05"
	)
	check(
		s.tone_for(0.07, VarioSynth.MODE_SILENT).mode == VarioSynth.MODE_SILENT,
		"из тишины включается только от 0,1"
	)


## Сценарий с меняющимся вариометром: set_vario в одних и тех же отсчётах, куски — разные.
func _scenario(s: VarioSynth, chunks: Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	var step := 997  # смена вариометра каждые 997 отсчётов (некратно кускам)
	var total := int(s.mix_rate_hz * 8.0)
	var pos := 0
	var ci := 0
	while pos < total:
		var n: int = mini(chunks[ci % chunks.size()], total - pos)
		# Не пересекать момент смены вариометра внутри куска.
		var to_change := step - (pos % step)
		n = mini(n, to_change)
		if pos % step == 0:
			var tsec := float(pos) / s.mix_rate_hz
			s.set_vario(-4.0 + 10.0 * tsec / 8.0 + 0.7 * sin(tsec * 3.0))
		out.append_array(s.generate(n))
		pos += n
		ci += 1
	return out


func test_no_discontinuities_between_buffers() -> void:
	# Одинаковый результат при любой нарезке буфера = фаза и огибающая непрерывны на стыках.
	var a := _scenario(_synth(), [100000])
	var b := _scenario(_synth(), [367, 12, 1024, 1, 555, 2048, 97])
	check(a.size() == b.size(), "одинаковая длина")
	var max_diff := 0.0
	for i in a.size():
		max_diff = maxf(max_diff, absf(a[i] - b[i]))
	check(max_diff < 1e-5, "нарезка буфера не меняет звук (разница %.7f)" % max_diff)


func test_no_clicks() -> void:
	# Максимальный скачок между соседними отсчётами не больше,
	# чем у гладкой волны на максимальной частоте.
	var s := _synth()
	var cfg := _cfg()
	var sig := _scenario(s, [733, 256, 1500])
	var fmax := 0.0
	for row in cfg.climb_tones + cfg.sink_tones:
		fmax = maxf(fmax, float(row[1]))
	fmax *= 1.0 + float(cfg.get("climb_chirp_pct", 0.0)) * 0.01
	# Наибольшая крутизна таблицы волны на единицу фазы.
	var table := s._table
	var slope := 0.0
	for i in table.size():
		slope = maxf(slope, absf(table[(i + 1) % table.size()] - table[i]) * table.size())
	var bound := s.amplitude * (slope * fmax / s.mix_rate_hz + 2.0 * s._attack_step) * 1.1
	var max_jump := 0.0
	for i in range(1, sig.size()):
		max_jump = maxf(max_jump, absf(sig[i] - sig[i - 1]))
	check(max_jump <= bound, "скачок %.4f ≤ %.4f" % [max_jump, bound])
	# Начало писка из тишины: первые отсчёты тихие (плавный фронт, без щелчка).
	var s2 := _synth()
	var beep := _render(s2, 2.0, 0.5)
	var first := -1
	for i in beep.size():
		if beep[i] != 0.0:
			first = i
			break
	check(first >= 0, "писк есть")
	var early_peak := 0.0
	for i in range(first, first + int(s2.mix_rate_hz * 0.001)):
		early_peak = maxf(early_peak, absf(beep[i]))
	check(early_peak < s2.amplitude * 0.15, "первая 1 мс писка тихая (%.3f)" % early_peak)


func test_export_wav_examples() -> void:
	var dir := OS.get_environment("VARIO_WAV_DIR")
	if dir == "":
		return
	DirAccess.make_dir_recursive_absolute(dir)
	for v in [0.5, 2.0, 5.0, -3.0, -6.0]:
		var s := _synth()
		_save_wav(_render(s, v, 4.0), s.mix_rate_hz, dir.path_join("vario_%+.1f.wav" % v))
	# Плавный проход −4 → +6 м/с за 30 с.
	var s := _synth()
	var out := PackedFloat32Array()
	var block := 441
	var total := int(30.0 * s.mix_rate_hz)
	var pos := 0
	while pos < total:
		s.set_vario(-4.0 + 10.0 * float(pos) / float(total))
		out.append_array(s.generate(block))
		pos += block
	_save_wav(out, s.mix_rate_hz, dir.path_join("vario_sweep_-4_to_+6.wav"))
	# Синус как в стенде (термик): 0,8 ± 3,2 м/с, период 16 с, 32 с.
	var s2 := _synth()
	var out2 := PackedFloat32Array()
	total = int(32.0 * s2.mix_rate_hz)
	pos = 0
	while pos < total:
		s2.set_vario(0.8 + 3.2 * sin(TAU * float(pos) / s2.mix_rate_hz / 16.0))
		out2.append_array(s2.generate(block))
		pos += block
	_save_wav(out2, s2.mix_rate_hz, dir.path_join("vario_thermal_sine.wav"))


func _save_wav(sig: PackedFloat32Array, rate: float, path: String) -> void:
	var data := PackedByteArray()
	data.resize(sig.size() * 2)
	for i in sig.size():
		data.encode_s16(i * 2, int(clampf(sig[i], -1.0, 1.0) * 32767.0))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = int(rate)
	wav.stereo = false
	wav.data = data
	var err := wav.save_to_wav(path)
	check(err == OK, "запись %s" % path)


func test_presets_exist_and_default_classic() -> void:
	var raw: Dictionary = Config.get_config("audio").vario_audio
	var names := VarioSynth.preset_names(raw)
	check(names.has("classic_90s") and names.has("xctracer"), "пресеты: %s" % str(names))
	check(String(raw.preset) == "classic_90s", "по умолчанию — классический")
	var c := VarioSynth.resolve_preset(raw, "classic_90s")
	check(float(c.climb_on_ms) == float(raw.climb_on_ms), "пороги общие для пресетов")
	var bad := VarioSynth.resolve_preset(raw, "нет_такого")
	check(bad.preset == raw.preset, "неизвестный пресет — пресет по умолчанию")


func test_classic_beeps_faster_and_harsher() -> void:
	var sc := _synth(_cfg("classic_90s"))
	var rc := _analyze(_render(sc, 2.0, 6.0), sc.mix_rate_hz, sc.amplitude)
	var sx := _synth(_cfg("xctracer"))
	var rx := _analyze(_render(sx, 2.0, 6.0), sx.mix_rate_hz, sx.amplitude)
	check(rc.beeps_per_s > rx.beeps_per_s * 1.5, "90-е пищат чаще: %.1f/с" % rc.beeps_per_s)
	var sc5 := _synth(_cfg("classic_90s"))
	var rc5 := _analyze(_render(sc5, 5.0, 4.0), sc5.mix_rate_hz, sc5.amplitude)
	check(
		rc5.beeps_per_s > rc.beeps_per_s * 1.4, "темп растёт с подъёмом: %.1f/с" % rc5.beeps_per_s
	)
	# «Жёсткость»: высокие нечётные гармоники (5, 7, 9) относительно основного тона.
	var hc := _odd_harmonics(_synth(_cfg("classic_90s")), -3.0)
	var hx := _odd_harmonics(_synth(_cfg("xctracer")), -3.0)
	check(hc > 2.0 * hx, "тембр 90-х жёстче: %.2f против %.2f" % [hc, hx])


func test_classic_chunk_invariant() -> void:
	var a := _scenario(_synth(_cfg("classic_90s")), [100000])
	var b := _scenario(_synth(_cfg("classic_90s")), [367, 12, 1024, 1, 555, 2048, 97])
	var max_diff := 0.0
	for i in a.size():
		max_diff = maxf(max_diff, absf(a[i] - b[i]))
	check(max_diff < 1e-5, "нарезка буфера не меняет звук 90-х (%.7f)" % max_diff)
	var peak := 0.0
	for x in a:
		peak = maxf(peak, absf(x))
	check(peak < 1.0, "без перегрузки: пик %.2f" % peak)


## Сумма амплитуд 5-й, 7-й и 9-й гармоник к основной (метод Гёрцеля) на непрерывном гудке.
func _odd_harmonics(s: VarioSynth, vario: float) -> float:
	var f: float = s.tone_for(vario).freq_hz
	var sig := _render(s, vario, 1.0)
	var base := _goertzel(sig, s.mix_rate_hz, f)
	var hi := 0.0
	for k in [5, 7, 9]:
		hi += _goertzel(sig, s.mix_rate_hz, f * k)
	return hi / maxf(base, 1e-9)


func _goertzel(sig: PackedFloat32Array, rate: float, f: float) -> float:
	var w := TAU * f / rate
	var re := 0.0
	var im := 0.0
	# Вторую половину — установившийся тон.
	for i in range(sig.size() / 2, sig.size()):
		re += sig[i] * cos(w * i)
		im += sig[i] * sin(w * i)
	return sqrt(re * re + im * im)


func test_export_preset_wavs() -> void:
	var dir := OS.get_environment("VARIO_WAV_DIR")
	if dir == "":
		return
	for preset in ["classic_90s", "xctracer"]:
		var s := _synth(_cfg(preset))
		var out := PackedFloat32Array()
		var block := 441
		# Сценарий: тишина → +0,5 → +2 → +5 → 0 → −3 → −6 (по 3 с).
		for v in [0.0, 0.5, 2.0, 5.0, 0.0, -3.0, -6.0]:
			s.set_vario(v)
			for k in int(3.0 * s.mix_rate_hz / block):
				out.append_array(s.generate(block))
		_save_wav(out, s.mix_rate_hz, dir.path_join("preset_%s.wav" % preset))
