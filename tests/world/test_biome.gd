extends TestCase
## Biome (RV-К1): эталонные точки, запасной boreal, границы прямоугольника, профиль — копия.

const REF := [
	["Анси", 45.90, 6.15, "temperate"],
	["Казбеги", 42.66, 44.64, "temperate"],
	["Онгудай", 50.79, 86.13, "boreal"],
	["Аушкуль", 54.72, 59.69, "boreal"],
	["Флорианополис", -27.72, -48.78, "subtropical"],
	["Манаус", -3.10, -60.00, "tropical_wet"],
	["Рапа-Нуи", -27.12, -109.35, "island"],
	["Ницца", 43.70, 7.26, "mediterranean"],
	["Кейптаун", -33.95, 18.42, "mediterranean"],
	["Покхара", 28.21, 83.99, "subtropical"],
	["Кернс", -16.92, 145.77, "tropical_wet"],
	["Тегеран", 35.70, 51.40, "arid"],
]


func _real() -> void:
	Biome.path = "res://configs/biomes.json"
	Biome.reset()


func test_reference_points() -> void:
	_real()
	for r: Array in REF:
		var got := Biome.at(float(r[1]), float(r[2]))
		check(got == String(r[3]), "%s: ожидался %s, получен %s" % [r[0], r[3], got])


func test_missing_file_is_boreal() -> void:
	Biome.path = "res://configs/нет_такого_biomes.json"
	Biome.reset()
	check(Biome.at(-3.1, -60.0) == "boreal", "нет файла — boreal")
	check(Biome.classify_tree(-3.1, -60.0) == "boreal", "нет файла: classify_tree — boreal")
	check(Biome.profile("boreal").is_empty(), "нет файла: профиль пуст")
	_real()


func test_rect_bounds_inclusive() -> void:
	_real()
	# Кейптаун: lat -34.5…-33.0, lon 17.8…19.5; углы входят, чуть снаружи — решает дерево
	for p in [[-34.5, 17.8], [-33.0, 19.5], [-34.5, 19.5], [-33.0, 17.8]]:
		check(Biome.at(p[0], p[1]) == "mediterranean", "угол %s входит" % [p])
	# Рапа-Нуи: углы
	check(Biome.at(-27.3, -109.5) == "island" and Biome.at(-27.0, -109.2) == "island", "углы Рапа-Нуи входят")
	check(Biome.at(-26.9, -109.1) != "island", "снаружи Рапа-Нуи — не island")


func test_profile_is_copy() -> void:
	_real()
	var p := Biome.profile("boreal")
	check(not p.is_empty(), "boreal есть")
	(p.trees as Dictionary).set.clear()
	p["x"] = 1
	var q := Biome.profile("boreal")
	check(q.trees.set.size() == 5 and not q.has("x"), "правка копии не портит кеш")
	check(Biome.profile("нет-такого").is_empty(), "неизвестный — {}")
