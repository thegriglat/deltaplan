class_name PilotVoice
extends Node
## Реплики пилота игрока (PV-К4): плеер на шине Voice. Решает PilotVoiceLogic, здесь — голос, язык,
## файл (PV-К3) и воспроизведение. Нет файла — реплика молча пропускается.
## Game вызывает update каждый шаг телеметрии и on_event на событиях; set_suppressed — правила «реплик нет»
## (скорость времени ≠ ×1, осмотр, дельталёт и т. п.).

var logic := PilotVoiceLogic.new()
var voice: String = "male"

var _cfg: Dictionary = {}
var _player: AudioStreamPlayer
var _suppressed := false
var _line_id := ""  ## звучащая реплика
var _cache: Dictionary = {}  ## path -> AudioStream или null
var _lang_override := ""


func _ready() -> void:
	setup(Config.get_config("pilot_voice"))


## Перенастроить из configs/pilot_voice.json целиком.
func setup(cfg: Dictionary, rng_seed: int = 0) -> void:
	_cfg = cfg
	logic.setup(cfg, rng_seed)
	set_voice(String(cfg.get("voice", "male")))
	var bus_name := String(cfg.get("bus", "Voice"))
	AudioBuses.ensure_bus(bus_name)
	if _player == null:
		_player = AudioStreamPlayer.new()
		_player.name = "Player"
		add_child(_player)
		_player.finished.connect(_on_finished)
	_player.bus = bus_name
	_player.volume_db = float(cfg.get("volume_db", 0.0))


## "male" | "female" | "off"; неизвестное значение = "off".
func set_voice(v: String) -> void:
	var voices: Array = _cfg.get("voices", ["male", "female"])
	voice = v if voices.has(v) else "off"
	if voice == "off":
		_stop()


func is_active() -> bool:
	return voice != "off" and not _suppressed


func set_suppressed(on: bool) -> void:
	if on == _suppressed:
		return
	_suppressed = on
	if on:
		_stop()


## Новый полёт.
func reset() -> void:
	_stop()
	logic.reset()


func on_event(event_name: String, data := {}) -> void:
	if is_active():
		logic.event(event_name, data)


func update(t: Telemetry, vario_ms: float, cloud: float, dt: float) -> void:
	if not is_active():
		return
	var line := logic.update(
		dt,
		{
			"phase": t.phase,
			"vario_ms": vario_ms,
			"airspeed_ms": t.airspeed,
			"load_factor": t.load_factor,
			"bank_deg": t.bank_deg,
			"altitude_agl": t.altitude_agl,
			"altitude_msl": t.altitude_msl,
			"stalled": t.stalled,
			"cloud": cloud,
		}
	)
	if line != "":
		_play(line)


## Путь файла реплики: <dir>/<voice>/<lang>/<id>_<k>.ogg (PV-К3); dir по умолчанию — из конфига.
static func line_path(voice_name: String, lang: String, line_id: String, dir: String = "") -> String:
	if dir == "":
		dir = String(Config.get_config("pilot_voice").get("dir", "res://assets/sounds/voice"))
	return "%s/%s/%s/%s.ogg" % [dir, voice_name, lang, line_id]


## Язык реплик по языку интерфейса: ru* -> ru, иначе en.
func lang() -> String:
	if _lang_override != "":
		return _lang_override
	return "ru" if TranslationServer.get_locale().begins_with("ru") else "en"


func set_lang_override(l: String) -> void:
	_lang_override = l


func current_line() -> String:
	return _line_id


func _play(line_id: String) -> void:
	var path := line_path(voice, lang(), line_id, String(_cfg.get("dir", "res://assets/sounds/voice")))
	var stream: AudioStream = _stream(path)
	if stream == null:
		logic.line_finished()  # файла нет: тихо, ситуация уже ушла на паузу
		return
	_line_id = line_id
	_player.stream = stream
	_player.play()


func _stream(path: String) -> AudioStream:
	if not _cache.has(path):
		_cache[path] = load(path) as AudioStream if ResourceLoader.exists(path) else null
	return _cache[path]


func _stop() -> void:
	_line_id = ""
	if _player != null and _player.playing:
		_player.stop()
	logic.line_finished()


func _on_finished() -> void:
	_line_id = ""
	logic.line_finished()
