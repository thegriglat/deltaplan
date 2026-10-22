extends TestCase
## Цвет солнца из пропускания атмосферы (HH4 v2): день — белый, закат — краснее, у горизонта — тёмно-красный;
## в configs/world.json нет ручной таблицы time.light.sun_color.


func _sun_color(h: float, month: int, day: int) -> Color:
	var sky: SkyEnvironment = load("res://scenes/world/environment.tscn").instantiate()
	sky.apply_config()  # без дерева: _ready не вызывается
	sky.clock.start_flight(53.26, 58.54, month, day, h, 5.0)
	var c: Color = sky.sky_material().get_shader_parameter("sun_color")
	sky.free()
	var b: Array = Config.get_config("world").sun.color
	return Color(c.r / float(b[0]), c.g / float(b[1]), c.b / float(b[2]))  # без sun.color — чистая цветность


func test_no_manual_table() -> void:
	var l: Dictionary = Config.get_config("world").time.light
	check(not l.has("sun_color"), "ручной таблицы sun_color нет")


func test_noon_white_dusk_red() -> void:
	var noon := _sun_color(13.0, 7, 15)
	check(absf(noon.g / noon.r - 1.0) < 0.03 and absf(noon.b / noon.r - 1.0) < 0.03, "днём белое: %s" % noon)
	var dusk := _sun_color(20.0 + 40.0 / 60.0, 7, 15)  # ≈ 5°
	check(dusk.g / dusk.r < 0.65 and dusk.b / dusk.r < 0.3, "закат красный: %s" % dusk)
