class_name MenuAmbient
extends Node
## Фон меню: ветер (две записи, порывы по MenuAmbientMix) и далёкие крики хищных птиц.
## Вешается к StartMenu: звучит, пока меню видно (is_visible_in_tree), иначе плавно затухает
## (при старте полёта ~1 с) и останавливается. Свои шины MenuWind/MenuBirds идут в Ambient →
## Master, поэтому громкости из настроек действуют. Параметры — configs/audio.json → menu.

const BUS_WIND := "MenuWind"
const BUS_BIRDS := "MenuBirds"

var mix := MenuAmbientMix.new()
var enabled: bool = true
## null — следить за видимостью родителя; true/false — задать вручную (стенды, тесты).
var force_active: Variant = null

var _cfg: Dictionary = {}
var _wind: AudioStreamPlayer
var _grass: AudioStreamPlayer
var _bird: AudioStreamPlayer
var _birds: Array[AudioStream] = []
var _wind_lpf: AudioEffectLowPassFilter
var _birds_pan: AudioEffectPanner
var _playing: bool = false


func _ready() -> void:
	setup(Config.get_config("audio").get("menu", {}), randi())


func setup(cfg: Dictionary, seed_value: int = 0) -> void:
	_cfg = cfg
	enabled = bool(cfg.get("enabled", true))
	for c in get_children():
		c.queue_free()
	_birds.clear()
	var files: Dictionary = cfg.get("files", {})
	for p in files.get("birds", []):
		var s := _load(String(p))
		if s != null:
			_birds.append(s)
	mix.setup(cfg, seed_value, _birds.size())
	var target := String(cfg.get("bus", "Ambient"))
	AudioBuses.ensure_bus(target)
	var wb := AudioBuses.ensure_bus(BUS_WIND)
	AudioServer.set_bus_send(wb, target)
	_wind_lpf = AudioBuses.find_effect(wb, "AudioEffectLowPassFilter") as AudioEffectLowPassFilter
	if _wind_lpf == null:
		_wind_lpf = AudioEffectLowPassFilter.new()
		AudioServer.add_bus_effect(wb, _wind_lpf)
	var bb := AudioBuses.ensure_bus(BUS_BIRDS)
	AudioServer.set_bus_send(bb, target)
	var blpf := AudioBuses.find_effect(bb, "AudioEffectLowPassFilter") as AudioEffectLowPassFilter
	if blpf == null:
		blpf = AudioEffectLowPassFilter.new()
		AudioServer.add_bus_effect(bb, blpf)
	blpf.cutoff_hz = float(cfg.get("birds_lpf_hz", 6000.0))
	_birds_pan = AudioBuses.find_effect(bb, "AudioEffectPanner") as AudioEffectPanner
	if _birds_pan == null:
		_birds_pan = AudioEffectPanner.new()
		AudioServer.add_bus_effect(bb, _birds_pan)
	_wind = _make_player(_load(String(files.get("wind", ""))), BUS_WIND)
	_grass = _make_player(_load(String(files.get("grass", ""))), BUS_WIND)
	_bird = _make_player(null, BUS_BIRDS)
	_playing = false


func _load(path: String) -> AudioStream:
	if path == "" or not ResourceLoader.exists(path):
		return null
	return load(path) as AudioStream


func _make_player(stream: AudioStream, bus: String) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.stream = stream
	p.bus = bus
	p.volume_db = -80.0
	add_child(p)
	return p


func _active() -> bool:
	if force_active != null:
		return bool(force_active)
	var par := get_parent() as CanvasItem
	return par == null or par.is_visible_in_tree()


func _process(delta: float) -> void:
	if not enabled or _wind == null:
		return
	var ev := mix.advance(delta, _active())
	if not mix.audible():
		if _playing:
			_wind.stop()
			_grass.stop()
			_bird.stop()
			_playing = false
		return
	if not _playing:
		_start_loop(_wind)
		_start_loop(_grass)
		_playing = true
	var fade := mix.fade_db()
	_wind.volume_db = mix.wind_db() + fade
	_grass.volume_db = mix.grass_db() + fade
	_wind_lpf.cutoff_hz = mix.lpf_hz()
	_bird.volume_db = _bird_db + fade
	if not ev.is_empty():
		_play_bird(ev)


var _bird_db: float = -80.0


func _start_loop(p: AudioStreamPlayer) -> void:
	if p.stream != null:
		p.play(randf() * maxf(p.stream.get_length() - 1.0, 0.0))


func _play_bird(ev: Dictionary) -> void:
	var i := int(ev.get("clip", 0))
	if i < 0 or i >= _birds.size():
		return
	_birds_pan.pan = float(ev.get("pan", 0.0))
	_bird_db = float(ev.get("db", -12.0))
	_bird.stream = _birds[i]
	_bird.volume_db = _bird_db + mix.fade_db()
	_bird.play()
