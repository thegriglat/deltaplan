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
## Высота рельефа (x, z) -> м; для закрытия пасхалок землёй. Пусто — не закрыто.
var height_fn := Callable()
var _egg_acc := 0.0
var _egg_seen_t: Dictionary = {}  ## id пасхалки -> непрерывное время в поле зрения, с
const EGG_STEP_S := 0.25  ## проверка видимости пасхалок — не чаще 4 Гц
const EGG_OCCLUSION_POINTS := 16


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
	_egg_seen_t.clear()
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


## Пасхалки в поле зрения (PV-К1): eggs — живые EasterEgg; не чаще 4 Гц; непрерывно hold_s -> egg_seen.
func watch_eggs(camera: Camera3D, eggs: Array, dt: float) -> void:
	if not is_active() or camera == null:
		_egg_seen_t.clear()
		return
	_egg_acc += dt
	if _egg_acc < EGG_STEP_S:
		return
	var step := _egg_acc
	_egg_acc = 0.0
	var cam := camera.global_transform if camera.is_inside_tree() else camera.transform
	var seen_now: Dictionary = {}
	for e: Variant in eggs:
		var egg := e as EasterEgg
		if egg == null or egg.id == "" or seen_now.has(egg.id):
			continue
		var sit_id := "egg_" + egg.id
		var max_d := logic.p(sit_id, "max_dist_m", 0.0)
		if max_d <= 0.0:
			continue
		var point := egg.voice_anchor(cam.origin)
		if egg_in_view(cam, point, logic.p(sit_id, "cone_deg", 30.0), max_d) and not _terrain_hides(cam.origin, point):
			seen_now[egg.id] = true
	for id: String in seen_now:
		var t_seen: float = float(_egg_seen_t.get(id, 0.0)) + step
		if t_seen >= logic.p("egg_" + id, "hold_s", 1.5):
			logic.event("egg_seen", {"id": id})
			t_seen = 0.0
		_egg_seen_t[id] = t_seen
	for id: String in _egg_seen_t.keys():
		if not seen_now.has(id):
			_egg_seen_t.erase(id)


## Точка в конусе взгляда камеры (полуугол cone_deg) и не дальше max_dist_m; рельеф не учитывается.
static func egg_in_view(cam: Transform3D, point: Vector3, cone_deg: float, max_dist_m: float) -> bool:
	var d := point - cam.origin
	var dist := d.length()
	if dist > max_dist_m:
		return false
	if dist < 1e-3:
		return true
	return (-cam.basis.z).dot(d / dist) >= cos(deg_to_rad(cone_deg))


## Отрезок от глаза до точки уходит под рельеф (16 точек).
func _terrain_hides(from: Vector3, to: Vector3) -> bool:
	if not height_fn.is_valid():
		return false
	for i in range(1, EGG_OCCLUSION_POINTS + 1):
		var p := from.lerp(to, float(i) / float(EGG_OCCLUSION_POINTS + 1))
		if p.y < float(height_fn.call(p.x, p.z)):
			return true
	return false


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
