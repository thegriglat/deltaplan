class_name BackdropSlideshow
extends Control
## Фон на весь экран из кадров игры (configs/ui.json → backdrops): картинки сменяются по кругу
## через interval_s с плавным переходом fade_s, порядок случайный, первая — случайная. Картинка
## обрезается по центру без искажений. В памяти — только две текстуры (текущая и следующая).
## interval_s = 0 — одна случайная картинка без смены (экран загрузки).

var interval_s := 0.0
var fade_s := 2.0
var _paths: Array[String] = []
var _order: Array[int] = []
var _pos := 0
var _front: TextureRect
var _back: TextureRect
var _timer: Timer


## Список картинок фона из configs/ui.json → backdrops (только существующие).
static func configured_paths() -> Array[String]:
	var out: Array[String] = []
	for p: String in Config.get_config("ui").get("backdrops", []):
		if ResourceLoader.exists(p):
			out.append(p)
	return out


func _init(paths: Array[String] = [], interval: float = 0.0, fade: float = 2.0) -> void:
	_paths = paths
	interval_s = interval
	fade_s = fade
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	clip_contents = true
	_back = _rect()
	_front = _rect()
	_reshuffle()
	if not _paths.is_empty():
		_front.texture = load(_paths[_order[0]]) as Texture2D


func _ready() -> void:
	if interval_s > 0.0 and _paths.size() > 1:
		_timer = Timer.new()
		_timer.wait_time = interval_s
		_timer.timeout.connect(next)
		add_child(_timer)
		_timer.start()


## Новая случайная картинка без перехода (экран загрузки: своя на каждую загрузку).
func show_random() -> void:
	if _paths.is_empty():
		return
	_reshuffle()
	_front.texture = load(_paths[_order[0]]) as Texture2D
	_front.modulate.a = 1.0


## Следующая картинка с плавным переходом.
func next() -> void:
	if _paths.size() < 2:
		return
	_pos += 1
	if _pos >= _order.size():
		var last := _order[_order.size() - 1]
		_reshuffle()
		if _order[0] == last:  # без повтора на стыке кругов
			_order.reverse()
	_back.texture = _front.texture
	_back.modulate.a = 1.0
	_front.texture = load(_paths[_order[_pos]]) as Texture2D
	_front.modulate.a = 0.0
	create_tween().tween_property(_front, "modulate:a", 1.0, fade_s)


func current_path() -> String:
	return "" if _paths.is_empty() else _paths[_order[_pos]]


func _reshuffle() -> void:
	_order.clear()
	for i in _paths.size():
		_order.append(i)
	_order.shuffle()
	_pos = 0


func _rect() -> TextureRect:
	var r := TextureRect.new()
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	r.set_anchors_preset(Control.PRESET_FULL_RECT)
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(r)
	return r
