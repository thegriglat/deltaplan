class_name AudioBuses
extends RefCounted
## Аудиошины проекта: Master ← Vario, Wind (ФНЧ, панорама, компрессор), Effects, Ambient.
## Эталон раскладки — scenes/audio/bus_layout.tres (подключается в project.godot интегратором).
## ensure() создаёт недостающие шины при запуске — чтобы стенды работали и без раскладки.


## Создать недостающие шины (cfg — раздел flight из configs/audio.json).
static func ensure(cfg: Dictionary) -> void:
	var buses: Dictionary = cfg.get("buses", {})
	_ensure_bus(String(buses.get("vario", "Vario")))
	var wind := _ensure_bus(String(buses.get("wind", "Wind")))
	if find_effect(wind, "AudioEffectLowPassFilter") == null:
		AudioServer.add_bus_effect(wind, AudioEffectLowPassFilter.new())
	if find_effect(wind, "AudioEffectPanner") == null:
		AudioServer.add_bus_effect(wind, AudioEffectPanner.new())
	if find_effect(wind, "AudioEffectCompressor") == null:
		var comp := AudioEffectCompressor.new()
		comp.threshold = float(buses.get("wind_compressor_threshold_db", -12.0))
		comp.ratio = float(buses.get("wind_compressor_ratio", 3.0))
		AudioServer.add_bus_effect(wind, comp)
	_ensure_bus(String(buses.get("effects", "Effects")))
	_ensure_bus(String(buses.get("ambient", "Ambient")))


## Эффект заданного класса на шине или null.
static func find_effect(bus: int, cls: String) -> AudioEffect:
	if bus < 0:
		return null
	for i in AudioServer.get_bus_effect_count(bus):
		var e := AudioServer.get_bus_effect(bus, i)
		if e.is_class(cls):
			return e
	return null


## Индекс шины по имени; Master (0), если такой нет.
static func index_or_master(bus_name: String) -> int:
	var i := AudioServer.get_bus_index(bus_name)
	return i if i >= 0 else 0


static func _ensure_bus(bus_name: String) -> int:
	var i := AudioServer.get_bus_index(bus_name)
	if i >= 0:
		return i
	AudioServer.add_bus()
	i = AudioServer.bus_count - 1
	AudioServer.set_bus_name(i, bus_name)
	AudioServer.set_bus_send(i, &"Master")
	return i
