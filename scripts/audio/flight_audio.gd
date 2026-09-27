class_name FlightAudio
extends Node
## Звуки полёта (FR-28): поток воздуха, тросы, парус, каркас, разбег, посадка, окружение.
## Логика громкостей и событий — FlightSoundMix (RefCounted), здесь — только плееры и шины.
## Вызывать сверху: update(t, extra) каждый шаг физики;
## события — play_landing / play_step / play_carabiner.
## Параметры и пути к файлам — configs/audio.json → flight.

var mix := FlightSoundMix.new()
var enabled: bool = true

var _cfg: Dictionary = {}
var _loops: Dictionary = {}  # имя → AudioStreamPlayer
var _gain: Dictionary = {}  # имя → текущая линейная громкость (сглаженная)
var _pitch: Dictionary = {}  # имя → текущий pitch_scale
var _oneshots: Array[AudioStreamPlayer] = []
var _next_oneshot: int = 0
var _lists: Dictionary = {}  # имя списка → Array[AudioStream]
var _last_pick: Dictionary = {}  # имя списка → последний индекс (без повтора подряд)
var _has_state: bool = false
var _wind_bus: int = 0
var _lpf: AudioEffectLowPassFilter
var _panner: AudioEffectPanner
var _silence_db: float = -60.0
var _min_db: float = -80.0
var _smooth_s: float = 0.2


func _ready() -> void:
	setup(Config.get_config("audio").get("flight", {}))


## Перенастроить из раздела flight (можно повторно после Config.reload()).
func setup(cfg: Dictionary, seed_value: int = 0) -> void:
	_cfg = cfg
	mix.setup(cfg, seed_value)
	_silence_db = float(cfg.get("silence_db", -60.0))
	_min_db = float(cfg.get("min_db", -80.0))
	_smooth_s = float(cfg.get("smooth_s", 0.2))
	if bool(cfg.get("create_missing_buses", true)):
		AudioBuses.ensure(cfg)
	var buses: Dictionary = cfg.get("buses", {})
	_wind_bus = AudioBuses.index_or_master(String(buses.get("wind", "Wind")))
	_lpf = AudioBuses.find_effect(_wind_bus, "AudioEffectLowPassFilter") as AudioEffectLowPassFilter
	_panner = AudioBuses.find_effect(_wind_bus, "AudioEffectPanner") as AudioEffectPanner
	_clear_players()
	var wind := String(buses.get("wind", "Wind"))
	var fx := String(buses.get("effects", "Effects"))
	var amb := String(buses.get("ambient", "Ambient"))
	_make_loops(cfg.get("airflow", {}), FlightSoundMix.AIRFLOW_LOOPS, wind)
	_make_loops(cfg.get("sail", {}), FlightSoundMix.SAIL_LOOPS, fx)
	_make_loops(cfg.get("run", {}), FlightSoundMix.RUN_LOOPS, fx)
	_make_loops(cfg.get("ambient", {}), FlightSoundMix.AMBIENT_LOOPS, amb)
	var sail_files: Dictionary = cfg.get("sail", {}).get("files", {})
	var frame_files: Dictionary = cfg.get("frame", {}).get("files", {})
	var run_files: Dictionary = cfg.get("run", {}).get("files", {})
	var land_files: Dictionary = cfg.get("landing", {}).get("files", {})
	_lists["snaps"] = _load_list(sail_files.get("snaps", []))
	_lists["creaks"] = _load_list(frame_files.get("creaks", []))
	_lists["carabiner"] = _load_list([frame_files.get("carabiner", "")])
	_lists["steps_grass"] = _load_list(run_files.get("steps_grass", []))
	_lists["steps_gravel"] = _load_list(run_files.get("steps_gravel", []))
	_lists["pant"] = _load_list([run_files.get("pant", "")])
	for grade in ["soft", "hard", "crash"]:
		_lists["landing_" + grade] = _load_list(land_files.get(grade, []))
	for i in int(cfg.get("oneshot_voices", 12)):
		var p := AudioStreamPlayer.new()
		p.name = "OneShot%d" % i
		p.bus = fx
		add_child(p)
		_oneshots.append(p)


## Данные полёта. extra: phase ("standing"/"walking"/"running"/"flying"/"landed"),
## stall_amount 0..1, turbulence 0..1, sideslip_deg, load_factor, ground_wind_ms,
## surface ("grass"/"gravel") — всё необязательно.
func update(t: Telemetry, extra: Dictionary = {}) -> void:
	mix.set_state(t, extra)
	_has_state = true


## Посадка: result от планера ({grade: "soft"|"hard"|"crash", vertical_speed_ms, ...}).
func play_landing(result: Dictionary) -> void:
	var grade := String(result.get("grade", "soft"))
	var list: Array = _lists.get("landing_" + grade, [])
	var db := mix.landing_gain_db(result)
	for s in list:
		_play_stream(s, db, 1.0)
	var run: Dictionary = _cfg.get("run", {})
	mix.schedule_pant(float(run.get("pant_delay_s", 1.2)))


