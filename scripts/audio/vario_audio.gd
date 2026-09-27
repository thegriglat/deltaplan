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
var _cfg: Dictionary = {}


func _ready() -> void:
	setup(Config.get_config("audio").get("vario_audio", {}))


## Перенастроить из словаря (раздел vario_audio). Можно звать повторно после Config.reload().
func setup(cfg: Dictionary) -> void:
	_cfg = cfg
	synth.setup(cfg)
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


## Громкость, дБ (настройки пилота).
func set_volume_db(db: float) -> void:
	if player:
		player.volume_db = db


func set_enabled(on: bool) -> void:
	enabled = on


## Сколько раз с запуска звуку не хватило данных (должно быть 0).
func get_skips() -> int:
	return _playback.get_skips() if _playback else 0


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
