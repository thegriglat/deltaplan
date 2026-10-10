class_name NameTag
extends RefCounted
## Подпись в мире (Label3D постоянного размера на экране): имена ботов (BotGlider) и вершины/перевалы
## OSM (OsmPilot). Вид — configs/bots.json → names (шрифт, цвет, обводка, размер букв, прозрачность).
## За рельефом не видна (проверка глубины), гаснет вдали.

const FONT := "res://assets/fonts/NotoSans-CondensedBold.ttf"


## Новая подпись (скрыта); родитель добавляет её сам.
static func create() -> Label3D:
	var t := Label3D.new()
	t.name = "NameTag"
	t.top_level = true
	t.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	t.fixed_size = true
	t.no_depth_test = false
	t.shaded = false
	t.double_sided = true
	# Непрозрачное (отсечка по альфе) — пишет глубину: иначе дымка и облака (haze, cloud_volume
	# — по буферу глубины) рисуются поверх имени, и его не видно.
	t.alpha_cut = Label3D.ALPHA_CUT_DISCARD
	t.font_size = 48
	t.outline_modulate = Color(0.0, 0.0, 0.0, 0.8)
	t.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	t.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if ResourceLoader.exists(FONT):
		t.font = load(FONT)
	t.visible = false
	return t


## Цвет и обводка из настроек вида (bots.json → names).
static func apply_style(tag: Label3D, nc: Dictionary) -> void:
	var c: Array = nc.get("color", [1.0, 1.0, 1.0])
	tag.modulate = Color(float(c[0]), float(c[1]), float(c[2]))
	tag.outline_size = int(nc.get("outline_px", 6))
	if not bool(nc.get("show", true)):
		tag.visible = false


## Видимость 0…1 по дальности: 1 до start, 0 с end.
static func fade(d: float, start: float, end: float) -> float:
	return 1.0 - smoothstep(start, end, d)


## Показать подпись: текст, точка в мире, размер на экране с учётом поля зрения камеры, прозрачность
## alpha·fade. Видимость при угасании ≤ 0,01 — выключена.
static func show_at(
	tag: Label3D, cam: Camera3D, text: String, pos: Vector3, nc: Dictionary, fade_k: float
) -> void:
	if fade_k <= 0.01:
		tag.visible = false
		return
	tag.visible = true
	if tag.text != text:
		tag.text = text
	tag.global_position = pos
	var frac := float(nc.get("font_px", 22.0)) / 1080.0
	tag.pixel_size = frac * 2.0 * tan(deg_to_rad(cam.fov) * 0.5) / float(tag.font_size)
	var k := float(nc.get("alpha", 0.85)) * fade_k
	tag.modulate.a = k
	tag.outline_modulate.a = 0.8 * k


## Текст подписи вершины/перевала: «<имя> <ele> м»; без имени — пусто (подписи нет); без высоты — одно имя.
static func peak_text(nm: String, ele: float) -> String:
	if nm == "":
		return ""
	if is_nan(ele):
		return nm
	return "%s %d м" % [nm, roundi(ele)]
