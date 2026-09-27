class_name LoadProgress
extends RefCounted
## Ход долгой загрузки (рельеф с карты, FR-17): этап (текст для экрана загрузки) и доля 0..1.
## Этапы идут по порядку; доля делится между ними по весам (configs/ui.json → loading.stage_weights,
## ключ этапа → вес), внутри этапа — sub(done, total) (например, тайлы скачивания).
## Тот, кто грузит, зовёт stage()/sub(); экран слушает changed. timings — длительность этапов, с
## (замеры, tools/loading/load_probe.gd); trace = true — печатать каждый этап в журнал.

signal changed(text: String, fraction: float)

var text: String = ""
var fraction: float = 0.0
var trace: bool = false
## [{key, text, s}] — завершённые этапы с длительностью.
var timings: Array[Dictionary] = []

var _weights: Dictionary = {}
var _order: PackedStringArray = []
var _key: String = ""
var _lo: float = 0.0
var _hi: float = 0.0
var _t0: int = 0
var _stage_t0: int = 0


func _init(weights: Dictionary = {}) -> void:
	if weights.is_empty():
		weights = Config.value("ui", "loading.stage_weights", {})
	_weights = weights
	_order = PackedStringArray(weights.keys())


## Начать заново (новая загрузка).
func begin() -> void:
	timings.clear()
	_key = ""
	_t0 = Time.get_ticks_usec()
	_stage_t0 = _t0
	_emit(tr("Готовлюсь…"), 0.0)


## Новый этап key (из loading.stage_weights) с текстом для экрана. Доля — начало этапа;
## этапы, которых в весах нет, долю не двигают.
func stage(key: String, stage_text: String) -> void:
	_close_stage()
	_key = key
	var total := 0.0
	var before := 0.0
	var found := false
	for k in _order:
		var w := float(_weights[k])
		if k == key:
			found = true
			_lo = before
			_hi = before + w
		elif not found:
			before += w
		total += w
	if total <= 0.0 or not found:
		_lo = fraction
		_hi = fraction
	else:
		_lo /= total
		_hi /= total
	_emit(stage_text, maxf(fraction, _lo))


## Внутри этапа: сделано done из total.
func sub(done: float, total: float) -> void:
	if total <= 0.0:
		return
	_emit(text, maxf(fraction, lerpf(_lo, _hi, clampf(done / total, 0.0, 1.0))))


## Всё готово.
func finish() -> void:
	_close_stage()
	_key = ""
	_emit("", 1.0)
	if trace:
		print("[load] всего %.2f с" % ((Time.get_ticks_usec() - _t0) / 1e6))


## Сколько секунд прошло с begin().
func elapsed_s() -> float:
	return (Time.get_ticks_usec() - _t0) / 1e6


func _close_stage() -> void:
	var now := Time.get_ticks_usec()
	if _key != "":
		var s := (now - _stage_t0) / 1e6
		timings.append({"key": _key, "text": text, "s": s})
		if trace:
			print("[load] %-10s %6.2f с  (к %.2f с)" % [_key, s, (now - _t0) / 1e6])
	_stage_t0 = now


func _emit(t: String, f: float) -> void:
	text = t
	fraction = f
	changed.emit(text, fraction)
