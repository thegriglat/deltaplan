class_name VarioAudio
extends Node
## Звук вариометра (FR-23): AudioStreamGenerator + VarioSynth.
## Буфер дозаполняется в _process (сколько освободилось с прошлого кадра).
## Вход — set_vario(ms): передавайте отфильтрованный вариометр (Vario.vario_ms),
## тогда звук и стрелка прибора совпадают, как у настоящего прибора.
## Параметры — configs/audio.json → vario_audio.

var synth := VarioSynth.new()
var player: AudioStreamPlayer
var enabled: bool = true
var _playback: AudioStreamGeneratorPlayback
var _raw: Dictionary = {}  # раздел vario_audio как в конфиге (с presets)
var _cfg: Dictionary = {}  # собранные настройки текущего пресета


func _ready() -> void:
	setup(Config.get_config("audio").get("vario_audio", {}))


## Перенастроить из словаря (раздел vario_audio). Можно звать повторно после Config.reload().
## preset_name — пресет звучания; пусто — из cfg.preset.
func setup(cfg: Dictionary, preset_name: String = "") -> void:
	_raw = cfg.duplicate(true)  # своя копия: set_thresholds не должен менять общий кеш Config
	_cfg = VarioSynth.resolve_preset(cfg, preset_name)
	var last := synth.get_target_vario()
	synth.setup(_cfg)
	synth.set_vario(last)
	enabled = bool(cfg.get("enabled", true))
	if player == null:
		player = AudioStreamPlayer.new()
		player.name = "VarioPlayer"
		add_child(player)
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = synth.mix_rate_hz
	gen.buffer_length = float(cfg.get("buffer_length_s", 0.12))
	player.stream = gen
	var bus := String(cfg.get("bus", "Master"))
	player.bus = bus if AudioServer.get_bus_index(bus) >= 0 else &"Master"
	player.volume_db = float(cfg.get("volume_db", -6.0))
	player.play()
	_playback = player.get_stream_playback()
	_fill()


## Показание вариометра, м/с (+ вверх).
func set_vario(ms: float) -> void:
	synth.set_vario(ms)


## Сменить звучание: "classic_90s", "xctracer" … (ключи vario_audio.presets).
## Громкость и пороги при этом сохраняются.
func set_preset(preset_name: String) -> void:
	var vol := player.volume_db if player else float(_raw.get("volume_db", -6.0))
	var on := enabled
	setup(_raw, preset_name)
	set_volume_db(vol)
	enabled = on


## Имя текущего пресета.
func get_preset() -> String:
	return String(_cfg.get("preset", ""))


## Имена доступных пресетов.
func get_preset_names() -> PackedStringArray:
	return VarioSynth.preset_names(_raw)


## Пороги звука (настройки пилота), м/с.
func set_thresholds(climb_on_ms: float, sink_on_ms: float) -> void:
	_raw["climb_on_ms"] = climb_on_ms
	_raw["sink_on_ms"] = sink_on_ms
	set_preset(get_preset())


## Громкость, дБ (настройки пилота).
func set_volume_db(db: float) -> void:
	if player:
		player.volume_db = db


func set_enabled(on: bool) -> void:
	enabled = on


## Текущие настройки для показа на приборе (FlightInstrument.set_sound_settings).
func get_settings() -> Dictionary:
	return {
		"enabled": enabled,
		"volume_db": player.volume_db if player else float(_cfg.get("volume_db", 0.0)),
		"climb_on_ms": float(_cfg.get("climb_on_ms", 0.1)),
		"sink_on_ms": float(_cfg.get("sink_on_ms", -2.5)),
		"preset": String(_cfg.get("preset", "")),
		"preset_title": String(_cfg.get("preset_title", "")),
	}


## Сколько раз с запуска звуку не хватило данных (должно быть 0).
func get_skips() -> int:
	return _playback.get_skips() if _playback else 0


func _exit_tree() -> void:
	# Отпустить playback генератора: остановить, снять поток (иначе утечка при выходе).
	_playback = null
	if player:
		player.stop()
		player.stream = null


func _process(_delta: float) -> void:
	_fill()


func _fill() -> void:
	if _playback == null:
		return
	var n := _playback.get_frames_available()
	if n <= 0:
		return
	if not enabled:
		# Выключено: плавно гасим (синтез с порогом «тишина»), не обрывая писк.
		synth.set_vario(0.0)
	_playback.push_buffer(synth.generate_stereo(n))
