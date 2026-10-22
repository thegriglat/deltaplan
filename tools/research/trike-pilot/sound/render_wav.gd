extends SceneTree
## Рендер WAV для прослушивания звука двигателя игрока (TP-К9): godot --headless --path . -s tools/research/trike-pilot/sound/render_wav.gd
## Берёт петлю TowTrikeSound.build_stream, гонит TrikeEngine по сценарию и проигрывает петлю с pitch_scale и громкостью
## update_engine (линейная интерполяция, как микшер Godot). Эффектов расстояния нет. Выход: build/screenshots/trike-pilot/.

const OUT := "/home/greg/deltaplan/build/screenshots/trike-pilot/"
const DT := 0.01


func _init() -> void:
	DirAccess.make_dir_recursive_absolute(OUT)
	var cfg: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://configs/trike_pilot.json"))
	var tug: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://configs/tow_tug.json"))
	var snd := TowTrikeSound.new()
	root.add_child(snd)
	snd.setup_player(tug.engine, cfg.sound)
	var b := TowTrikeSound.build_stream(float(tug.engine.gear_ratio), int(tug.engine.prop_blades))
	var loop: PackedByteArray = (b.stream as AudioStreamWAV).data
	var n_loop := loop.size() / 2
	# сценарии: [файл, [[toggle, throttle_axis, секунд], ...], начальный газ, старт прогрева]
	_render("tp9_idle.wav", cfg, tug, snd, loop, n_loop, [[true, 0.0, 6.0]], 0.0, 4.0)
	_render("tp9_half.wav", cfg, tug, snd, loop, n_loop, [[true, 0.0, 4.0], [false, 1.0, 1.0], [false, 0.0, 4.0]], 0.0, 4.0)
	_render("tp9_full.wav", cfg, tug, snd, loop, n_loop, [[true, 0.0, 4.0], [false, 1.0, 2.0], [false, 0.0, 4.0]], 0.0, 4.0)
	_render("tp9_start.wav", cfg, tug, snd, loop, n_loop, [[true, 0.0, 7.0]], 0.0, 0.0)
	_render("tp9_stop.wav", cfg, tug, snd, loop, n_loop, [[true, 0.0, 4.0], [true, 0.0, 6.0]], 0.0, 3.0)
	quit()


func _render(file: String, cfg: Dictionary, tug: Dictionary, snd: TowTrikeSound, loop: PackedByteArray, n_loop: int, segs: Array, _g: float, skip_s: float) -> void:
	var e := TrikeEngine.new()
	e.setup(tug.engine, tug.thrust, cfg)
	e.reset()
	var rate := TowTrikeSound.RATE
	var pcm := PackedByteArray()
	var phase := 0.0
	var spf := int(rate * DT)
	var first := true
	# шаг половины сценария: в «idle/half/full» пропускаем skip_s после запуска (прогрев не нужен)
	var t_total := 0.0
	for seg: Array in segs:
		var n := int(float(seg[2]) / DT)
		for i in n:
			e.step(DT, 0.0, float(seg[1]), seg[0] and i == 0)
			var on := e.state != "off" and e.prop_rpm > 0.0  # как update_engine (узел вне дерева играть не может)
			var gain := db_to_linear(snd.engine_volume_db(e.prop_rpm, e.throttle) + snd.cabin_offset_db) if on else 0.0
			var pitch := clampf(e.prop_rpm / snd.ref_prop_rpm, 0.05, 8.0) if on else 0.0
			t_total += DT
			if t_total < skip_s and file != "tp9_start.wav":
				first = false
				continue
			for k in spf:
				var ip := int(phase)
				var fr := phase - ip
				var a := float(loop.decode_s16((ip % n_loop) * 2))
				var c := float(loop.decode_s16(((ip + 1) % n_loop) * 2))
				var v := (a + (c - a) * fr) / 32768.0 * gain
				var o := PackedByteArray()
				o.resize(2)
				o.encode_s16(0, int(clampf(v, -1.0, 1.0) * 32000.0))
				pcm.append_array(o)
				phase = fmod(phase + pitch, float(n_loop))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = rate
	w.data = pcm
	w.save_to_wav(OUT + file)
	print("wav ", file, " ", pcm.size() / 2.0 / rate, " c")