## Один шаг (обычно шаги звучат сами по темпу бега).
func play_step(surface: String = "") -> void:
	var run: Dictionary = _cfg.get("run", {})
	var srf := surface if surface != "" else mix.surface
	var jitter := mix.rand_jitter(float(run.get("step_pitch_jitter", 0.05)))
	_play_from("steps_" + srf, float(run.get("step_db", -6.0)), 1.0 + jitter)


## Щелчок карабина (пристёгивание перед стартом).
func play_carabiner() -> void:
	_play_from("carabiner", float(_cfg.get("frame", {}).get("carabiner_db", -6.0)), 1.0)


func set_enabled(on: bool) -> void:
	enabled = on


## Текущая громкость лупа, дБ (для отладки и стендов).
func get_loop_db(loop_name: String) -> float:
	return _to_db(float(_gain.get(loop_name, 0.0)))


func _exit_tree() -> void:
	# Остановить звуки, чтобы аудиосервер отпустил потоки (без утечек при выходе).
	for c in get_children():
		if c is AudioStreamPlayer:
			(c as AudioStreamPlayer).stop()


func _process(delta: float) -> void:
	if not _has_state:
		return
	var levels := mix.compute()
	var k := 1.0 - exp(-delta / maxf(_smooth_s, 1e-3))
	for loop_name in _loops:
		var p: AudioStreamPlayer = _loops[loop_name]
		var target: Vector2 = levels.get(loop_name, Vector2(_min_db, 1.0))
		var target_gain := 0.0 if not enabled else db_to_linear(target.x)
		var g: float = lerpf(_gain[loop_name], target_gain, k)
		var pitch: float = lerpf(_pitch[loop_name], target.y, k)
		_gain[loop_name] = g
		_pitch[loop_name] = pitch
		_apply_loop(p, g, pitch)
	if _lpf:
		_lpf.cutoff_hz = float(levels.get("lp_cutoff_hz", 2000.0))
	if _panner:
		_panner.pan = float(levels.get("pan", 0.0))
	if not enabled:
		return
	for ev in mix.advance(delta):
		_play_event(ev)


func _apply_loop(p: AudioStreamPlayer, gain: float, pitch: float) -> void:
	var db := _to_db(gain)
	if db < _silence_db:
		if p.playing:
			p.stop()
		return
	p.volume_db = db
	p.pitch_scale = maxf(pitch, 0.01)
	if not p.playing:
		var len_s := p.stream.get_length()
		p.play(mix.randf01() * len_s if len_s > 0.0 else 0.0)


func _play_event(ev: Dictionary) -> void:
	var type := String(ev.get("type", ""))
	var db := float(ev.get("gain_db", 0.0))
	var pitch := float(ev.get("pitch", 1.0))
	match type:
		"step":
			_play_from("steps_" + String(ev.get("surface", "grass")), db, pitch)
		"snap":
			_play_from("snaps", db, pitch)
		"creak":
			_play_from("creaks", db, pitch)
		"pant":
			_play_from("pant", db, pitch)


## Случайный файл списка без повтора подряд.
func _play_from(list_name: String, db: float, pitch: float) -> void:
	var list: Array = _lists.get(list_name, [])
	if list.is_empty():
		return
	var last := int(_last_pick.get(list_name, -1))
	var i := int(mix.randf01() * list.size()) % list.size()
	if list.size() > 1 and i == last:
		i = (i + 1) % list.size()
	_last_pick[list_name] = i
	_play_stream(list[i], db, pitch)


func _play_stream(stream: AudioStream, db: float, pitch: float) -> void:
	if stream == null or _oneshots.is_empty():
		return
	var p := _oneshots[_next_oneshot]
	_next_oneshot = (_next_oneshot + 1) % _oneshots.size()
	p.stream = stream
	p.volume_db = db
	p.pitch_scale = maxf(pitch, 0.01)
	p.play()


func _make_loops(section: Dictionary, names: PackedStringArray, bus: String) -> void:
	var files: Dictionary = section.get("files", {})
	for loop_name in names:
		var stream := _load(String(files.get(loop_name, "")))
		if stream == null:
			continue
		var p := AudioStreamPlayer.new()
		p.name = "Loop_" + loop_name
		p.stream = stream
		p.bus = bus
		p.volume_db = _min_db
		add_child(p)
		_loops[loop_name] = p
		_gain[loop_name] = 0.0
		_pitch[loop_name] = 1.0


func _load_list(paths: Array) -> Array[AudioStream]:
	var out: Array[AudioStream] = []
	for path in paths:
		var s := _load(String(path))
		if s:
			out.append(s)
	return out


func _load(path: String) -> AudioStream:
	if path == "":
		return null
	if not ResourceLoader.exists(path):
		push_warning("FlightAudio: нет файла %s" % path)
		return null
	return load(path) as AudioStream


func _clear_players() -> void:
	for c in get_children():
		c.free()
	_loops.clear()
	_gain.clear()
	_pitch.clear()
	_oneshots.clear()
	_lists.clear()
	_next_oneshot = 0


func _to_db(gain: float) -> float:
	return maxf(linear_to_db(maxf(gain, 1e-6)), _min_db)
