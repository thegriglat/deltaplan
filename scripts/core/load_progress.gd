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
## Доп. строка под этапом (например, какой ветер выбран, если его этап пропущен); "" — нет.
var note: String = ""
var trace: bool = false
## [{key, text, s}] — завершённые этапы с длительностью.
var timings: Array[Dictionary] = []

## Счётчики запросов по стадиям сборки (NO-7): ключ стадии ("dem", "surface") → [done, total].
var counters: Dictionary = {}

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
	counters.clear()
	note = ""
	_key = ""
	_t0 = Time.get_ticks_usec()
	_stage_t0 = _t0
	_emit(tr("loading_getting_ready_dots"), 0.0)


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


## Счётчик запросов стадии сборки: сделано done из total (из кеша засчитывается сразу).
## Полоса идёт по счётчику: доля внутри текущего этапа = done / total.
func counter(build_stage: String, done: int, total: int) -> void:
	counters[build_stage] = [done, total]
	if total > 0:
		sub(float(done), float(total))
	else:
		changed.emit(text, fraction)


## «Рельеф: 23/63» для стадии сборки ("" — запросов нет / стадия без счётчика).
func counter_text(build_stage: String) -> String:
	var c: Array = counters.get(build_stage, [])
	if c.is_empty() or int(c[1]) <= 0:
		return ""
	var label_key: String = {"dem": "loading_counter_dem", "surface": "loading_counter_surface"}.get(build_stage, "")
	if label_key == "":
		return ""
	return tr(label_key) % [int(c[0]), int(c[1])]


## Сумма по всем стадиям: [done, total].
func totals() -> Array:
	var d := 0
	var t := 0
	for c: Array in counters.values():
		d += int(c[0])
		t += int(c[1])
	return [d, t]


## «Всего: 40/149» ("" — меньше двух стадий со счётчиком, дублировать нечего).
func total_text() -> String:
	var n := 0
	for c: Array in counters.values():
		if int(c[1]) > 0:
			n += 1
	if n < 2:
		return ""
	var s := totals()
	return tr("loading_counter_total") % [int(s[0]), int(s[1])]


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
