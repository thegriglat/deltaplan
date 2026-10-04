class_name LoadingScreen
extends Control
## Экран загрузки полёта: полупрозрачная панель поверх фона — куда летим, этап («Скачиваю
## рельеф…»), полоса прогресса и время с начала. Точки после этапа и секунды бегут каждый кадр —
## видно, что игра не зависла. Источник — LoadProgress (open). Пока открыт — клики до меню
## не доходят. Ничего не запускает само.

var _progress: LoadProgress
var _place: Label
var _net_label: Label
var _stage: Label
var _bar: ProgressBar
var _time: Label
var _note: Label
var _shown := 0.0
var _anim := 0.0
var _t0 := 0
var _bg: TextureRect

## Кадры игры для фона (случайный на каждую загрузку).
const BACKDROPS: Array[String] = [
	"res://assets/ui/loading/chase.jpg",
	"res://assets/ui/loading/free.jpg",
	"res://assets/ui/loading/run.jpg",
	"res://assets/ui/loading/slavutych.jpg",
	"res://assets/ui/loading/thermal.jpg",
]


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build()
	visible = false


## Показать загрузку: progress — ход (этап и доля), place — куда летим (подпись).
func open(progress: LoadProgress, place: String) -> void:
	if _progress != null and _progress.changed.is_connected(_on_changed):
		_progress.changed.disconnect(_on_changed)
	_progress = progress
	if progress != null:
		progress.changed.connect(_on_changed)
	_bg.texture = load(BACKDROPS[randi() % BACKDROPS.size()]) as Texture2D
	_place.text = place
	_place.visible = place != ""
	set_net_info({})
	_shown = 0.0
	_bar.value = 0.0
	_t0 = Time.get_ticks_msec()
	_on_changed(progress.text if progress != null else "", 0.0)
	visible = true


## Зона сетевого полёта (NET-52, NetPauseInfo.build): код и кто в зоне; {} — не сетевой полёт
## (строка скрыта).
func set_net_info(info: Dictionary) -> void:
	if info.is_empty():
		_net_label.visible = false
		return
	var names: PackedStringArray = []
	for p: Dictionary in info.get("pilots", []):
		names.append(String(p.get("name", "")))
	_net_label.text = (
		"%s %s — %s" % [tr("net_zone_code"), String(info.get("code", "")), ", ".join(names)]
	)
	_net_label.visible = true


## Строка «код зоны — кто в зоне», как показана ("" — не сетевой полёт); для тестов/скриншотов.
func net_line_text() -> String:
	return _net_label.text if _net_label.visible else ""


func close() -> void:
	if _progress != null and _progress.changed.is_connected(_on_changed):
		_progress.changed.disconnect(_on_changed)
	_progress = null
	visible = false


func _build() -> void:
	# непрозрачный фон на весь экран: пропорции сохраняются, лишнее обрезается по краям
	_bg = TextureRect.new()
	_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_bg)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.45)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(dim)
	var ui: Dictionary = Config.get_config("ui")
	var box := UiKit.centered_panel(self, float(ui.get("panel_width_px", 560)))
	UiKit.label(box, tr("loading_title"), "TitleLabel")
	_place = UiKit.label(box, "", "HintLabel")
	_net_label = UiKit.label(box, "", "HintLabel")
	_net_label.visible = false
	UiKit.separator(box)
	_stage = UiKit.label(box, "", "HeaderLabel")
	_note = UiKit.label(box, "", "HintLabel")
	_note.visible = false
	_bar = ProgressBar.new()
	_bar.min_value = 0.0
	_bar.max_value = 1.0
	_bar.step = 0.0
	_bar.show_percentage = false
	_bar.custom_minimum_size.y = 14
	_bar.add_theme_stylebox_override("background", _flat(Color(1, 1, 1, 0.12)))
	_bar.add_theme_stylebox_override("fill", _flat(Color(0.95, 0.78, 0.5, 0.95)))
	box.add_child(_bar)
	_time = UiKit.label(box, "", "HintLabel")
	_time.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	UiKit.label(
		box,
		tr("loading_hint"),
		"HintLabel"
	)


static func _flat(c: Color) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = c
	s.set_corner_radius_all(4)
	return s


func _on_changed(text: String, _fraction: float) -> void:
	_stage.set_meta("base", text.trim_suffix("…").trim_suffix("..."))


func _process(dt: float) -> void:
	if not visible:
		return
	_anim += dt
	var target := _progress.fraction if _progress != null else 0.0
	# полоса догоняет долю плавно (скачки этапов не дёргают)
	_shown = move_toward(_shown, target, maxf(target - _shown, 0.05) * minf(dt * 4.0, 1.0))
	_bar.value = _shown
	var base := String(_stage.get_meta("base", ""))
	if base == "":
		base = tr("loading_getting_ready")
	_stage.text = base + ".".repeat(1 + int(_anim * 2.5) % 3)
	var note := _progress.note if _progress != null else ""
	_note.text = note
	_note.visible = note != ""
	var s := (Time.get_ticks_msec() - _t0) / 1000
	_time.text = "%d:%02d" % [s / 60, s % 60]
